import AppKit
import SwiftUI
import Combine
import os

struct WorkspaceWindowActions {
    let recentFolders: [URL]
    let openFolder: () -> Void
    let openRecent: (URL) -> Void
    let clearRecents: () -> Void
    let plan: () -> Void
    let initialize: () -> Void
    let validate: () -> Void
    let canPlan: Bool
    let canInitialize: Bool
    let canValidate: Bool
    let planTitle: String
}

private struct WorkspaceWindowActionsKey: FocusedValueKey {
    typealias Value = WorkspaceWindowActions
}

extension FocusedValues {
    var workspaceWindowActions: WorkspaceWindowActions? {
        get { self[WorkspaceWindowActionsKey.self] }
        set { self[WorkspaceWindowActionsKey.self] = newValue }
    }
}

struct ContentView: View {
    enum NavigationItem: String {
        case map, workspace, readme, configuration, runs, resources, outputs, variables, envVariables, settings

        var title: String {
            switch self {
            case .map: "Map"
            case .workspace: "Workspace"
            case .readme: "README"
            case .configuration: "Configuration"
            case .runs: "Runs"
            case .resources: "Resources"
            case .outputs: "Outputs"
            case .variables: "Variables"
            case .envVariables: "Environment Variables"
            case .settings: "Settings"
            }
        }

        var hasDetailList: Bool {
            self == .runs || self == .resources || self == .outputs
        }
    }

    @StateObject var workspace: Workspace

    @Environment(\.openWindow) private var openWindow
    private let onOpenRemoteWorkspace: (TerraformRemoteWorkspaceLink) -> Void
    /// Shared with the cloud and Settings windows; the Library lists its workspaces.
    @ObservedObject private var cloud: HCPWorkspaceViewerModel
    /// App-wide agent server; this window offers its folder while it is the one in use.
    @ObservedObject private var agentAccess: HabitableAgentAccess
    @StateObject private var library = LibraryModel()
    @StateObject private var checkouts = WorkspaceCheckoutStore()
    @State private var remoteWorkspaceLink: TerraformRemoteWorkspaceLink?

    /// `initialDirectory` is supplied when another window opens a specific
    /// folder (for example a cloud workspace's linked local checkout).
    /// Opening a window with this value shows the Library instead of restoring
    /// the last folder (File › Library, or the Library toolbar button).
    static let libraryURL = URL(string: "habitable://library")!

    init(initialDirectory: URL? = nil, cloud: HCPWorkspaceViewerModel, agentAccess: HabitableAgentAccess,
         onOpenRemoteWorkspace: @escaping (TerraformRemoteWorkspaceLink) -> Void = { _ in }) {
        self.onOpenRemoteWorkspace = onOpenRemoteWorkspace
        self.cloud = cloud
        self.agentAccess = agentAccess
        let wantsLibrary = initialDirectory == Self.libraryURL
        let directory = wantsLibrary ? nil : initialDirectory
        // Settings › General › "Open last folder at launch".
        let restoreLast = UserDefaults.standard.object(forKey: "general.restoreLastFolder") as? Bool ?? true
        _workspace = StateObject(wrappedValue: Workspace(
            dir: directory, restoreLastDirectory: directory == nil && !wantsLibrary && restoreLast,
            autoInitializeOnOpen: !HabitableAppDelegate.consumeExternal(directory)))
    }
    @StateObject private var recentWorkspaces = RecentWorkspaceStore()
    @StateObject private var configurationModel = ConfigurationModel()
    @StateObject private var releaseCatalog = TerraformReleaseCatalog()
    @StateObject private var editors = ExternalEditorStore()
    @StateObject private var readme = WorkspaceReadmePresentation()
    @StateObject private var navigationTrace = NavigationTrace()
    @State private var selection: NavigationItem? = .map
    @State private var selectedRun: UUID?
    /// The run whose saved plan the Map is previewing, and a tick that re-renders
    /// when that run's own published state (plan result, status) changes.
    @State private var previewRunID: UUID?
    @State private var previewTick = 0
    @State private var mapSelectionRequest: MapSelectionRequest?
    @State private var selectedRunDetail: TerraformRun?
    @State private var selectedResource: String?
    @State private var selectedOutput: String?
    @State private var showMissingInputs = false
    @State private var declarationRequest: ConfigurationDeclarationRequest?
    @State private var isOpenErrorPresented = false
    @State private var presentedOpenError: String?

