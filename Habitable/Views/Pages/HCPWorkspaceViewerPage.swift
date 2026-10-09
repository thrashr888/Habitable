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
    /// Folders on this Mac that belong to the selected workspace, and the
    /// window's Check Out action, for the Proposal face.
    var linkedFolders: [URL] = []
    var onCheckOut: (() -> Void)? = nil
    @State private var workspaceSearch = ""
    @State private var faceRequest: MapSideFaceRequest?
    @State private var chosenFolder: URL?
    // Remembered per window so Variables, Runs and Map come back the way they were left.
    @SceneStorage("hcp.section") private var sectionStorage = HCPWorkspaceSection.map.rawValue
    private var section: HCPWorkspaceSection {
        get { HCPWorkspaceSection(rawValue: sectionStorage) ?? .map }
        nonmutating set { sectionStorage = newValue.rawValue }
    }
    @State private var showingWorkspaces = false
    @State private var inspectorRequest: HCPMapInspectorRequest?
    @StateObject private var checkouts = WorkspaceCheckoutStore()

    init(model: HCPWorkspaceViewerModel, connectionOnly: Bool = false,
         onOpenConnections: @escaping () -> Void = {}, onOpenWorkspaces: @escaping () -> Void = {},
         linkedFolders: [URL] = [], onCheckOut: (() -> Void)? = nil) {
        self.model = model; self.connectionOnly = connectionOnly
        self.onOpenConnections = onOpenConnections; self.onOpenWorkspaces = onOpenWorkspaces
        self.linkedFolders = linkedFolders; self.onCheckOut = onCheckOut
    }

    private var filteredWorkspaces: [HCPWorkspace] {
        let source = model.linkedWorkspaceCandidates ?? model.workspaces
        let query = workspaceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(query)
                || workspace.tagNames.contains { $0.localizedCaseInsensitiveContains(query) }
                || (workspace.projectName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if connectionOnly {
                ConnectionsPane(model: model, onOpenWorkspaces: onOpenWorkspaces)
            } else if model.isConnected {
                if section == .map {
                    cloudMap.frame(minWidth: 550, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if section == .variables {
                    HCPMapVariablesPanel(model: model).id(model.mapRequestKey)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        if geometry.size.width >= 960 {
                            // The toolbar's Workspaces chooser is the workspace list; the Runs
                            // section is the workspace's runs beside the chosen run.
                            HSplitView {
                                runColumn.frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
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
        .disclosureGroupStyle(HeaderDisclosureStyle())
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in checkouts.reload() }
        .toolbar {
            if !connectionOnly && model.isConnected {
              QuietToolbar {
                ToolbarItemGroup(placement: .navigation) {
                    // The window title already names the workspace; the chooser names
                    // the collection it opens, as a Finder pop-up would.
                    Button { showingWorkspaces.toggle() } label: {
                        Label(model.selectedWorkspace == nil ? "Choose workspace" : "Workspaces", systemImage: "square.grid.2x2")
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
                if model.isConnected {
                    // Keep the connection and the organization list; reload only workspaces.
                    Task { await model.switchOrganization(organization) }
                } else {
                    model.selectedOrganization = organization
                }
            })) {
                ForEach(model.organizations) { organization in Text(organization.name).tag(organization.name) }
            }
            .labelsHidden().lineLimit(1).accessibilityLabel("HCP Terraform organization")
            .help(model.hostname)
        }
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
                FilterField(placeholder: "Filter workspaces", text: $workspaceSearch, accessibilityLabel: "Filter HCP workspaces")
                    .frame(maxWidth: 220)
                Text("\(filteredWorkspaces.count) of \(model.workspaces.count) workspaces")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
                    workspaceStatusLine(workspace)
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
                                }.font(.system(size: 12)).foregroundStyle(.secondary)
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
        let shown = model.viewingStateVersion != nil ? model.historicalSnapshot : model.mapSnapshot
        ResourceMapContent(title: model.selectedWorkspace?.name ?? "Choose a workspace",
            identity: model.mapRequestKey + "|" + (shown?.versionID ?? ""),
            map: shown?.map, resources: shown?.resources ?? [],
            notice: historyNotice ?? shown?.notice ?? (shown == nil ? nil : "HCP Terraform · Current state"),
            errorMessage: model.historyError ?? model.mapError,
            isLoading: model.isLoadingMap || model.isLoadingHistory, canRefresh: model.selectedWorkspace != nil && !model.isLoadingMap,
            refresh: { Task { await model.refreshMap() } },
            onShowList: { inspectorRequest = HCPMapInspectorRequest(address: nil) },
            onOpenResource: { address in inspectorRequest = HCPMapInspectorRequest(address: address) },
            emptyDetail: shown?.hasStateVersion == false
                ? "No run has applied in this workspace, so there is no state to map. Its runs are in Runs."
                : "This workspace has no managed resources in its current state. Data sources remain available in List; remote run history is available in Runs.",
            emptyTitle: shown?.hasStateVersion == false ? "No state recorded yet" : nil,
            emptyAction: shown?.hasStateVersion == false
                ? MapEmptyAction(title: "Make a change…") { faceRequest = MapSideFaceRequest(faceID: "proposal") }
                : nil,
            workspaceURL: model.selectedWorkspace?.htmlURL,
            stateVersionID: shown?.hasStateVersion == true ? shown?.versionID : nil,
            stateCreatedAt: shown?.stateCreatedAt,
            stateSerial: shown?.stateSerial,
            onShowHistory: { section = .runs },
            onShowVariables: { section = .variables },
            sideFaces: remoteSideFaces,
            sourceDirectory: checkoutFolder, repository: model.selectedWorkspace?.vcs,
            historyBanner: historyNotice.map { text in (text: text, dismiss: { model.returnToCurrentState() }) },
            workspaceDescription: model.selectedWorkspace?.description,
            preview: model.proposalPreview,
            onDiscardPreview: previewedRun.map { run in { Task { await model.discard(run: run) } } },
            onReviewPreview: previewedRun.flatMap { run in
                ["planned", "cost_estimated", "policy_checked"].contains(run.status)
                    ? { Task { await model.confirmApply(run: run) } } : nil
            },
            previewDiscardTitle: previewedRun.map { ["planned", "cost_estimated", "policy_checked"].contains($0.status) } == true ? "Discard Run" : "Hide",
            previewReviewTitle: "Confirm Apply",
            previewCaption: previewCaption,
            faceRequest: faceRequest)
        .task(id: model.mapRequestKey) { await model.refreshMap() }
        .onChange(of: model.requestedFace) { face in
            guard let face else { return }
            section = .map
            faceRequest = MapSideFaceRequest(faceID: face)
            model.requestedFace = nil
        }
        .onAppear {
            if let face = model.requestedFace { faceRequest = MapSideFaceRequest(faceID: face); model.requestedFace = nil }
        }
        Divider()
        MapTimelineStrip(clips: remoteChangeClips, selectedID: model.viewingStateVersion?.runID,
                         hint: model.runs.isEmpty ? "" : "Select a change to see the Map as it was after that run",
                         onSelect: { clip in
                             Task {
                                 // Applied runs have a state version; anything else opens the run itself.
                                 if await model.showStateVersion(forRunID: clip.id) == false {
                                     runSelection.wrappedValue = clip.id
                                     section = .runs
                                 }
                             }
                         }, onShowAll: { section = .runs },
                         newRunTitle: "Make a change",
                         onNewRun: { faceRequest = MapSideFaceRequest(faceID: "proposal") })
        }
        }
    }

    /// Runs and Variables ride the cloud Map's inspector as faces (DESIGN.md §2).
    private var remoteSideFaces: [MapSideFace] {
        [
            // Runs live in the Changes strip; a second list in the inspector was duplicative.
            MapSideFace(id: "variables", title: "Variables",
                        count: model.workspaceVariables.isEmpty ? nil : model.workspaceVariables.count) {
                RemoteVariablesFace(model: model, onOpen: { section = .variables })
            },
            MapSideFace(id: "proposal", title: "Proposal") {
                HCPProposalFace(model: model, folders: proposalFolders, onCheckOut: onCheckOut,
                                onChooseFolder: chooseProposalFolder,
                                onShowRun: { run in Task { await model.showPlanPreview(for: run) } },
                                onOpenSettings: { faceRequest = MapSideFaceRequest(faceID: "settings") })
            },
            MapSideFace(id: "settings", title: "Settings") {
                HCPWorkspaceSettingsFace(model: model)
            }
        ]
    }

    /// Folders a proposal can start from: the window's linked folders, a
    /// checkout, or one chosen for this session.
    private var proposalFolders: [URL] {
        var folders = linkedFolders
        if let checkoutFolder, !folders.contains(checkoutFolder) { folders.append(checkoutFolder) }
        if let chosenFolder, !folders.contains(chosenFolder) { folders.insert(chosenFolder, at: 0) }
        return folders
    }

    private func chooseProposalFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder to upload"
        panel.message = "Choose the Terraform folder whose configuration this run should use."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            chosenFolder = url.standardizedFileURL
        }
    }

    /// The run whose plan is on the Map: the active proposal's run, or one chosen from Latest runs.
    private var previewedRun: HCPRun? {
        let id = model.proposal?.runID ?? model.previewedRunID
        return id.flatMap { id in model.runs.first { $0.id == id } }
    }

    private var previewCaption: String? {
        guard let run = previewedRun else { return nil }
        let word = run.status.replacingOccurrences(of: "_", with: " ")
        let when = run.createdAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return "Plan from HCP Terraform · \(run.message?.isEmpty == false ? run.message! : "Run") · \(word)\(when)"
    }

    private var historyNotice: String? {
        guard let version = model.viewingStateVersion else { return nil }
        var parts = ["State as recorded"]
        if let date = version.createdAt { parts[0] += " \(date.formatted(date: .abbreviated, time: .shortened))" }
        if let serial = version.serial { parts.append("revision \(serial)") }
        return parts.joined(separator: " · ")
    }

    /// A folder this app checked out from the selected workspace, for source lookups.
    private var checkoutFolder: URL? {
        guard let workspace = model.selectedWorkspace else { return nil }
        return checkouts.records(hostname: model.hostname, organization: model.selectedOrganization, workspaceID: workspace.id)
            .first.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
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

    @ViewBuilder private var disconnectedState: some View {
        if model.isLoading {
            // Connecting with a stored credential: say so rather than asking to connect.
            LoadingIndicator(size: 24, label: "Connecting to HCP Terraform…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            disconnectedPrompt
        }
    }

    private var disconnectedPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(model.hasStoredCredential ? "Connect to load your organization" : "Import a credential to get started")
                .font(.headline)
            Text("Browse workspace state and runs, and propose changes. Habitable never applies from your Mac; runs happen in HCP Terraform and you confirm them here.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480) }
            Button("Open connection settings", action: onOpenConnections).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workspaces").font(.headline)
                Spacer()
                Text("\(model.workspaces.count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FilterField(placeholder: "Filter workspaces", text: $workspaceSearch)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredWorkspaces) { workspace in
                        Button { workspaceSelection.wrappedValue = workspace.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(workspace.name).lineLimit(1)
                                        if let project = workspace.projectName {
                                            Text(project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    workspaceStatusLine(workspace)
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
            if let workspace = model.selectedWorkspace {
                workspaceHeader(workspace)
                Divider().padding(.vertical, 4)
            }
            HStack {
                Text("Runs").font(.headline)
                Spacer()
                Button { Task { await model.refreshRuns(force: false) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh run history")
                    .accessibilityLabel("Refresh run history")
                    .disabled(model.isLoading || model.selectedWorkspaceID == nil)
            }
            List(selection: runSelection) {
                ForEach(model.runs) { run in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(hcpRunTitle(run))
                                .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
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
                        if let provenance = runProvenance(run) {
                            Text(provenance).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(run.id))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if model.runHasNextPage {
                Button("Load More Runs") { Task { await model.loadNextRunPage() } }
                    .buttonStyle(.borderless).disabled(model.isLoading)
            }
        }
    }

    private func runProvenance(_ run: HCPRun) -> String? { hcpRunProvenance(run) }

    /// The workspace's latest run as HCP recorded it: dot, word, when. Locked when it is.
    @ViewBuilder private func workspaceStatusLine(_ workspace: HCPWorkspace) -> some View {
        HStack(spacing: 6) {
            if let status = workspace.currentRunStatus {
                HCPRunStatusLabel(status: status)
                if let date = workspace.currentRunCreatedAt { Text("· \(hcpRelativeDate(date))").foregroundStyle(.secondary) }
            } else {
                Text("No runs yet").foregroundStyle(.secondary)
            }
            if workspace.locked { Image(systemName: "lock").foregroundStyle(.secondary).help("Workspace locked") }
        }
        .font(.system(size: 12))
    }

    /// What HCP Terraform's workspace page says at the top, in one card: status,
    /// repository, resources, project, Terraform, execution mode, auto-apply, links.
    private func workspaceHeader(_ workspace: HCPWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(workspace.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                if let url = workspace.htmlURL {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open workspace in HCP Terraform").accessibilityLabel("Open workspace in HCP Terraform")
                }
            }
            workspaceStatusLine(workspace).font(.system(size: 13))
            if let description = workspace.description {
                Text(description).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let vcs = workspace.vcs, let identifier = vcs.identifier {
                    fact("Repository") {
                        // Only a web URL becomes a link; anything else is shown as text.
                        if let url = vcs.repositoryHTTPURL, url.scheme?.lowercased() == "https" {
                            Link(identifier + (vcs.branch.map { " · \($0)" } ?? ""), destination: url).lineLimit(1)
                        } else {
                            Text(identifier)
                        }
                    }
                } else {
                    fact("Repository") { Text("None · API and CLI runs") }
                }
                if let count = workspace.resourceCount { fact("Resources") { Text("\(count)") } }
                if let project = workspace.projectName { fact("Project") { Text(project) } }
                fact("Terraform") { Text(workspace.terraformVersion ?? "latest") }
                fact("Runs") { Text((workspace.executionMode ?? "remote").capitalized + (workspace.autoApply ? " · applies without confirmation" : " · apply waits for confirmation")) }
                if !workspace.tagNames.isEmpty { fact("Tags") { Text(workspace.tagNames.joined(separator: ", ")).lineLimit(1) } }
            }
            HStack(spacing: 14) {
                Button("Map") { section = .map }.buttonStyle(.link)
                Button("Variables") { section = .variables }.buttonStyle(.link)
                Button("Settings") { section = .map; faceRequest = MapSideFaceRequest(faceID: "settings") }.buttonStyle(.link)
                Button("Make a change") { section = .map; faceRequest = MapSideFaceRequest(faceID: "proposal") }.buttonStyle(.link)
            }
            .font(.system(size: 13))
        }
    }

    private func fact<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            value().font(.system(size: 13))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var runDetail: some View {
        if let details = model.selectedRunDetails {
            HCPRunDetailView(details: details, listedRun: model.runs.first { $0.id == details.run.id },
                             executionMode: model.selectedWorkspace?.executionMode)
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

/// A commit message's first line; bodies and blank lines stay out of the list.
private func hcpRunTitle(_ run: HCPRun) -> String {
    let first = run.message?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return first.isEmpty ? (run.operation?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Terraform run") : first
}

/// "VCS · master · 6b85f52 · thrashr888" or "API · pthrasher": how a run came to be.
private func hcpRunProvenance(_ run: HCPRun) -> String? {
    var parts: [String] = []
    if let word = run.sourceWord { parts.append(word) }
    if let number = run.pullRequestNumber { parts.append("PR #\(number)") }
    if let branch = run.branch { parts.append(branch) }
    if let sha = run.shortSHA { parts.append(sha) }
    if let who = run.sender ?? run.createdBy { parts.append(who) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    /// The same run as the list holds it, with provenance from the page's includes.
    var listedRun: HCPRun? = nil
    var executionMode: String? = nil
    @State private var plan: HCPRunLogPresentation?
    @State private var apply: HCPRunLogPresentation?
    /// Stage cards the person opened or closed; stages not listed follow the run's progress.
    @State private var stageOverrides: [String: Bool] = [:]

    /// The run with provenance: the detail fetch carries it; the list copy fills any gaps.
    private var run: HCPRun {
        var merged = details.run
        if let listed = listedRun {
            merged.source = merged.source ?? listed.source
            merged.createdBy = merged.createdBy ?? listed.createdBy
            merged.branch = merged.branch ?? listed.branch
            merged.commitSHA = merged.commitSHA ?? listed.commitSHA
            merged.commitURL = merged.commitURL ?? listed.commitURL
            merged.sender = merged.sender ?? listed.sender
            merged.pullRequestNumber = merged.pullRequestNumber ?? listed.pullRequestNumber
            merged.triggerReason = merged.triggerReason ?? listed.triggerReason
            merged.commitMessage = merged.commitMessage ?? listed.commitMessage
            merged.repositoryIdentifier = merged.repositoryIdentifier ?? listed.repositoryIdentifier
        }
        return merged
    }

    /// "GitHub" when the commit link says so, else the repository host, else "VCS".
    private var vcsHostWord: String {
        guard let host = run.commitURL?.host?.lowercased() else { return "VCS" }
        if host.contains("github") { return "GitHub" }
        if host.contains("gitlab") { return "GitLab" }
        if host.contains("bitbucket") { return "Bitbucket" }
        if host.contains("dev.azure") { return "Azure DevOps" }
        return host
    }

    private var statusWord: String { details.run.status.replacingOccurrences(of: "_", with: " ").capitalized }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                summaryStrip
                if needsConfirmation, let review = details.planReviewURL {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Color.accentColor)
                        Text("This plan is waiting for a confirmation.").font(.system(size: 13))
                        Link("Review in HCP Terraform", destination: review).font(.system(size: 13))
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                stageCard("details", title: "Run details", symbol: "list.bullet.rectangle", color: .secondary,
                          when: run.createdAt, trailing: triggeredBy) { runDetailsFacts }
                if details.planStatus != nil || plan != nil {
                    stageCard("plan", title: "Plan " + stageWord(details.planStatus ?? "pending"),
                              symbol: stageSymbol(details.planStatus), color: stageColor(details.planStatus),
                              when: details.planFinishedAt ?? details.planStartedAt, trailing: planTrailing) {
                        VStack(alignment: .leading, spacing: 14) {
                            if let started = details.planStartedAt {
                                timing(started: started, finished: details.planFinishedAt)
                            }
                            if let plan, !plan.plannedChanges.isEmpty { plannedChanges(plan.plannedChanges) }
                            else if let summary = plan?.summary, summary.add + summary.change + summary.remove + summary.import == 0 {
                                Text("No changes. Infrastructure matches the configuration.").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            diagnostics(for: "plan", plan?.diagnostics ?? [])
                            otherOutput(plan)
                        }
                    }
                }
                if !details.policyChecks.isEmpty {
                    let worst = details.policyChecks.contains { $0.hardFailed > 0 } ? "failed" : (details.policyChecks.contains { $0.softFailed > 0 || $0.advisoryFailed > 0 } ? "soft_failed" : "passed")
                    stageCard("policy", title: "Policy check " + stageWord(worst), symbol: stageSymbol(worst), color: stageColor(worst),
                              when: nil, trailing: Text(policySummary)) { policySection }
                }
                if let estimate = details.costEstimate {
                    stageCard("cost", title: "Cost estimate " + stageWord(estimate.status), symbol: stageSymbol(estimate.status),
                              color: stageColor(estimate.status), when: nil, trailing: Text(costSummary)) { costSection(estimate) }
                }
                if !details.taskStages.isEmpty {
                    let results = details.taskStages.flatMap(\.results)
                    let worst = results.contains { $0.status == "failed" } ? "failed" : (results.allSatisfy { $0.status == "passed" } ? "passed" : "running")
                    stageCard("tasks", title: "Run tasks " + stageWord(worst), symbol: stageSymbol(worst), color: stageColor(worst),
                              when: nil, trailing: Text(taskSummary)) { taskSection }
                }
                if hasApplyStage {
                    stageCard("apply", title: "Apply " + stageWord(details.applyStatus ?? "pending"),
                              symbol: stageSymbol(details.applyStatus), color: stageColor(details.applyStatus),
                              when: details.applyFinishedAt ?? details.applyStartedAt, trailing: applyTrailing) {
                        VStack(alignment: .leading, spacing: 14) {
                            if let started = details.applyStartedAt {
                                timing(started: started, finished: details.applyFinishedAt)
                            }
                            if let apply, !apply.applyEvents.isEmpty { applyActivity(apply.applyEvents) }
                            if !details.outputs.isEmpty { outputsSection }
                            diagnostics(for: "apply", apply?.diagnostics ?? [])
                            otherOutput(apply)
                        }
                    }
                }
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
        // A new run, or a run that moved on: the cards follow its progress again.
        .onChange(of: details.run.id) { _ in stageOverrides = [:] }
        .onChange(of: details.run.status) { _ in stageOverrides = [:] }
    }

    // MARK: Stages

    private var needsConfirmation: Bool {
        ["planned", "cost_estimated", "policy_checked", "policy_override", "post_plan_awaiting_decision", "pre_apply_awaiting_decision"].contains(details.run.status)
    }

    private var hasApplyStage: Bool {
        details.applyStatus?.lowercased() != "unreachable" && (details.applyStatus != nil || details.run.applyID != nil || apply != nil)
    }

    private var isRunFinished: Bool { !details.run.isActive }

    /// Which stage is live: pending or running stages are open; when the run is
    /// over, the last stage stays open so the outcome is in view.
    private func stageOpenByDefault(_ key: String) -> Bool {
        switch key {
        case "details": return false
        case "plan":
            if let status = details.planStatus, Self.activeStageStatuses.contains(status) { return true }
            return needsConfirmation || !hasApplyStage && isRunFinished
        case "apply":
            if let status = details.applyStatus, Self.activeStageStatuses.contains(status) { return true }
            return isRunFinished
        case "policy", "cost", "tasks":
            return needsConfirmation && !hasApplyStage
        default: return false
        }
    }
    private static let activeStageStatuses: Set<String> = ["pending", "queued", "running", "managed_queued", "mfa_waiting"]

    private func isStageOpen(_ key: String) -> Binding<Bool> {
        Binding(get: { stageOverrides[key] ?? stageOpenByDefault(key) },
                set: { stageOverrides[key] = $0 })
    }

    private func stageCard<Content: View, Trailing: View>(_ key: String, title: String, symbol: String, color: Color, when: Date?,
                                                           trailing: Trailing, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isStageOpen(key).wrappedValue.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isStageOpen(key).wrappedValue ? 90 : 0)).frame(width: 12)
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let when { Text(hcpRelativeDate(when)).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    trailing.font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isStageOpen(key).wrappedValue ? "Expanded" : "Collapsed")
            if isStageOpen(key).wrappedValue {
                content().padding(.top, 12)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.15), value: isStageOpen(key).wrappedValue)
    }

    private func stageWord(_ status: String) -> String {
        switch status {
        case "finished", "passed": return status == "passed" ? "passed" : "finished"
        case "errored": return "errored"
        case "canceled": return "canceled"
        case "running": return "running"
        case "pending", "queued": return "pending"
        case "unreachable": return "skipped"
        case "soft_failed": return "passed with advisories"
        case "hard_failed", "failed": return "failed"
        default: return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func stageSymbol(_ status: String?) -> String {
        switch status {
        case "finished", "passed", "applied": return "checkmark.circle.fill"
        case "errored", "hard_failed", "failed": return "xmark.octagon.fill"
        case "canceled", "unreachable": return "minus.circle"
        case "running", "queued", "pending": return "circle.dotted"
        case "soft_failed": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private func stageColor(_ status: String?) -> Color {
        switch status {
        case "finished", "passed", "applied": return .green
        case "errored", "hard_failed", "failed": return .red
        case "running", "queued", "pending": return .orange
        case "soft_failed": return .orange
        default: return .secondary
        }
    }

    private func timing(started: Date, finished: Date?) -> some View {
        HStack(spacing: 6) {
            Text("Started").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(hcpRelativeDate(started)).font(.system(size: 12)).foregroundStyle(.secondary)
            if let finished {
                Text("›").foregroundStyle(.tertiary)
                Text("Finished").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(hcpRelativeDate(finished)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("· \(durationWord(from: started, to: finished))").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func durationWord(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "less than a minute" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    @ViewBuilder private var planTrailing: some View {
        if let summary = plan?.summary {
            let replaces = plan?.replaceCount ?? 0
            Text("+\(max(0, summary.add - replaces)) ~\(summary.change) −\(max(0, summary.remove - replaces))" + (replaces > 0 ? " ±\(replaces)" : ""))
                .monospacedDigit()
        } else {
            changeStateLabel
        }
    }

    @ViewBuilder private var applyTrailing: some View {
        if let apply, let summary = apply.summary {
            Text("+\(summary.add) ~\(summary.change) −\(summary.remove)").monospacedDigit()
        }
    }

    /// "thrashr888 triggered a run from GitHub" / "pthrasher triggered a run through the API".
    @ViewBuilder private var triggeredBy: some View {
        let who = run.sender ?? run.createdBy
        let how: String? = {
            switch run.source {
            case "tfe-configuration-version", "tfe-vcs": return "from " + vcsHostWord
            case "tfe-api": return "through the API"
            case "tfe-ui": return "in HCP Terraform"
            case "terraform+cloud", "terraform", "tfe-cli": return "from the CLI"
            case "tfe-infrastructure-lifecycle": return "by the workspace lifecycle"
            case "tfe-run-trigger": return "by a run trigger"
            default: return nil
            }
        }()
        if who != nil || how != nil {
            Text([who, "triggered a run", how].compactMap { $0 }.joined(separator: " ")).lineLimit(1)
        }
    }

    private var runDetailsFacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow("Run ID") {
                HStack(spacing: 6) {
                    Text(details.run.id).font(.system(size: 13, design: .monospaced))
                    MapCopyButton(value: details.run.id, label: "run ID")
                }
            }
            detailRow("Configuration") {
                HStack(spacing: 14) {
                    Text(configurationWord)
                    if let branch = run.branch { HStack(spacing: 4) { Text("Branch").foregroundStyle(.secondary); Text(branch) } }
                    if let identifier = run.repositoryIdentifier {
                        HStack(spacing: 4) {
                            Text("Repo").foregroundStyle(.secondary)
                            if let base = run.commitURL.flatMap({ URL(string: "https://\($0.host ?? "")/\(identifier)") }), run.commitURL?.scheme == "https" {
                                Link(identifier, destination: base)
                            } else { Text(identifier) }
                        }
                    }
                }
            }
            if let sha = run.shortSHA {
                detailRow("Commit") {
                    HStack(spacing: 6) {
                        if let url = run.commitURL { Link(sha, destination: url).font(.system(size: 13, design: .monospaced)) }
                        else { Text(sha).font(.system(size: 13, design: .monospaced)) }
                        if let message = run.commitMessage { Text(message).lineLimit(1) }
                    }
                }
            }
            if let number = run.pullRequestNumber { detailRow("Pull request") { Text("#\(number)") } }
            if let trigger = run.triggerWord { detailRow("Trigger") { Text(trigger) } }
            if let mode = executionMode { detailRow("Execution mode") { Text(mode.capitalized) } }
            if let operation = run.operation, operation != "plan_and_apply" {
                detailRow("Operation") { Text(operation.replacingOccurrences(of: "_", with: " ").capitalized) }
            }
        }
        .font(.system(size: 13))
    }

    private var configurationWord: String {
        let who = run.sender ?? run.createdBy
        switch run.source {
        case "tfe-configuration-version", "tfe-vcs": return "From " + vcsHostWord + (who.map { " by \($0)" } ?? "")
        case "tfe-api": return "Uploaded through the API" + (who.map { " by \($0)" } ?? "")
        case "tfe-ui": return "Started in HCP Terraform" + (who.map { " by \($0)" } ?? "")
        case "terraform+cloud", "terraform", "tfe-cli": return "Uploaded from the CLI" + (who.map { " by \($0)" } ?? "")
        case "tfe-infrastructure-lifecycle": return "Workspace lifecycle"
        case "tfe-run-trigger": return "Run trigger"
        case let other?: return other.replacingOccurrences(of: "tfe-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
        case nil: return who.map { "By \($0)" } ?? "Unknown"
        }
    }

    private func detailRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    /// HCP's top strip: policy, cost, duration, resources changed, run tasks, outputs.
    private var summaryStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
            phase("Policy checks", verbatim: policySummary)
            phase("Cost estimate", verbatim: costSummary)
            if let start = details.planStartedAt, let end = details.applyFinishedAt ?? details.planFinishedAt {
                phase("Plan & apply duration", verbatim: durationWord(from: start, to: end).capitalizedFirst)
            }
            resourcesChanged
            phase("Run tasks", verbatim: taskSummary)
            phase("Outputs", verbatim: details.outputs.isEmpty ? "None" : "\(details.outputs.count)")
        }
    }

    @ViewBuilder private var resourcesChanged: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Resources changed").font(.system(size: 12)).foregroundStyle(.secondary)
            if let summary = plan?.summary ?? apply?.summary {
                let replaces = plan?.replaceCount ?? apply?.replaceCount ?? 0
                HStack(spacing: 8) {
                    Text("+\(max(0, summary.add - replaces))").foregroundStyle(summary.add - replaces > 0 ? .green : .secondary)
                    Text("~\(summary.change)").foregroundStyle(summary.change > 0 ? .orange : .secondary)
                    if replaces > 0 { Text("±\(replaces)").foregroundStyle(hcpReplaceColor) }
                    Text("−\(max(0, summary.remove - replaces))").foregroundStyle(summary.remove - replaces > 0 ? .red : .secondary)
                }
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            } else {
                changeStateLabel
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(details.run.message?.isEmpty == false ? details.run.message! : "Remote run")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: stageSymbol(details.run.status == "applied" || details.run.status == "planned_and_finished" ? "finished" : (needsConfirmation ? "pending" : details.run.status)))
                    Text(statusWord)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hcpStatusColor(details.run.status))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(hcpStatusColor(details.run.status).opacity(0.14), in: Capsule())
            }
            HStack(spacing: 4) {
                if let date = details.run.createdAt { Text(hcpRelativeDate(date)).font(.system(size: 13)).foregroundStyle(.secondary) }
                if let url = details.runURL {
                    Text("·").foregroundStyle(.secondary)
                    Link("Open in HCP Terraform", destination: url).font(.system(size: 13))
                }
            }
            .accessibilityElement(children: .contain)
            if (plan?.diagnostics.isEmpty == false) || (apply?.diagnostics.isEmpty == false) {
                Label("Diagnostics were found in this run", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
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

    /// `status` is an HCP status word (snake_case) and gets title-cased; pass
    /// `verbatim:` for text that is already written for people.
    private func phase(_ label: String, _ status: String) -> some View {
        phase(label, verbatim: status.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private func phase(_ label: String, verbatim text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13))
        }
    }

    /// "$12.34/mo" from HCP's decimal strings.
    private func money(_ text: String?) -> String {
        guard let text, let value = Double(text) else { return "—" }
        return "$" + String(format: "%.2f", value) + "/mo"
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

    @ViewBuilder private func diagnostics(for phaseName: String, _ list: [HCPRunLogPresentation.Diagnostic]) -> some View {
        if !list.isEmpty {
            let errors = list.filter { $0.severity.lowercased() == "error" }.count
            DisclosureGroup(isExpanded: Binding(get: { showDiagnostics[phaseName] ?? (errors > 0) },
                                                set: { showDiagnostics[phaseName] = $0 })) {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, diagnostic in
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
              .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(errors > 0 ? Color.red : Color.orange)
                    Text("Diagnostics · \(list.count)").font(.system(size: 13, weight: .semibold))
                }
            }
        }
    }

    @State private var showDiagnostics: [String: Bool] = [:]

    private var policySummary: String {
        guard !details.policyChecks.isEmpty else { return "None" }
        let passed = details.policyChecks.reduce(0) { $0 + $1.passed }
        let total = details.policyChecks.reduce(0) { $0 + $1.passed + $1.totalFailed }
        return total == 0 ? details.policyChecks.first!.status.replacingOccurrences(of: "_", with: " ").capitalized : "\(passed) of \(total) passed"
    }

    private var costSummary: String {
        guard let estimate = details.costEstimate else { return "None" }
        if let delta = estimate.deltaMonthlyCost, let value = Double(delta) {
            if value == 0 { return "No change" }
            return (value > 0 ? "+" : "−") + "$" + String(format: "%.2f", abs(value)) + "/mo"
        }
        return estimate.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var taskSummary: String {
        let results = details.taskStages.flatMap(\.results)
        guard !results.isEmpty else { return "None" }
        let passed = results.filter { $0.status == "passed" }.count
        return "\(passed) of \(results.count) passed"
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(details.policyChecks) { check in
                HStack(spacing: 8) {
                    Circle().fill(check.hardFailed > 0 ? Color.red : (check.softFailed > 0 || check.advisoryFailed > 0 ? .orange : .green)).frame(width: 8, height: 8)
                    Text((check.kind ?? check.scope ?? "Policy").capitalized).font(.system(size: 13, weight: .medium))
                    Text("\(check.passed) passed" + (check.totalFailed > 0 ? " · \(check.totalFailed) failed" : ""))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if check.hardFailed > 0 { Text("· \(check.hardFailed) hard").font(.system(size: 13)).foregroundStyle(.red) }
                    if check.softFailed > 0 { Text("· \(check.softFailed) soft").font(.system(size: 13)).foregroundStyle(.orange) }
                    if check.advisoryFailed > 0 { Text("· \(check.advisoryFailed) advisory").font(.system(size: 13)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(check.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func costSection(_ estimate: HCPCostEstimate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = estimate.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 12) {
                    phase("Before", verbatim: money(estimate.priorMonthlyCost))
                    phase("After", verbatim: money(estimate.proposedMonthlyCost))
                    phase("Change", verbatim: costSummary)
                    if let matched = estimate.matchedResourcesCount, let count = estimate.resourcesCount {
                        phase("Priced", verbatim: "\(matched) of \(count) resources")
                    }
                }
            }
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(details.taskStages) { stage in
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.stage.replacingOccurrences(of: "_", with: "-").capitalized)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(stage.results) { result in
                        HStack(spacing: 8) {
                            Circle().fill(result.status == "passed" ? Color.green : (result.status == "failed" ? .red : .orange)).frame(width: 8, height: 8)
                            Text(result.taskName).font(.system(size: 13, weight: .medium))
                            if let message = result.message, !message.isEmpty {
                                Text(message).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let level = result.enforcementLevel { Text(level.capitalized).font(.system(size: 12)).foregroundStyle(.secondary) }
                            if let url = result.url { Link("Details", destination: url).font(.system(size: 12)) }
                        }
                    }
                }
            }
        }
    }

    /// Terraform outputs from the state this run produced; sensitive values stay hidden.
    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Outputs")
            ForEach(details.outputs) { output in
                HStack(alignment: .top, spacing: 10) {
                    Text(output.name).font(.system(size: 13, weight: .medium)).frame(width: 160, alignment: .leading).lineLimit(1)
                    if let value = output.value {
                        Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(6)
                        MapCopyButton(value: value, label: "output \(output.name)")
                    } else {
                        Text("Sensitive value hidden").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder private func otherOutput(_ presentation: HCPRunLogPresentation?) -> some View {
        let lines = presentation.map { $0.messages + $0.unparsedLines } ?? []
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
                        Text(resource.address).font(.system(size: 13, design: .monospaced)).tag(resource.address)
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
                                    Text(attribute.path).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Text(attribute.value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
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

/// Compact Variables face for the cloud Map. Masked values stay masked;
/// editing happens on the Variables page.
private struct RemoteVariablesFace: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoadingVariables && model.workspaceVariables.isEmpty {
                LoadingIndicator(size: 18, label: "Loading variables…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.variablesError, model.workspaceVariables.isEmpty {
                Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else if model.workspaceVariables.isEmpty {
                Text("This workspace has no variables.").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.workspaceVariables) { variable in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(variable.key).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text(variable.category == "env" ? "Environment" : "Terraform")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                if variable.isMaskedForDisplay {
                                    Label("Private value · hidden", systemImage: "lock.fill")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                } else {
                                    Text(variable.value?.isEmpty == false ? variable.value! : "Empty value")
                                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onOpen)
                            .accessibilityElement(children: .combine)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            Divider()
            Button("Open Variables", action: onOpen).buttonStyle(.link).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .task(id: model.mapRequestKey) {
            if model.workspaceVariables.isEmpty, !model.isLoadingVariables { await model.refreshVariables() }
        }
    }
}


private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
