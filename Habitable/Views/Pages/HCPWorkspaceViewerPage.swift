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
        let query = workspaceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.workspaces }
        return model.workspaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
                HStack(spacing: 16) {
                    organizationPicker.frame(maxWidth: 270)
                    Button { showingWorkspaces.toggle() } label: { Label("Workspaces", systemImage: "square.grid.2x2") }
                        .accessibilityLabel("Choose cloud workspace")
                        .popover(isPresented: $showingWorkspaces) {
                            workspaceColumn.padding(16).frame(width: 340, height: 480)
                        }
                    Spacer()
                    Picker("Workspace view", selection: $section) {
                        ForEach(HCPWorkspaceSection.allCases) { section in Text(section.rawValue).tag(section) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }.padding(.bottom, 8)
                if section == .map {
                    Divider()
                    cloudMap.frame(minWidth: 550, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if section == .variables {
                    Divider()
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
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    @ViewBuilder private var cloudMap: some View {
        if model.selectedWorkspace == nil {
            Text("Choose a workspace to view its resource map.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
                    .disabled(model.isLoading || model.selectedWorkspaceID == nil)
            }
            if let workspace = model.selectedWorkspace {
                Text(workspace.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            List(selection: runSelection) {
                ForEach(model.runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(run.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline.weight(.medium))
                            Spacer()
                            if run.isDestroy { Image(systemName: "trash").foregroundStyle(.orange).help("Destroy run") }
                        }
                        Text(run.message?.isEmpty == false ? run.message! : run.operation ?? "Terraform run")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let date = run.createdAt {
                            Text(date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details.run.message?.isEmpty == false ? details.run.message! : "Remote run")
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(details.run.id) · \(details.run.status)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = details.runURL { Link("Open in HCP Terraform", destination: url).font(.callout) }
                    }
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                              alignment: .leading, spacing: 12) {
                        phase(label: "Plan", status: details.planStatus ?? (details.run.planID == nil ? "Not available" : "Available"))
                        phase(label: "Apply", status: details.applyStatus ?? (details.run.applyID == nil ? "Not part of this run" : "Available"))
                        if let changes = details.run.hasChanges {
                            Label(changes ? "Changes" : "No changes", systemImage: changes ? "arrow.triangle.2.circlepath" : "checkmark")
                                .font(.callout)
                        }
                    }
                    if let plan = details.planReviewURL { Link("Review plan in HCP Terraform", destination: plan).font(.callout) }
                    if let logs = details.planLogs { logSection("Plan output", text: logs) }
                    if let logs = details.applyLogs { logSection("Apply output", text: logs) }
                    if details.planLogs == nil && details.applyLogs == nil {
                        Text("Run output is unavailable for this account or run phase. Open the run in HCP Terraform for the full event timeline.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
            }
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

    private func phase(label: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline)
        }
    }

    private func logSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(12).background(Color(nsColor: .textBackgroundColor))
        }
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


private struct HCPMapVariablesPanel: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @State private var editing: HCPWorkspaceVariable?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.selectedWorkspace?.name ?? "Workspace").font(.headline)
                Text("Changes affect future runs").font(.callout).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter variables", text: $query).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260).accessibilityLabel("Filter workspace variables")
                Button { Task { await model.refreshVariables() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh workspace variables")
                    .disabled(model.isLoadingVariables || model.savingVariableID != nil)
            }
            if model.isLoadingVariables { ProgressView("Loading variables…") }
            if let error = model.variablesError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(["terraform", "env"], id: \.self) { category in
                        let rows = model.workspaceVariables.filter {
                            $0.category == category && (query.isEmpty || $0.key.localizedCaseInsensitiveContains(query))
                        }
                        if !rows.isEmpty {
                            Text(category == "terraform" ? "Terraform" : "Environment").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .topLeading)], alignment: .leading, spacing: 16) {
                            ForEach(rows) { variable in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top) {
                                        Text(variable.key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        MapCopyButton(value: variable.key, label: "variable name")
                                        Button("Edit") { editing = variable }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel("Edit variable \(variable.key)")
                                            .disabled(model.savingVariableID != nil)
                                    }
                                    if variable.isMaskedForDisplay {
                                        Label("Private value · hidden", systemImage: "lock.fill")
                                            .font(.callout).foregroundStyle(.secondary)
                                    } else {
                                        HStack(alignment: .top) {
                                            Text(variable.value?.isEmpty == false ? variable.value! : "Empty value")
                                                .font(.system(.body, design: .monospaced)).lineLimit(3)
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            if let value = variable.value { MapCopyButton(value: value, label: "variable value") }
                                        }
                                    }
                                    if variable.isHCL { Text("HCL expression").font(.callout).foregroundStyle(.secondary) }
                                    if !variable.description.isEmpty {
                                        Text(variable.description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                            }
                        }
                    }
                    if !query.isEmpty && !model.workspaceVariables.contains(where: { $0.key.localizedCaseInsensitiveContains(query) }) {
                        Text("No matching variables").font(.headline)
                        Button("Clear filter") { query = "" }.buttonStyle(.borderless)
                    }
                    if !model.isLoadingVariables && model.workspaceVariables.isEmpty && model.variablesError == nil {
                        Text("No workspace-specific variables").font(.headline)
                    }
                    Text("Inherited variable sets and values from configuration files are not included here.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let url = model.selectedWorkspace?.htmlURL {
                        Link("Open workspace in HCP Terraform", destination: url)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .task { await model.refreshVariables() }
        .sheet(item: $editing) { variable in
            HCPMapVariableEditor(model: model, variable: variable, sourceKey: model.mapRequestKey)
        }
    }
}

private struct HCPMapVariableEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: HCPWorkspaceViewerModel
    let variable: HCPWorkspaceVariable
    let sourceKey: String
    @State private var value: String
    @State private var didEdit = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(model: HCPWorkspaceViewerModel, variable: HCPWorkspaceVariable, sourceKey: String) {
        self.model = model; self.variable = variable; self.sourceKey = sourceKey
        _value = State(initialValue: variable.isMaskedForDisplay ? "" : (variable.value ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(variable.key)").font(.title2.weight(.semibold))
            Text(model.selectedWorkspace?.name ?? "Workspace").foregroundStyle(.secondary)
            Text("Saving updates this workspace variable in HCP Terraform. It does not start a run or change the current state.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            if variable.isMaskedForDisplay {
                Text("The current value is hidden. Enter a replacement only if you intend to change it.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("Replacement value", text: $value).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Replacement sensitive variable value")
            } else {
                Text(variable.isHCL ? "HCL value" : "Value").font(.headline)
                TextEditor(text: $value).font(.system(.body, design: .monospaced))
                    .frame(height: 140).border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("Variable value")
            }
            if let saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save to HCP Terraform") {
                    guard sourceKey == model.mapRequestKey else { return }
                    isSaving = true; saveError = nil
                    Task {
                        let saved = await model.updateVariable(variableID: variable.id, value: value)
                        isSaving = false
                        if saved { dismiss() } else { saveError = model.variablesError ?? "The variable could not be saved." }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !didEdit || sourceKey != model.mapRequestKey || (!variable.isMaskedForDisplay && value == (variable.value ?? "")))
            }
        }
        .padding(24).frame(width: 510)
        .onChange(of: value) { _ in didEdit = true }
        .onChange(of: model.mapRequestKey) { _ in dismiss() }
        .interactiveDismissDisabled(isSaving)
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