    var body: some View {
        configuredWindowContent
        .task(id: workspace.workingDirectory) {
            remoteWorkspaceLink = nil
            guard let directory = workspace.workingDirectory else { return }
            var link = await Task.detached(priority: .utility) {
                TerraformRemoteWorkspaceLink.resolve(workingDirectory: directory)
            }.value
            guard !Task.isCancelled, directory == workspace.workingDirectory else { return }
            if link == nil, let record = checkouts.record(forPath: directory),
               let url = URL(string: "https://\(record.hostname)/app/\(record.organization)/workspaces/\(record.workspaceName)") {
                // A folder Habitable cloned from a workspace is linked to it even before init.
                link = TerraformRemoteWorkspaceLink(hostname: record.hostname, organization: record.organization,
                    selector: .name(record.workspaceName), source: .checkout(workspaceID: record.workspaceID), url: url)
            }
            remoteWorkspaceLink = link
        }
        .onChange(of: workspace.workspaceOpenError) { error in
            if let error {
                presentedOpenError = error
                isOpenErrorPresented = true
            }
        }
        .onChange(of: workspace.workingDirectory) { directory in
            offerToAgents()
            if let directory, isAvailableDirectory(directory) {
                recentWorkspaces.recordSuccessfulOpen(directory)
                navigationSelection.wrappedValue = .map
            }
        }
        .alert("Unable to Open Folder", isPresented: $isOpenErrorPresented) {
            Button("OK", role: .cancel) { workspace.dismissWorkspaceOpenError() }
        } message: {
            Text(presentedOpenError ?? "The selected folder could not be opened.")
        }
        .onAppear {
            offerToAgents()
            editors.refresh()
            if let directory = workspace.workingDirectory, isAvailableDirectory(directory) {
                recentWorkspaces.recordSuccessfulOpen(directory)
            }
            if let error = workspace.workspaceOpenError {
                presentedOpenError = error
                isOpenErrorPresented = true
            }
        }
        .onChange(of: workspace.workingDirectory) { _ in
            selectedRun = nil
            selectedRunDetail = nil
            selectedResource = nil
            selectedOutput = nil
        }
        .onDisappear { agentAccess.deactivate(workspace) }
        .background(WindowKeyObserver(onBecomeKey: offerToAgents))
        // The folder is the window's represented file: proxy icon, and one window per folder.
        .background(WindowMenuMembership(folder: workspace.workingDirectory))
        .onReceive(previewRun?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            previewTick &+= 1
        }
        .onChange(of: selectedRun) { id in
            selectedRunDetail = workspace.runs.first { $0.id == id }
                ?? (workspace.latestOverviewRun?.id == id ? workspace.latestOverviewRun : nil)
        }
        .onChange(of: workspace.runs.map(\.id)) { _ in
            if let run = workspace.runs.first(where: { $0.id == selectedRun }) {
                selectedRunDetail = run
            }
        }
        .onChange(of: workspace.state?.id) { _ in
            if let selectedResource, let state = workspace.state,
               !state.resources.contains(where: { ($0.address ?? $0.id.uuidString) == selectedResource }) {
                self.selectedResource = nil
            }
            if let selectedOutput, let state = workspace.state,
               !state.outputs.contains(where: { $0.key == selectedOutput }) {
                self.selectedOutput = nil
            }
        }
    }


