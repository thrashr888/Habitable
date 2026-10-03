import AppKit
import SwiftUI
import os

struct WorkspaceWindowActions {
    let recentFolders: [URL]
    let openFolder: () -> Void
    let openRecent: (URL) -> Void
    let clearRecents: () -> Void
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
        case workspace, readme, configuration, runs, resources, outputs, variables, envVariables, settings

        var title: String {
            switch self {
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

    @StateObject var workspace = Workspace()
    @StateObject private var recentWorkspaces = RecentWorkspaceStore()
    @StateObject private var configurationModel = ConfigurationModel()
    @StateObject private var releaseCatalog = TerraformReleaseCatalog()
    @StateObject private var editors = ExternalEditorStore()
    @StateObject private var readme = WorkspaceReadmePresentation()
    @StateObject private var navigationTrace = NavigationTrace()
    @State private var selection: NavigationItem? = .workspace
    @State private var selectedRun: UUID?
    @State private var selectedResource: String?
    @State private var selectedOutput: String?
    @State private var sidebarVisible = true
    @State private var isOpenErrorPresented = false
    @State private var presentedOpenError: String?

    var body: some View {
        Group {
            if workspace.workingDirectory == nil {
                BlankSlateView(recentFolders: recentWorkspaces.folders,
                               onChooseFolder: openFolder,
                               onOpenRecent: openRecent)
            } else {
                HSplitView {
                    if sidebarVisible {
                        sidebar.frame(minWidth: 180, idealWidth: 200, maxWidth: 240, maxHeight: .infinity)
                    }
                    if selection?.hasDetailList == true {
                        HSplitView {
                            collection
                                .frame(minWidth: 240, idealWidth: selection == .resources ? 460 : 280,
                                       maxWidth: selection == .resources ? .infinity : 340,
                                       maxHeight: .infinity)
                            detail.frame(minWidth: selection == .resources ? 400 : 360, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        page.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text((selection ?? .workspace).title)
                                .font(.headline).fixedSize(horizontal: true, vertical: false)
                            Text(workspaceName).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: 320)
                        .help(workspace.workingDirectory?.path ?? workspaceName)
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .navigation) {
                        Button { sidebarVisible.toggle() } label: {
                            Label(sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                        }
                        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                        .keyboardShortcut("s", modifiers: [.command, .control])
                    }
                }
            }
        }
        .background(WorkspaceWindowIdentity(title: "\(workspaceName) — \((selection ?? .workspace).title)"))
        .environmentObject(workspace)
        .environmentObject(editors)
        .animation(nil, value: selection)
        .background(NavigationLayoutProbe(trace: navigationTrace, page: selection?.rawValue ?? "workspace")
            .allowsHitTesting(false))
        .disclosureGroupStyle(FullHeaderDisclosureStyle())
        .focusedSceneValue(\.workspaceWindowActions, WorkspaceWindowActions(
            recentFolders: recentWorkspaces.folders,
            openFolder: openFolder,
            openRecent: openRecent,
            clearRecents: recentWorkspaces.clear
        ))
        .onChange(of: workspace.workspaceOpenError) { error in
            if let error {
                presentedOpenError = error
                isOpenErrorPresented = true
            }
        }
        .onChange(of: workspace.workingDirectory) { directory in
            if let directory, isAvailableDirectory(directory) { recentWorkspaces.recordSuccessfulOpen(directory) }
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
            selectedResource = nil
            selectedOutput = nil
        }
        .onChange(of: workspace.runs.map(\.id)) { ids in
            if let selectedRun, !ids.contains(selectedRun) {
                self.selectedRun = nil
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

    private var workspaceName: String {
        guard let directory = workspace.workingDirectory else { return "Habitable" }
        return directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
    }

    private var sidebar: some View {
        List(selection: navigationSelection) {
            Label("Workspace", systemImage: "folder").tag(NavigationItem.workspace)
            Label("README", systemImage: "book.closed").tag(NavigationItem.readme)
            Label("Configuration", systemImage: "doc.text").tag(NavigationItem.configuration)
            Label("Runs (\(max(workspace.historyTotalCount, workspace.runs.count)))", systemImage: "list.bullet.rectangle").tag(NavigationItem.runs)
            Label("Resources (\(workspace.state?.resources.count ?? 0))", systemImage: "globe").tag(NavigationItem.resources)
            Label("Outputs (\(workspace.state?.outputs.count ?? 0))", systemImage: "chevron.right.square").tag(NavigationItem.outputs)
            Label("Variables (\(workspace.terraformVariables.count))", systemImage: "dollarsign.circle").tag(NavigationItem.variables)
            Label("Env Vars (\(workspace.environmentVariables.count))", systemImage: "dollarsign.circle").tag(NavigationItem.envVariables)
            Label("Settings", systemImage: "gear").tag(NavigationItem.settings)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if workspace.locked {
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
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
            .accessibilityElement(children: .combine)
        }
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
            if let run = workspace.runs.first(where: { $0.id == selectedRun }) {
                RunPageView(run: run).id(run.id)
            } else {
                placeholder("Select a run", message: "Choose a run to review its plan, results, and logs.")
            }
        case .resources:
            if let address = selectedResource, let resource = workspace.state?.resources.first(where: { ($0.address ?? $0.id.uuidString) == address }) {
                ShowResourceView(resource: resource, workspaceDirectory: workspace.workingDirectory,
                                 terraformExecutableURL: workspace.runner.executableURL,
                                 workspaceInitialized: workspace.isInitialized)
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
        case .readme: WorkspaceReadmePage(directory: workspace.workingDirectory, presentation: readme)
        case .configuration: ConfigurationPage(workspace: workspace, model: configurationModel)
        case .variables: VariableListPage()
        case .envVariables: EnvVarListPage()
        case .settings: SettingsListPage(catalog: releaseCatalog)
        default: WorkspacePage(onReviewRun: { id in
            selectedRun = id
            navigationSelection.wrappedValue = .runs
        }, onOpenConfiguration: { navigationSelection.wrappedValue = .configuration },
           onOpenInputs: { navigationSelection.wrappedValue = .variables })
        }
    }

    private var navigationSelection: Binding<NavigationItem?> {
        Binding(get: { selection }, set: { page in
            guard page != selection else { return }
            navigationTrace.begin(page: page?.rawValue ?? "workspace")
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { selection = page }
        })
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

/// Keep Window-menu identity useful while the principal toolbar owns the visible
/// title. Native sidebar-bound titles can clip at the sidebar divider.
private struct WorkspaceWindowIdentity: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> IdentityView { IdentityView() }
    func updateNSView(_ view: IdentityView, context: Context) {
        view.title = title
        view.updateIdentity()
    }
    final class IdentityView: NSView {
        var title = "Habitable"
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateIdentity()
        }
        func updateIdentity() {
            window?.title = title
            window?.titleVisibility = .hidden
        }
    }
}
