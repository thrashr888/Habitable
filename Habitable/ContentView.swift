import AppKit
import SwiftUI
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
        case map, workspace, readme, configuration, runs, resources, outputs, variables, envVariables, settings, hcpTerraform

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
            case .hcpTerraform: "HCP Terraform"
            }
        }

        var hasDetailList: Bool {
            self == .runs || self == .resources || self == .outputs
        }
    }

    @StateObject var workspace: Workspace

    init() {
        let restoreHCP = UserDefaults.standard.bool(forKey: "lastWorkspaceSourceWasHCP")
        _workspace = StateObject(wrappedValue: Workspace(restoreLastDirectory: !restoreHCP))
        _selection = State(initialValue: restoreHCP ? .hcpTerraform : .map)
    }
    @StateObject private var recentWorkspaces = RecentWorkspaceStore()
    @StateObject private var configurationModel = ConfigurationModel()
    @StateObject private var releaseCatalog = TerraformReleaseCatalog()
    @StateObject private var editors = ExternalEditorStore()
    @StateObject private var readme = WorkspaceReadmePresentation()
    @StateObject private var navigationTrace = NavigationTrace()
    @StateObject private var hcpViewer = HCPWorkspaceViewerModel()
    @StateObject private var agentAccess = HabitableAgentAccess()
    @StateObject private var windowIdentity = WorkspaceTitlebarController()
    @State private var selection: NavigationItem? = .map
    @State private var selectedRun: UUID?
    @State private var selectedRunDetail: TerraformRun?
    @State private var selectedResource: String?
    @State private var selectedOutput: String?
    @State private var showMissingInputs = false
    @State private var declarationRequest: ConfigurationDeclarationRequest?
    @State private var sidebarVisible = true
    @State private var isOpenErrorPresented = false
    @State private var presentedOpenError: String?

    var body: some View {
        configuredWindowContent
        .onChange(of: workspace.workspaceOpenError) { error in
            if let error {
                presentedOpenError = error
                isOpenErrorPresented = true
            }
        }
        .onChange(of: workspace.workingDirectory) { directory in
            agentAccess.workspaceChanged(in: workspace)
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
        .onDisappear { agentAccess.setEnabled(false, in: workspace) }
        .onChange(of: selection) { page in
            if page == .hcpTerraform { agentAccess.setEnabled(false, in: workspace) }
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
        .background(WorkspaceWindowIdentity(controller: windowIdentity, title: workspaceName,
                                            sidebarVisible: sidebarVisible && (workspace.workingDirectory != nil || selection == .hcpTerraform),
                                            hasWorkspace: workspace.workingDirectory != nil || selection == .hcpTerraform,
                                            toggleSidebar: { sidebarVisible.toggle() }))
        .environmentObject(workspace)
        .environmentObject(editors)
        .buttonStyle(.borderless)
        .groupBoxStyle(QuietGroupBoxStyle())
        .animation(nil, value: selection)
        .background(NavigationLayoutProbe(trace: navigationTrace, page: selection?.rawValue ?? "workspace")
            .allowsHitTesting(false))
        .disclosureGroupStyle(FullHeaderDisclosureStyle())
        .focusedSceneValue(\.workspaceWindowActions, windowActions)
    }

    private var windowContent: some View {
        Group {
            if workspace.workingDirectory == nil && selection != .hcpTerraform {
                BlankSlateView(recentFolders: recentWorkspaces.folders,
                               onChooseFolder: openFolder,
                               onOpenRecent: openRecent,
                               onOpenHCP: { navigationSelection.wrappedValue = .hcpTerraform })
            } else {
                HSplitView {
                    if sidebarVisible {
                        sidebar.frame(minWidth: 180, idealWidth: 200, maxWidth: 240, maxHeight: .infinity)
                            .background(WorkspaceSidebarEdge(controller: windowIdentity))
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
            plan: {
                guard selection != .hcpTerraform else { return }
                workspace.validateAndQueueRun(onCreated: { id in
                    selectedRun = id
                    navigationSelection.wrappedValue = .runs
                })
            },
            initialize: workspace.initialize,
            validate: workspace.validate,
            canPlan: selection != .hcpTerraform && workspace.workingDirectory != nil && !workspace.locked && !workspace.historyLoading
                && workspace.historyError == nil && !workspace.isInspectingInputs && !workspace.hasUnavailableRememberedInputs,
            canInitialize: selection != .hcpTerraform && workspace.workingDirectory != nil && !workspace.locked,
            canValidate: selection != .hcpTerraform && workspace.workingDirectory != nil && !workspace.locked && !workspace.hasUnavailableRememberedInputs,
            planTitle: workspace.autoApply ? "Plan and apply automatically" : "Plan"
        )
    }

    private var workspaceName: String {
        if selection == .hcpTerraform {
            return hcpViewer.selectedWorkspace.map { "\($0.name) · \(hcpViewer.selectedOrganization)" } ?? "HCP Terraform"
        }
        guard let directory = workspace.workingDirectory else { return "Habitable" }
        return directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
    }

    private var sidebar: some View {
        List(selection: navigationSelection) {
            Label("Map", systemImage: "square.grid.3x3").tag(NavigationItem.map)
            Label("Workspace", systemImage: "folder").tag(NavigationItem.workspace)
            Label("README", systemImage: "book.closed").tag(NavigationItem.readme)
            Label("Configuration", systemImage: "doc.text").tag(NavigationItem.configuration)
            sidebarRow("Runs", symbol: "list.bullet.rectangle", count: max(workspace.historyTotalCount, workspace.runs.count)).tag(NavigationItem.runs)
            sidebarRow("Resources", symbol: "globe", count: workspace.state?.resources.count ?? 0).tag(NavigationItem.resources)
            sidebarRow("Outputs", symbol: "chevron.right.square", count: workspace.state?.outputs.count ?? 0).tag(NavigationItem.outputs)
            sidebarRow("Variables", symbol: "dollarsign.circle", count: workspace.terraformVariables.count).tag(NavigationItem.variables)
            sidebarRow("Environment", symbol: "terminal", count: workspace.environmentVariables.count).tag(NavigationItem.envVariables)
            Label("Settings", systemImage: "gear").tag(NavigationItem.settings)
            Divider()
            Label("HCP Terraform", systemImage: "cloud").tag(NavigationItem.hcpTerraform)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if selection == .hcpTerraform {
                    Label(hcpViewer.isConnected ? "HCP · Connected" : "HCP disconnected", systemImage: "cloud")
                } else if workspace.locked {
                    ProgressView().controlSize(.small)
                    Text("Running Terraform").lineLimit(1)
                } else if workspace.isInspectingInputs {
                    Label("Reading inputs", systemImage: "ellipsis.circle")
                } else if workspace.terraformVariables.contains(where: {
                    $0.declaration?.required == true && !$0.isUserInput && $0.discoveredSource == nil && !$0.hasUnresolvedDiscoveredValue
                }) {
                    Label("Inputs needed", systemImage: "exclamationmark.circle")
                } else if workspace.isInitialized && workspace.isValid {
                    Label("Ready to plan", systemImage: "checkmark.circle")
                } else {
                    Label("Idle", systemImage: "minus.circle")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }

    private func sidebarRow(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).lineLimit(1)
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
    }

    @ViewBuilder private var collection: some View {
        switch selection {
        case .runs: RunListPage(selection: $selectedRun)
        case .resources: ResourceListPage(selection: $selectedResource)
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
        case .map: ResourceMapPage(onShowVariables: { navigationSelection.wrappedValue = .variables },
                                    onShowList: { navigationSelection.wrappedValue = .resources },
                                    onOpenResource: { address in
                                        selectedResource = address
                                        navigationSelection.wrappedValue = .resources
                                    })
        case .readme: WorkspaceReadmePage(directory: workspace.workingDirectory, presentation: readme)
        case .configuration: ConfigurationPage(workspace: workspace, model: configurationModel,
                                               declarationRequest: $declarationRequest)
        case .variables: VariableListPage(showMissingOnly: showMissingInputs)
        case .envVariables: EnvVarListPage()
        case .settings: SettingsListPage(catalog: releaseCatalog, agentAccess: agentAccess)
        case .hcpTerraform: HCPWorkspaceViewer(model: hcpViewer)
                .onAppear { hcpViewer.setVisible(true) }
                .onDisappear { hcpViewer.setVisible(false) }
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
            if let page {
                UserDefaults.standard.set(page == .hcpTerraform, forKey: "lastWorkspaceSourceWasHCP")
            }
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}

/// The title remains the window identity for the Window menu and accessibility.
/// Its one visible label lives in a standard left titlebar accessory, aligned to
/// the real sidebar edge rather than an assumed sidebar width or page heading.
@MainActor
private final class WorkspaceTitlebarController: ObservableObject {
    private weak var window: NSWindow?
    private weak var sidebar: NSView?
    private let accessory = NSTitlebarAccessoryViewController()
    private let titleView = WorkspaceTitlebarLabel()
    private var sidebarVisible = true

    init() {
        accessory.layoutAttribute = .left
        accessory.view = titleView
    }

    func update(window: NSWindow?, title: String, sidebarVisible: Bool, hasWorkspace: Bool, toggleSidebar: @escaping () -> Void) {
        self.sidebarVisible = sidebarVisible
        guard let window else { return }
        if self.window !== window {
            if let oldWindow = self.window,
               let index = oldWindow.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                oldWindow.removeTitlebarAccessoryViewController(at: index)
            }
            self.window = window
            window.addTitlebarAccessoryViewController(accessory)
        }
        window.title = title
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        titleView.toggleSidebar = toggleSidebar
        titleView.sidebarButton.isHidden = !hasWorkspace
        titleView.sidebarButton.toolTip = sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        titleView.sidebarButton.setAccessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        titleView.label.stringValue = title
        titleView.label.toolTip = title
        titleView.label.setAccessibilityLabel("Workspace: \(title)")
        updateGeometry()
    }

    func track(sidebar: NSView) {
        self.sidebar = sidebar
        updateGeometry()
    }

    func updateGeometry() {
        guard let window else { return }
        let sidebarEdge = sidebarVisible && sidebar?.window === window
            ? sidebar?.convert(sidebar?.bounds ?? .zero, to: nil).maxX : nil
        titleView.sidebarEdge = sidebarEdge
        titleView.availableWindowWidth = window.frame.width
        titleView.needsLayout = true
    }
}

private final class WorkspaceTitlebarLabel: NSView {
    let label = NSTextField(labelWithString: "")
    let sidebarButton = NSButton()
    var toggleSidebar: (() -> Void)?
    var sidebarEdge: CGFloat?
    var availableWindowWidth: CGFloat = 900

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.isBordered = false
        sidebarButton.bezelStyle = .accessoryBarAction
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebarAction)
        sidebarButton.keyEquivalent = "s"
        sidebarButton.keyEquivalentModifierMask = [.command, .control]
        addSubview(sidebarButton)
    }

    @objc private func toggleSidebarAction() { toggleSidebar?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        guard window != nil else { return }
        let origin = convert(bounds, to: nil).minX
        let leadingSpace: CGFloat = sidebarButton.isHidden ? 8 : 36
        let inset = sidebarEdge.map { max(leadingSpace, $0 + 16 - origin) } ?? leadingSpace
        // Leave room for page actions/search at the minimum supported window size.
        let titleWidth = min(260, max(120, (availableWindowWidth - (sidebarEdge ?? origin)) * 0.30))
        let width = inset + titleWidth
        if abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: frame.height)) }
        let height = ceil(label.intrinsicContentSize.height)
        sidebarButton.frame = NSRect(x: 0, y: floor((bounds.height - 28) / 2), width: 28, height: 28)
        label.frame = NSRect(x: inset, y: floor((bounds.height - height) / 2), width: titleWidth, height: height)
    }
}

private struct WorkspaceWindowIdentity: NSViewRepresentable {
    let controller: WorkspaceTitlebarController
    let title: String
    let sidebarVisible: Bool
    let hasWorkspace: Bool
    let toggleSidebar: () -> Void
    func makeNSView(context: Context) -> IdentityView { IdentityView() }
    func updateNSView(_ view: IdentityView, context: Context) {
        view.update = { [weak controller] window in
            controller?.update(window: window, title: title, sidebarVisible: sidebarVisible,
                               hasWorkspace: hasWorkspace, toggleSidebar: toggleSidebar)
        }
        view.update?(view.window)
    }
    final class IdentityView: NSView {
        var update: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            update?(window)
        }
        override func layout() {
            super.layout()
            update?(window)
        }
    }
}

private struct WorkspaceSidebarEdge: NSViewRepresentable {
    let controller: WorkspaceTitlebarController
    func makeNSView(context: Context) -> EdgeView { EdgeView() }
    func updateNSView(_ view: EdgeView, context: Context) {
        view.controller = controller
        controller.track(sidebar: view)
    }
    final class EdgeView: NSView {
        weak var controller: WorkspaceTitlebarController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller?.track(sidebar: self)
        }
        override func layout() {
            super.layout()
            controller?.track(sidebar: self)
        }
    }
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