    private var configuredWindowContent: some View {
        windowContent
        .navigationTitle(workspace.workingDirectory == nil ? "Library" : workspaceName)
        .navigationSubtitle(workspaceSubtitle)
        .environmentObject(workspace)
        .environmentObject(editors)
        .buttonStyle(.borderless)
        .groupBoxStyle(QuietGroupBoxStyle())
        .animation(nil, value: selection)
        .background(NavigationLayoutProbe(trace: navigationTrace, page: selection?.rawValue ?? "workspace")
            .allowsHitTesting(false))
        .disclosureGroupStyle(FullHeaderDisclosureStyle())
        .focusedSceneValue(\.workspaceWindowActions, windowActions)
        .toolbar {
          QuietToolbar {
            if workspace.workingDirectory != nil {
                ToolbarItemGroup(placement: .navigation) {
                    Picker("View", selection: viewModeSelection) {
                        Text("Map").tag(ViewMode.map)
                        Text("List").tag(ViewMode.list)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 132)
                    .help("Map shows resources grouped by what they do. List is the complete table.")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(windowActions.planTitle) { windowActions.plan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!windowActions.canPlan)
                        .help(workspace.autoApply
                              ? "Preview changes, then apply them automatically when the preview succeeds"
                              : "Preview what Terraform would change. Nothing changes until you apply.")
                    Button { navigationSelection.wrappedValue = .variables } label: { Label("Inputs", systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon) }
                        .help("Terraform input variables for this folder")
                    Button { navigationSelection.wrappedValue = .runs } label: { Label("Changes", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon) }
                        .help("Previewed and applied changes")
                    Menu {
                        Button("Overview") { navigationSelection.wrappedValue = .workspace }
                        Button("About (README)") { navigationSelection.wrappedValue = .readme }
                        Button("Source files") { navigationSelection.wrappedValue = .configuration }
                        Button("Outputs") { navigationSelection.wrappedValue = .outputs }
                        Button("Environment variables") { navigationSelection.wrappedValue = .envVariables }
                        Divider()
                        Button("Workspace settings…") { navigationSelection.wrappedValue = .settings }
                    } label: { Label("Workspace", systemImage: "info.circle") }
                    .help("Workspace details and settings")
                }
            }
            ToolbarItemGroup(placement: .automatic) {
                if workspace.workingDirectory != nil {
                    Button { openWindow(id: "Workspace.viewer", value: Self.libraryURL) } label: { Label("Library", systemImage: "books.vertical") }
                        .help("Show the Library of folders and cloud workspaces")
                }
                if let link = remoteWorkspaceLink {
                    Button {
                        onOpenRemoteWorkspace(link)
                        openWindow(id: "HCP.browser")
                    } label: { Label(link.isExact ? "Open in HCP Terraform" : "Find in HCP Terraform", systemImage: "cloud") }
                    .help(remoteLinkHelp(link))
                } else {
                    Button { openWindow(id: "HCP.browser") } label: { Label("Cloud workspaces", systemImage: "cloud") }
                }
                Button { openWindow(id: "App.settings") } label: { Label("Settings", systemImage: "gear") }
            }
          }
        }
    }

    private enum ViewMode: Hashable { case map, list, other }

    /// Map and List are the two views of the same workspace (Exploration B).
    /// Other pages leave neither segment selected.
    private var viewModeSelection: Binding<ViewMode> {
        Binding(get: {
            switch selection {
            case .map: .map
            case .resources: .list
            default: .other
            }
        }, set: { mode in
            switch mode {
            case .map: navigationSelection.wrappedValue = .map
            case .list: navigationSelection.wrappedValue = .resources
            case .other: break
            }
        })
    }

    /// A checkout's runs happen in HCP Terraform; its changes start in the cloud
    /// window's Proposal face rather than as a local plan.
    private var isCheckout: Bool {
        if case .checkout = remoteWorkspaceLink?.source { return true }
        return false
    }

