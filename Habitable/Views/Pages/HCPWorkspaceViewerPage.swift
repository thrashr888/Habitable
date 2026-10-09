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
        return source.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
                                    Text(workspace.name).lineLimit(1)
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
            Text(details.run.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
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
            // A plan-only run has no apply stage; HCP reports it as "unreachable".
            if details.applyStatus?.lowercased() != "unreachable", details.applyStatus != nil || details.run.applyID != nil {
                phase("Apply", details.applyStatus ?? "Available")
            }
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
