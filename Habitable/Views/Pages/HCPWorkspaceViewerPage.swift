import SwiftUI

private enum HCPWorkspaceSection: String, CaseIterable, Identifiable {
    case map = "Map"
    case runs = "Runs"
    case variables = "Variables"
    var id: String { rawValue }
}

struct HCPWorkspaceViewer: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    let connectionOnly: Bool
    let onOpenConnections: () -> Void
    let onOpenWorkspaces: () -> Void
    @StateObject private var localConnections = LocalCloudConnectionsModel()
    @State private var workspaceSearch = ""
    @State private var section: HCPWorkspaceSection = .map
    @State private var showingWorkspaces = false
    @State private var inspectorRequest: HCPMapInspectorRequest?

    init(model: HCPWorkspaceViewerModel, connectionOnly: Bool = false,
         onOpenConnections: @escaping () -> Void = {}, onOpenWorkspaces: @escaping () -> Void = {}) {
        self.model = model; self.connectionOnly = connectionOnly
        self.onOpenConnections = onOpenConnections; self.onOpenWorkspaces = onOpenWorkspaces
    }

    private var filteredWorkspaces: [HCPWorkspace] {
        let source = model.linkedWorkspaceCandidates ?? model.workspaces
        let query = workspaceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if connectionOnly {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Connections").font(.largeTitle.weight(.semibold))
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("HCP Terraform & Terraform Enterprise").font(.title3.weight(.semibold))
                                Text("Browse remote workspace state and runs.").foregroundStyle(.secondary)
                                connectionPanel
                                if model.isConnected {
                                    Button("Open workspaces", action: onOpenWorkspaces).buttonStyle(.borderedProminent)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Local cloud access").font(.title2.weight(.semibold))
                                Text("Uses your existing CLI sign-ins for local Terraform workflows.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if localConnections.isRefreshing { ProgressView().controlSize(.small) }
                            Button("Refresh cloud connections") { Task { await localConnections.refresh() } }
                                .disabled(localConnections.isRefreshing || localConnections.connectingID != nil)
                        }
                        ForEach(localConnections.connections) { connection in
                            LocalCloudConnectionCard(connection: connection, isRefreshing: localConnections.isRefreshing,
                                                     isConnecting: localConnections.connectingID == connection.id,
                                                     canConnect: localConnections.canConnect(connection.id),
                                                     loginMessage: localConnections.loginMessages[connection.id]) {
                                Task { await localConnections.connect(connection.id) }
                            }
                        }
                        Text("Authentication checks do not run a plan or change infrastructure. Provider settings in each workspace determine which profile, subscription, and project Terraform uses.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(maxWidth: 980, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.task { await localConnections.refresh() }
            } else if model.isConnected {
                if section == .map {
                    cloudMap.frame(minWidth: 550, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if section == .variables {
                    HCPMapVariablesPanel(model: model).id(model.mapRequestKey)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        if geometry.size.width >= 960 {
                            HSplitView {
                                workspaceColumn.frame(minWidth: 210, idealWidth: 250, maxWidth: 330)
                                runColumn.frame(minWidth: 260, idealWidth: 320, maxWidth: 390)
                                runDetail.frame(minWidth: 360, maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 0) {
                                compactSelection
                                Divider()
                                runDetail
                            }
                        }
                    }
                }
            } else {
                disconnectedState
            }
        }
        .padding(connectionOnly || section != .map ? 16 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            if !connectionOnly && model.isConnected {
              QuietToolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { showingWorkspaces.toggle() } label: {
                        Label(model.selectedWorkspace?.name ?? "Choose workspace", systemImage: "square.grid.2x2")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Choose cloud workspace")
                    .help("Choose an organization and workspace")
                    .popover(isPresented: $showingWorkspaces) {
                        VStack(alignment: .leading, spacing: 12) {
                            organizationPicker
                            workspaceColumn
                        }.padding(16).frame(width: 340, height: 520)
                    }
                    Picker("Workspace view", selection: Binding(get: { section == .variables ? .map : section },
                                                              set: { section = $0 })) {
                        Text("Map").tag(HCPWorkspaceSection.map)
                        Text("Runs").tag(HCPWorkspaceSection.runs)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 132)
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(get: { section == .variables }, set: { section = $0 ? .variables : .map })) {
                        Label("Variables", systemImage: "slider.horizontal.3")
                    }
                    .toggleStyle(.button)
                    .help("Show or hide workspace variables")
                    .accessibilityLabel("Show workspace variables")
                }
              }
            }
        }
        .onChange(of: model.mapRequestKey) { _ in inspectorRequest = nil }
        .sheet(item: $inspectorRequest) { request in
            HCPMapResourceSheet(resources: model.mapSnapshot?.resources ?? [],
                                title: model.selectedWorkspace?.name ?? "Workspace", selectedAddress: request.address)
        }
        .alert("HCP Terraform", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
    }

    // Only user selection starts a request. Model refreshes already load their
    // selected workspace/run and must not be duplicated when layouts remount.
    private var workspaceSelection: Binding<String?> {
        Binding(get: { model.selectedWorkspaceID }, set: { id in
            showingWorkspaces = false
            guard model.selectedWorkspaceID != id else { return }
            model.selectedWorkspaceID = id
            if id != nil { Task { await model.refreshRuns(force: true) } }
        })
    }

    private var runSelection: Binding<String?> {
        Binding(get: { model.selectedRunID }, set: { id in
            guard model.selectedRunID != id else { return }
            model.selectedRunID = id
            guard let id, let run = model.runs.first(where: { $0.id == id }) else { return }
            Task { await model.load(run: run) }
        })
    }

    @ViewBuilder private var organizationPicker: some View {
        if model.organizations.isEmpty {
            TextField("Organization name", text: $model.selectedOrganization)
                .textFieldStyle(.roundedBorder).accessibilityLabel("HCP Terraform organization")
        } else {
            Picker("Organization", selection: Binding(get: { model.selectedOrganization }, set: { organization in
                guard organization != model.selectedOrganization else { return }
                let reconnect = model.isConnected
                model.selectedOrganization = organization
                if reconnect { Task { await model.connect() } }
            })) {
                ForEach(model.organizations) { organization in Text(organization.name).tag(organization.name) }
            }
            .labelsHidden().lineLimit(1).accessibilityLabel("HCP Terraform organization")
            .help(model.hostname)
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 160), alignment: .leading),
                                GridItem(.flexible(minimum: 160), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hostname").font(.caption).foregroundStyle(.secondary)
                    TextField("app.terraform.io", text: $model.hostname)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("HCP Terraform hostname")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization").font(.caption).foregroundStyle(.secondary)
                    organizationPicker
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.isConnected ? model.connectionSummary : "Credentials are stored in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.isConnected {
                    Button("Refresh") { Task { await model.refreshWorkspaces() } }
                        .disabled(model.isLoading)
                    Button("Disconnect") { model.disconnect() }
                } else {
                    Button("Import CLI credential") { Task { await model.importTerraformCredentialFile() } }
                        .help("Import the Terraform CLI credential into Keychain")
                        .disabled(model.isImporting || model.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "app.terraform.io")
                    Button("Connect") { Task { await model.connect() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isLoading || !model.hasStoredCredential)
                }
            }
            .buttonStyle(.borderless)
            if model.isImporting {
                Label("Importing credential into Keychain…", systemImage: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    /// Keep the selected workspace represented when search narrows the menu.
    /// Filtering must not silently change the workspace or selected run.
    private var compactWorkspaces: [HCPWorkspace] {
        var choices = filteredWorkspaces
        if let selected = model.selectedWorkspace, !choices.contains(where: { $0.id == selected.id }) {
            choices.insert(selected, at: 0)
        }
        return choices
    }

    private var compactSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Filter workspaces", text: $workspaceSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Filter HCP workspaces")
                Text("\(filteredWorkspaces.count) of \(model.workspaces.count) workspaces")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.workspaceHasNextPage {
                    Button("Load more") { Task { await model.loadNextWorkspacePage() } }
                        .disabled(model.isLoading)
                        .accessibilityLabel("Load more workspaces")
                }
            }
            HStack(spacing: 12) {
                Picker("Workspace", selection: workspaceSelection) {
                    Text("Choose a workspace").tag(nil as String?)
                    ForEach(compactWorkspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let workspace = model.selectedWorkspace {
                    if let version = workspace.terraformVersion {
                        Text("Terraform \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if workspace.locked { Image(systemName: "lock").help("Workspace locked").accessibilityLabel("Workspace locked") }
                    if let url = workspace.htmlURL {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Open workspace in HCP Terraform")
                            .accessibilityLabel("Open workspace in HCP Terraform")
                    }
                }
            }
            if section == .runs {
                HStack(spacing: 12) {
                    Picker("Run", selection: runSelection) {
                        Text(model.runs.isEmpty ? "No remote runs loaded" : "Choose a run").tag(nil as String?)
                        if let id = model.selectedRunID, !model.runs.contains(where: { $0.id == id }) {
                            Text("Selected run · \(id)").tag(Optional(id))
                        }
                        ForEach(model.runs) { run in
                            Text("\(run.status.replacingOccurrences(of: "_", with: " ").capitalized) · \(run.message?.isEmpty == false ? run.message! : run.operation ?? run.id)")
                                .tag(Optional(run.id))
                        }
                    }
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .disabled(model.selectedWorkspaceID == nil)
                    if model.runHasNextPage {
                        Button("Load more") { Task { await model.loadNextRunPage() } }
                            .disabled(model.isLoading)
                            .accessibilityLabel("Load more remote runs")
                    }
                    Button { Task { await model.refreshRuns(force: false) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh run history").accessibilityLabel("Refresh remote run history")
                        .disabled(model.isLoading || model.selectedWorkspaceID == nil)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 12)
    }

    /// Shown when a local folder's backend selects workspaces by tag or prefix.
    /// Only the verified candidates are offered; nothing is chosen for the user.
    private func linkedCandidateChooser(_ candidates: [HCPWorkspace], notice: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(notice, systemImage: "folder.badge.questionmark").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(candidates) { workspace in
                    Button { workspaceSelection.wrappedValue = workspace.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name)
                                HStack(spacing: 6) {
                                    if let version = workspace.terraformVersion { Text("Terraform \(version)") }
                                    if !workspace.tagNames.isEmpty { Text(workspace.tagNames.joined(separator: ", ")) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Choose workspace \(workspace.name)")
                }
            }
            Button("Show all workspaces") { model.clearLinkedWorkspaceCandidates() }.buttonStyle(.borderless)
        }
        .padding(20).frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var cloudMap: some View {
        if model.selectedWorkspace == nil, let candidates = model.linkedWorkspaceCandidates,
           let notice = model.linkedWorkspaceNotice {
            linkedCandidateChooser(candidates, notice: notice)
        } else if model.selectedWorkspace == nil {
            Text("Choose a workspace to view its resource map.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        VStack(spacing: 0) {
        ResourceMapContent(title: model.selectedWorkspace?.name ?? "Choose a workspace",
            identity: model.mapRequestKey + "|" + (model.mapSnapshot?.versionID ?? ""),
            map: model.mapSnapshot?.map, resources: model.mapSnapshot?.resources ?? [],
            notice: model.mapSnapshot?.notice ?? (model.mapSnapshot == nil ? nil : "HCP Terraform · Current state"),
            errorMessage: model.mapError,
            isLoading: model.isLoadingMap, canRefresh: model.selectedWorkspace != nil && !model.isLoadingMap,
            refresh: { Task { await model.refreshMap() } },
            onShowList: { inspectorRequest = HCPMapInspectorRequest(address: nil) },
            onOpenResource: { address in inspectorRequest = HCPMapInspectorRequest(address: address) },
            emptyDetail: "This workspace has no managed resources in its current state. Data sources remain available in List; remote run history is available in Runs.",
            workspaceURL: model.selectedWorkspace?.htmlURL,
            stateVersionID: model.mapSnapshot?.versionID,
            stateCreatedAt: model.mapSnapshot?.stateCreatedAt,
            stateSerial: model.mapSnapshot?.stateSerial,
            onShowHistory: { section = .runs },
            onShowVariables: { section = .variables })
        .task(id: model.mapRequestKey) { await model.refreshMap() }
        Divider()
        MapTimelineStrip(clips: remoteChangeClips, selectedID: model.selectedRunID,
                         hint: model.runs.isEmpty ? "" : "Select a change to review its remote run",
                         onSelect: { clip in
                             runSelection.wrappedValue = clip.id
                             section = .runs
                         }, onShowAll: { section = .runs })
        }
        }
    }

    /// Loaded remote runs, oldest first. HCP run lists carry no per-run change
    /// counts, so clips show their recorded status instead of inventing numbers.
    private var remoteChangeClips: [MapChangeClip] {
        model.runs.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }.map { run in
            let status = run.status.replacingOccurrences(of: "_", with: " ").capitalized
            let fallback = run.operation?.replacingOccurrences(of: "_", with: " ").capitalized ?? status
            return MapChangeClip(id: run.id, title: run.message?.isEmpty == false ? run.message! : fallback,
                                 date: run.createdAt, status: run.hasChanges == false ? "No changes" : status,
                                 isApplied: run.status == "applied", added: nil, changed: nil, destroyed: nil, author: nil)
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(model.hasStoredCredential ? "Connect to load your organization" : "Import a credential to get started")
                .font(.headline)
            Text("Browse workspace state and runs. Workspace variables are updated only when you choose Save; Habitable does not queue or apply remote runs.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480) }
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Open connection settings", action: onOpenConnections).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workspaces").font(.headline)
                Spacer()
                Text("\(model.workspaces.count)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Filter workspaces", text: $workspaceSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredWorkspaces) { workspace in
                        Button { workspaceSelection.wrappedValue = workspace.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.name).lineLimit(1)
                                    HStack(spacing: 5) {
                                        if let version = workspace.terraformVersion { Text("Terraform \(version)") }
                                        if workspace.locked { Text("Locked") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if model.selectedWorkspaceID == workspace.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedWorkspaceID == workspace.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Choose workspace \(workspace.name)")
                        .contextMenu {
                            if let url = workspace.htmlURL { Link("Open in HCP Terraform", destination: url) }
                        }
                    }
                }
            }
            if model.workspaceHasNextPage {
                Button("Load More Workspaces") { Task { await model.loadNextWorkspacePage() } }
                    .buttonStyle(.borderless).disabled(model.isLoading)
            }
        }
        .padding(.trailing, 8)
    }

    private var runColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote runs").font(.headline)
                Spacer()
                Button { Task { await model.refreshRuns(force: false) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh run history")
                    .accessibilityLabel("Refresh run history")
                    .disabled(model.isLoading || model.selectedWorkspaceID == nil)
            }
            if let workspace = model.selectedWorkspace {
                Text(workspace.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            List(selection: runSelection) {
                ForEach(model.runs) { run in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(run.message?.isEmpty == false ? run.message! : run.operation ?? "Terraform run")
                                .font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Spacer(minLength: 0)
                            if run.isDestroy { Image(systemName: "trash").foregroundStyle(.orange).help("Destroy run") }
                        }
                        HStack(spacing: 6) {
                            HCPRunStatusLabel(status: run.status)
                            if let date = run.createdAt {
                                Text("· \(hcpRelativeDate(date))").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12))
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(run.id))
                }
            }
            .listStyle(.inset)
            if model.runHasNextPage {
                Button("Load More Runs") { Task { await model.loadNextRunPage() } }
                    .buttonStyle(.borderless).disabled(model.isLoading)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var runDetail: some View {
        if let details = model.selectedRunDetails {
            HCPRunDetailView(details: details)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Select a remote run").font(.headline)
                Text("Choose a run to review its phase status, output, and HCP Terraform links.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

// MARK: - Remote run detail

private func hcpRelativeDate(_ date: Date) -> String {
    RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
}

private func hcpStatusColor(_ status: String) -> Color {
    switch status {
    case "applied": return .green
    case "errored": return .red
    case "planned", "planned_and_finished", "planned_and_saved", "discarded", "canceled", "force_canceled": return .secondary
    default: return .orange
    }
}

private let hcpReplaceColor = Color(red: 0.86, green: 0.25, blue: 0.55)

private func hcpActionStyle(_ action: ChangeActions) -> (word: String, color: Color) {
    switch action {
    case .Create: return ("Create", .green)
    case .Update: return ("Update", .orange)
    case .Replace: return ("Replace", hcpReplaceColor)
    case .Delete: return ("Delete", .red)
    case .Read: return ("Read", .blue)
    case .NoOp: return ("No-op", .secondary)
    }
}

private struct HCPRunStatusLabel: View {
    let status: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(hcpStatusColor(status)).frame(width: 8, height: 8)
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status \(status.replacingOccurrences(of: "_", with: " "))")
    }
}

private func hcpCopy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct HCPRunDetailView: View {
    let details: HCPRunDetails
    @State private var plan: HCPRunLogPresentation?
    @State private var apply: HCPRunLogPresentation?

    private var statusWord: String { details.run.status.replacingOccurrences(of: "_", with: " ").capitalized }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let summary = plan?.summary ?? apply?.summary {
                    consequences(summary, replaces: plan?.replaceCount ?? apply?.replaceCount ?? 0)
                }
                phases
                if let plan, !plan.plannedChanges.isEmpty { plannedChanges(plan.plannedChanges) }
                if let apply, !apply.applyEvents.isEmpty { applyActivity(apply.applyEvents) }
                diagnosticsSection
                otherOutput
                if let logs = details.planLogs { rawSection("Raw plan output", text: logs) }
                if let logs = details.applyLogs { rawSection("Raw apply output", text: logs) }
                if details.planLogs == nil && details.applyLogs == nil {
                    Text("Run output is unavailable for this account or run phase. Open the run in HCP Terraform for the full event timeline.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
        // Parse once per details change, not on every render.
        .task(id: details) {
            plan = details.planLogs.map(HCPRunLogPresentation.parse)
            apply = details.applyLogs.map(HCPRunLogPresentation.parse)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(details.run.message?.isEmpty == false ? details.run.message! : "Remote run")
                .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(([statusWord] + [details.run.operation].compactMap { $0 }
                      + [details.run.createdAt.map(hcpRelativeDate)].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let url = details.runURL {
                    Text("·").foregroundStyle(.secondary)
                    Link("Open in HCP Terraform", destination: url).font(.system(size: 13))
                }
            }
            .accessibilityElement(children: .contain)
            Text(details.run.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }

    private func consequences(_ summary: HCPRunLogPresentation.Summary, replaces: Int) -> some View {
        // Terraform's change_summary counts a replace as 1 add + 1 remove, so
        // subtract replaces from both to show them as their own column.
        let add = max(0, summary.add - replaces)
        let remove = max(0, summary.remove - replaces)
        return HStack(alignment: .top, spacing: 28) {
            stat(add, "to add", .green)
            stat(summary.change, "to change", .orange)
            stat(replaces, "to replace", hcpReplaceColor)
            stat(remove, "to remove", .red)
        }
        .accessibilityElement(children: .contain)
    }

    private func stat(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(value == 0 ? Color.secondary : color)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private var phases: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 12) {
            phase("Plan", details.planStatus ?? (details.run.planID == nil ? "Not available" : "Available"))
            phase("Apply", details.applyStatus ?? (details.run.applyID == nil ? "Not part of this run" : "Available"))
            changeStateLabel
            if let review = details.planReviewURL {
                Link("Review plan in HCP Terraform", destination: review).font(.system(size: 13))
            }
        }
    }

    /// Never shows "No changes" for a failed run; that is only claimed when a parsed summary says zero.
    @ViewBuilder private var changeStateLabel: some View {
        let status = details.run.status
        let summary = plan?.summary ?? apply?.summary
        if ["errored", "canceled", "force_canceled", "discarded"].contains(status) {
            Label(statusWord, systemImage: status == "errored" ? "xmark.octagon.fill" : "minus.circle")
                .font(.system(size: 13)).foregroundStyle(status == "errored" ? Color.red : Color.secondary)
        } else if let summary {
            let zero = summary.add + summary.change + summary.remove + summary.import == 0
            Label(zero ? "No changes" : "Changes", systemImage: zero ? "checkmark" : "arrow.triangle.2.circlepath")
                .font(.system(size: 13))
        } else if details.run.hasChanges == true {
            Label("Changes", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 13))
        }
    }

    private func phase(_ label: String, _ status: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 13))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }

    /// Data-source reads are not changes; when a plan has nothing else they stay
    /// available but collapsed, so a clean plan reads as clean.
    @ViewBuilder private func plannedChanges(_ changes: [HCPRunLogPresentation.Change]) -> some View {
        let reads = changes.filter { $0.action == .Read }
        let realChanges = changes.filter { $0.action != .Read }
        if !realChanges.isEmpty {
            plannedChangeRows(realChanges, title: "Planned changes")
        }
        if !reads.isEmpty {
            DisclosureGroup("\(reads.count) data source\(reads.count == 1 ? "" : "s") read during the plan") {
                plannedChangeRows(reads, title: nil).padding(.top, 6)
            }
            .font(.system(size: 13))
        }
    }

    private func plannedChangeRows(_ changes: [HCPRunLogPresentation.Change], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { sectionTitle(title) }
            ForEach(changes) { change in
                let style = hcpActionStyle(change.action)
                HStack(spacing: 8) {
                    Text(style.word)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(style.color)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(style.color.opacity(0.15)))
                        .frame(minWidth: 64)
                    Text(change.address).font(.system(size: 13, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { hcpCopy(change.address) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy address")
                        .accessibilityLabel("Copy address \(change.address)")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func applyActivity(_ events: [HCPRunLogPresentation.ApplyEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Apply activity")
            ForEach(events) { event in
                let failed = event.outcome == "errored"
                HStack(spacing: 8) {
                    Text(event.address).font(.system(size: 13, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(([event.outcome.capitalized] + [event.elapsedSeconds.map { "\($0)s" }].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(.system(size: 12)).monospacedDigit()
                }
                .foregroundStyle(failed ? Color.red : Color.primary)
            }
        }
    }

    @ViewBuilder private var diagnosticsSection: some View {
        let all = (plan?.diagnostics ?? []).map { ("plan", $0) } + (apply?.diagnostics ?? []).map { ("apply", $0) }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Diagnostics")
                ForEach(Array(all.enumerated()), id: \.offset) { _, entry in
                    let (phaseName, diagnostic) = entry
                    let isError = diagnostic.severity.lowercased() == "error"
                    let color: Color = isError ? .red : .orange
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.summary).font(.system(size: 13, weight: .medium))
                            if let detail = diagnostic.detail {
                                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if let address = diagnostic.address {
                                Text(address).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(diagnostic.severity) in \(phaseName): \(diagnostic.summary)")
                }
            }
        }
    }

    @ViewBuilder private var otherOutput: some View {
        let lines = (plan.map { $0.messages + $0.unparsedLines } ?? []) + (apply.map { $0.messages + $0.unparsedLines } ?? [])
        if !lines.isEmpty {
            DisclosureGroup("Other output") {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color(nsColor: .textBackgroundColor))
            }
            .font(.system(size: 13, weight: .semibold))
        }
    }

    private func rawSection(_ title: String, text: String) -> some View {
        DisclosureGroup(title) {
            ScrollView {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .font(.system(size: 13, weight: .semibold))
    }
}

private struct HCPMapInspectorRequest: Identifiable {
    let id = UUID()
    let address: String?
}

private struct HCPMapResourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let resources: [MapDisplayResource]
    let title: String
    @State private var selectedMapResource: String?

    init(resources: [MapDisplayResource], title: String, selectedAddress: String?) {
        self.resources = resources
        self.title = title
        _selectedMapResource = State(initialValue: selectedAddress)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(title) · Resources").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HSplitView {
                List(selection: $selectedMapResource) {
                    ForEach(resources, id: \.address) { resource in
                        Text(resource.address).font(.system(.callout, design: .monospaced)).tag(resource.address)
                    }
                }.frame(minWidth: 260, idealWidth: 340)
                ScrollView {
                    if let resource = resources.first(where: { $0.address == selectedMapResource }) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(resource.address).font(.headline).textSelection(.enabled)
                            Text(resource.type).foregroundStyle(.secondary)
                            if resource.displayAttributes.isEmpty {
                                Text("Attribute details are unavailable for this state version.").foregroundStyle(.secondary)
                            }
                            ForEach(resource.displayAttributes) { attribute in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(attribute.path).font(.caption).foregroundStyle(.secondary)
                                    Text(attribute.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else {
                        Text("Select a resource to inspect its details.").foregroundStyle(.secondary).padding(24)
                    }
                }.frame(minWidth: 300, maxWidth: .infinity)
            }
        }.frame(minWidth: 700, idealWidth: 850, minHeight: 500)
    }

}


private struct LocalCloudConnectionCard: View {
    let connection: LocalCloudConnection
    let isRefreshing: Bool
    let isConnecting: Bool
    let canConnect: Bool
    let loginMessage: String?
    let onConnect: () -> Void
    @State private var copied = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(connection.name).font(.title3.weight(.semibold))
                    Spacer()
                    Label(isRefreshing ? "Checking…" : connection.status,
                          systemImage: isRefreshing ? "clock" : (connection.isAuthenticated ? "checkmark.circle.fill" : "exclamationmark.circle"))
                        .foregroundStyle(connection.isAuthenticated && !isRefreshing ? Color.green : Color.secondary)
                }
                HStack(spacing: 12) {
                    Button(connection.isAuthenticated ? "Connected" : isConnecting ? "Connecting…" : "Connect", action: onConnect)
                        .buttonStyle(.borderedProminent).disabled(!canConnect)
                        .accessibilityLabel("Connect \(connection.name)")
                    if isConnecting { ProgressView().controlSize(.small) }
                    if let loginMessage {
                        Text(loginMessage).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !connection.isAuthenticated {
                        Text("Opens Terminal and your browser to sign in.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(connection.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Text(connection.loginCommand).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(copied ? "Copied" : "Copy sign-in command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connection.loginCommand, forType: .string)
                        copied = true
                    }.accessibilityLabel("Copy \(connection.name) sign-in command")
                }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