    private func openCloudProposal() {
        guard let link = remoteWorkspaceLink else { return }
        onOpenRemoteWorkspace(link)
        cloud.requestedFace = "proposal"
        openWindow(id: "HCP.browser")
    }

    private var newRunTitle: String {
        isCheckout ? "Make a change" : (workspace.autoApply ? "Preview and apply" : "Preview Changes")
    }
    private var newRunAction: (() -> Void)? {
        guard workspace.workingDirectory != nil, !workspace.locked else { return nil }
        if isCheckout { return { openCloudProposal() } }
        return { previewChanges() }
    }

    /// Preview Changes stays on the Map; the plan lands as a review state there.
    private func previewChanges() {
        workspace.validateAndQueueRun(onCreated: { id in
            previewRunID = id
            selectedRun = id
            navigationSelection.wrappedValue = .map
        })
    }

    /// The most recent run that holds a saved, unapplied plan: Preview Changes
    /// shows it on the Map until it is applied or discarded.
    private var previewRun: TerraformRun? {
        let candidates = workspace.runs.filter { $0.planDiff != nil && $0.status == .planned }
        if let id = previewRunID, let run = candidates.first(where: { $0.id == id }) { return run }
        return candidates.max { $0.createdAt < $1.createdAt }
    }

    private var mapPreview: MapChangePreview? {
        _ = previewTick
        guard let run = previewRun, let plan = run.planDiff else { return nil }
        // A folder with no recorded state yet has no map; the preview is then all new tiles.
        let map = workspace.resourceMap ?? ResourceMap(tiles: [], connections: [], dataSources: [])
        return try? MapChangePreview.build(plan: plan, currentMap: map)
    }

    /// Changes and Inputs ride the Map's inspector as faces (DESIGN.md §2).
    private var localSideFaces: [MapSideFace] {
        [
            // Changes live in the strip below the Map; the inspector keeps Inputs only.
            MapSideFace(id: "inputs", title: "Inputs", count: workspace.terraformVariables.isEmpty ? nil : workspace.terraformVariables.count) {
                LocalInputsFace(variables: workspace.terraformVariables,
                                onOpen: { showMissingInputs = false; navigationSelection.wrappedValue = .variables },
                                onOpenMissing: { showMissingInputs = true; navigationSelection.wrappedValue = .variables })
            }
        ]
    }

    /// Recorded local runs, oldest first. Counts come only from each run's own
    /// recorded plan summary; nothing is inferred from current state.
    private var localChangeClips: [MapChangeClip] {
        workspace.runs.sorted { $0.createdAt < $1.createdAt }.map { run in
            MapChangeClip(id: run.id.uuidString,
                          title: run.message?.isEmpty == false ? run.message! : "Run #\(run.number)",
                          date: run.createdAt, status: run.status.displayTitle,
                          isApplied: run.status == .applied,
                          added: run.added, changed: run.changed, destroyed: run.destroyed, author: nil)
        }
    }

    private var workspaceSubtitle: String {
        guard workspace.workingDirectory != nil else { return "" }
        var parts: [String] = []
        if workspace.selectedTerraformWorkspace != "default" { parts.append(workspace.selectedTerraformWorkspace) }
        if let link = remoteWorkspaceLink {
            if case .checkout = link.source { parts.append("From HCP Terraform") }
            else { parts.append(link.isInitialized ? "HCP Terraform state" : "HCP Terraform (not initialized)") }
        } else if workspace.backendIdentity != "unknown backend" {
            parts.append(workspace.backendIdentity.hasPrefix("local") ? "Local state" : workspace.backendIdentity)
        }
        parts.append("This Mac")
        return parts.joined(separator: " · ")
    }

    private var windowContent: some View {
        Group {
            if workspace.workingDirectory == nil {
                LibraryView(library: library, cloud: cloud, recentFolders: recentWorkspaces.folders,
                            onOpenFolder: openRecent, onForgetFolder: { recentWorkspaces.forget($0) }, onChooseFolder: openFolder,
                            onOpenCloud: { cloudWorkspace, organization, hostname in
                                let link = TerraformRemoteWorkspaceLink(hostname: hostname, organization: organization,
                                    workspaceName: cloudWorkspace.name, url: cloudWorkspace.htmlURL ?? URL(string: "https://\(hostname)")!)
                                onOpenRemoteWorkspace(link)
                                openWindow(id: "HCP.browser")
                            }, onOpenConnections: { openWindow(id: "App.settings") })
            } else {
                VStack(spacing: 0) {
                    if let page = selection, page != .map {
                        pageHeader(page)
                        Divider()
                    }
                    destinationContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var destinationContent: some View {
        if selection?.hasDetailList == true {
            splitDestinationContent
        } else {
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var splitDestinationContent: some View {
        HSplitView {
            collection.frame(minWidth: 240,
                             idealWidth: selection == .resources ? 460 : 280,
                             maxWidth: selection == .resources ? .infinity : 340,
                             maxHeight: .infinity)
            detail.frame(minWidth: selection == .resources ? 400 : 360,
                         maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var windowActions: WorkspaceWindowActions {
        WorkspaceWindowActions(
            recentFolders: recentWorkspaces.folders,
            openFolder: openFolder,
            openRecent: openRecent,
            clearRecents: recentWorkspaces.clear,
            plan: isCheckout ? openCloudProposal : previewChanges,
            initialize: { workspace.initialize() },
            validate: { workspace.validate() },
            canPlan: workspace.workingDirectory != nil && !workspace.locked && !workspace.historyLoading
                && workspace.historyError == nil && !workspace.isInspectingInputs && !workspace.hasUnavailableRememberedInputs,
            canInitialize: workspace.workingDirectory != nil && !workspace.locked,
            canValidate: workspace.workingDirectory != nil && !workspace.locked && !workspace.hasUnavailableRememberedInputs,
            planTitle: isCheckout ? "Make a Change in HCP Terraform" : (workspace.autoApply ? "Preview and apply automatically" : "Preview Changes")
        )
    }

    private func remoteLinkDetail(_ link: TerraformRemoteWorkspaceLink) -> String {
        var parts: [String] = []
        switch link.source {
        case .initializedBackend:
            parts.append("Open the remote workspace to view its Map. Local configuration and inputs remain available in this window.")
        case .configuration(let file):
            parts.append("\(file) declares \(link.organization) / \(link.selectorDescription) on \(link.hostname). This folder has not been initialized yet.")
        case .checkout:
            parts.append("This folder was checked out from \(link.organization) / \(link.selectorDescription). Runs happen in HCP Terraform; open the workspace to see its Map and state.")
        }
        if !link.isExact {
            parts.append("Terraform selects among \(link.selectorDescription); choose the one this folder uses in the HCP Terraform window.")
        }
        return parts.joined(separator: " ")
    }

    private func remoteLinkHelp(_ link: TerraformRemoteWorkspaceLink) -> String {
        var text = "\(link.organization) / \(link.selectorDescription) on \(link.hostname)"
        if case .configuration(let file) = link.source { text += " · declared in \(file), not initialized" }
        if case .checkout = link.source { text += " · checked out from this workspace" }
        return text
    }

    private var workspaceName: String {
        guard let directory = workspace.workingDirectory else { return "Habitable" }
        return directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
    }

    /// Secondary pages open in place of the Map and return to it, so the window
    /// keeps one subject (the workspace) instead of a sidebar of Terraform internals.
    private func pageHeader(_ page: NavigationItem) -> some View {
        HStack(spacing: 12) {
            Button { navigationSelection.wrappedValue = .map } label: { Label("Map", systemImage: "chevron.left") }
                .buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the Map")
            Text(page.title).font(.headline)
            Spacer()
            workspaceStatusLabel.font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var workspaceStatusLabel: some View {
        if workspace.locked {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running Terraform") }
        } else if workspace.isInspectingInputs {
            Label("Reading inputs", systemImage: "ellipsis.circle")
        } else if workspace.terraformVariables.contains(where: {
            $0.declaration?.required == true && !$0.isUserInput && $0.discoveredSource == nil && !$0.hasUnresolvedDiscoveredValue
        }) {
            Label("Inputs needed", systemImage: "exclamationmark.circle")
        } else if workspace.isInitialized && workspace.isValid {
            Label("Ready to preview", systemImage: "checkmark.circle")
        } else {
            Label("Idle", systemImage: "minus.circle")
        }
    }

    @ViewBuilder private var collection: some View {
        switch selection {
        case .runs: RunListPage(selection: $selectedRun)
        case .outputs: OutputsListPage(selection: $selectedOutput)
        default: EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .runs:
            if let run = workspace.runs.first(where: { $0.id == selectedRun })
                ?? (selectedRunDetail?.id == selectedRun ? selectedRunDetail : nil) {
                RunPageView(run: run, onOpenDeclaration: openDeclaration).id(run.id)
            } else {
                placeholder("Select a run", message: "Choose a run to review its plan, results, and logs.")
            }
        case .resources:
            if let address = selectedResource, let resource = workspace.state?.resources.first(where: { ($0.address ?? $0.id.uuidString) == address }) {
                ShowResourceView(resource: resource, workspaceDirectory: workspace.workingDirectory,
                                 terraformExecutableURL: workspace.runner.executableURL,
                                 workspaceInitialized: workspace.isInitialized,
                                 onOpenDeclaration: openDeclaration)
            } else {
                placeholder("Select a resource", message: "Choose a resource to inspect its details.")
            }
        case .outputs:
            if let key = selectedOutput, let output = workspace.state?.outputs.first(where: { $0.key == key }) {
                OutputPageView(output: output)
            } else {
                placeholder("Select an output", message: "Choose an output to inspect its value.")
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .map, .resources:
            // A folder whose state lives in HCP Terraform keeps the Map window shape:
            // the canvas explains and links to the remote workspace, while Inputs and
            // Changes stay on the right.
            let remote = (remoteWorkspaceLink != nil && workspace.state == nil && !workspace.locked) ? remoteWorkspaceLink : nil
            VStack(spacing: 0) {
                ResourceMapPage(onShowVariables: { navigationSelection.wrappedValue = .variables },
                                onShowList: { navigationSelection.wrappedValue = .resources },
                                onOpenResource: { address in
                                    selectedResource = address
                                    navigationSelection.wrappedValue = .resources
                                }, onShowHistory: { navigationSelection.wrappedValue = .runs },
                                sideFaces: localSideFaces,
                                emptyTitle: workspace.awaitingInitializationConsent ? "Initialize this folder?" : remote.map { link in
                                    if case .checkout = link.source { return "From \(link.workspaceName ?? "HCP Terraform")" }
                                    return link.isInitialized ? "State managed in HCP Terraform" : "Configured for HCP Terraform"
                                },
                                emptyDetail: workspace.awaitingInitializationConsent
                                    ? "This folder was opened from outside Habitable. Initializing runs terraform init, which downloads the providers its configuration declares and runs them to validate it."
                                    : remote.map(remoteLinkDetail),
                                emptySymbol: workspace.awaitingInitializationConsent ? "shippingbox" : (remote == nil ? nil : "cloud"),
                                emptyAction: workspace.awaitingInitializationConsent
                                    ? MapEmptyAction(title: "Initialize") { workspace.initialize() }
                                    : remote.map { link in
                                    MapEmptyAction(title: link.workspaceName.map { "Open \($0) in HCP Terraform" } ?? "Choose the workspace in HCP Terraform") {
                                        onOpenRemoteWorkspace(link)
                                        openWindow(id: "HCP.browser")
                                    }
                                },
                                preview: mapPreview,
                                onDiscardPreview: { previewRun?.doDiscard(); previewRunID = nil },
                                onReviewPreview: {
                                    if let run = previewRun { selectedRun = run.id; navigationSelection.wrappedValue = .runs }
                                },
                                selectionRequest: mapSelectionRequest,
                                listMode: selection == .resources,
                                onShowOnMap: { address in
                                    mapSelectionRequest = MapSelectionRequest(address: address)
                                    navigationSelection.wrappedValue = .map
                                },
                                onShowPlanOutput: {
                                    if let run = previewRun { selectedRun = run.id; navigationSelection.wrappedValue = .runs }
                                },
                                autoApplyBadge: workspace.autoApply ? "Applies automatically" : nil)
                Divider()
                MapTimelineStrip(clips: localChangeClips, selectedID: selectedRun?.uuidString,
                                 hint: "Select a change to review its run",
                                 onSelect: { clip in
                                     selectedRun = UUID(uuidString: clip.id)
                                     navigationSelection.wrappedValue = .runs
                                 }, onShowAll: { navigationSelection.wrappedValue = .runs },
                                 newRunTitle: newRunTitle, onNewRun: newRunAction)
            }
        case .readme: WorkspaceReadmePage(directory: workspace.workingDirectory, presentation: readme)
        case .configuration: ConfigurationPage(workspace: workspace, model: configurationModel,
                                               declarationRequest: $declarationRequest)
        case .variables: VariableListPage(showMissingOnly: showMissingInputs)
        case .envVariables: EnvVarListPage()
        case .settings: SettingsListPage(catalog: releaseCatalog, onOpenAppSettings: { openWindow(id: "App.settings") })
        default: WorkspacePage(onReviewRun: { id in
            selectedRun = id
            navigationSelection.wrappedValue = .runs
        }, onOpenConfiguration: { navigationSelection.wrappedValue = .configuration },
           onOpenInputs: {
               showMissingInputs = false
               navigationSelection.wrappedValue = .variables
           }, onOpenMissingInputs: {
               showMissingInputs = true
               navigationSelection.wrappedValue = .variables
           })
        }
    }

    private var navigationSelection: Binding<NavigationItem?> {
        Binding(get: { selection }, set: { page in
            guard page != selection else { return }
            if page != .variables { showMissingInputs = false }
            navigationTrace.begin(page: page?.rawValue ?? "workspace")
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { selection = page }
        })
    }

    private func openDeclaration(_ file: String, _ line: Int) {
        declarationRequest = ConfigurationDeclarationRequest(file: file, line: line)
        navigationSelection.wrappedValue = .configuration
    }

    private func placeholder(_ title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title2)
            Text(message).foregroundColor(.secondary)
        }
        .padding()
    }

    private func openFolder() {
        guard !workspace.locked else {
            presentedOpenError = "Wait for the current workspace command to finish before opening another folder."
            isOpenErrorPresented = true
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open Terraform Folder"
        panel.message = "Choose a local folder containing your Terraform configuration."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openRecent(url)
        }
    }

    private func openRecent(_ url: URL) {
        guard workspace.openWorkspaceDirectory(url) else {
            presentedOpenError = workspace.workspaceOpenError
            isOpenErrorPresented = true
            return
        }
        recentWorkspaces.recordSuccessfulOpen(url)
    }

    private func isAvailableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Signposts measure selection to the next AppKit layout, not network completion
/// or actual pixel presentation. Instruments can correlate this interval with UI hangs.
@MainActor
private final class NavigationTrace: ObservableObject {
    private let log = OSLog(subsystem: "dev.thrasher.paul.Habitable", category: .pointsOfInterest)
    private var pending: (page: String, id: OSSignpostID)?

    func begin(page: String) {
        if let pending { os_signpost(.end, log: log, name: "Page navigation", signpostID: pending.id, "Superseded") }
        let id = OSSignpostID(log: log)
        pending = (page, id)
        os_signpost(.begin, log: log, name: "Page navigation", signpostID: id, "%{public}@", page)
    }

    func laidOut(page: String) {
        guard let pending, pending.page == page else { return }
        os_signpost(.end, log: log, name: "Page navigation", signpostID: pending.id)
        self.pending = nil
    }
}

private struct NavigationLayoutProbe: NSViewRepresentable {
    let trace: NavigationTrace
    let page: String

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.didLayout = { trace.laidOut(page: page) }
        view.needsLayout = true
    }

    final class ProbeView: NSView {
        var didLayout: (() -> Void)?
        override func layout() {
            super.layout()
            didLayout?()
        }
    }
}

extension ContentView {
    /// Makes this window's folder the one agents reach. Library windows have none to offer.
    fileprivate func offerToAgents() {
        if workspace.workingDirectory != nil {
            agentAccess.activate(workspace)
            agentAccess.workspaceChanged(in: workspace)
        } else {
            agentAccess.deactivate(workspace)
        }
    }
}

/// Calls `onBecomeKey` whenever the hosting window becomes the key window.
private struct WindowKeyObserver: NSViewRepresentable {
    let onBecomeKey: () -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onBecomeKey = onBecomeKey
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var onBecomeKey: () -> Void = {}
        private weak var window: NSWindow?
        nonisolated(unsafe) private var token: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            self.window = window
            guard let window else { token = nil; return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBecomeKey() }
            }
            if window.isKeyWindow { onBecomeKey() }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView(cloud: HCPWorkspaceViewerModel(), agentAccess: HabitableAgentAccess()) }
}

/// Preserve native toolbar controls while removing the OS shared glass capsule.
struct QuietToolbar<Content: ToolbarContent>: ToolbarContent {
    let content: Content
    init(@ToolbarContentBuilder content: () -> Content) { self.content = content() }

    @ToolbarContentBuilder var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            content.sharedBackgroundVisibility(.hidden)
        } else {
            content
        }
    }
}

struct QuietGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Compact Inputs face: one row per declared or supplied input. Values follow
/// the same masking rules as the Inputs page; nothing sensitive is previewed.
private struct LocalInputsFace: View {
    let variables: [TerraformVariable]
    let onOpen: () -> Void
    let onOpenMissing: () -> Void

    private var missingCount: Int { variables.filter(\.isMissingRequiredInput).count }

    var body: some View {
        VStack(spacing: 0) {
            if missingCount > 0 {
                Button { onOpenMissing() } label: {
                    Label("\(missingCount) required input\(missingCount == 1 ? "" : "s") not set", systemImage: "exclamationmark.circle")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
            }
            if variables.isEmpty {
                Text("No inputs declared or supplied for this folder.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(variables.sorted { $0.key < $1.key }, id: \.id) { variable in
                            InputRow(variable: variable).onTapGesture(perform: onOpen)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            Divider()
            Button("Open Inputs", action: onOpen).buttonStyle(.link).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private struct InputRow: View {
        @ObservedObject var variable: TerraformVariable

        private var hasValue: Bool { variable.isUserInput || variable.discoveredSource != nil }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(variable.key).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                if variable.rememberedSecretUnavailable || variable.sensitive {
                    Label(variable.rememberedSecretUnavailable ? "Remembered value unavailable" : "Sensitive value hidden", systemImage: "lock.fill")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                } else if hasValue {
                    Text(variable.value.isEmpty ? "(empty)" : variable.value)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else if variable.isMissingRequiredInput {
                    Text("Required · not set").font(.system(size: 12)).foregroundStyle(.orange)
                } else {
                    Text(variable.declaration?.hasDefault == true ? "Uses Terraform default" : "Not set")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }
}
