import AppKit
import SwiftUI

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
        case workspace, configuration, runs, resources, outputs, variables, envVariables, settings

        var hasDetailList: Bool {
            self == .runs || self == .resources || self == .outputs
        }
    }

    @StateObject var workspace = Workspace()
    @StateObject private var recentWorkspaces = RecentWorkspaceStore()
    @StateObject private var configurationModel = ConfigurationModel()
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
        .environmentObject(workspace)
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

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Workspace", systemImage: "folder").tag(NavigationItem.workspace)
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
        case .configuration: ConfigurationPage(workspace: workspace, model: configurationModel)
        case .variables: VariableListPage()
        case .envVariables: EnvVarListPage()
        case .settings: SettingsListPage()
        default: WorkspacePage(onReviewRun: { id in
            selectedRun = id
            selection = .runs
        }, onOpenConfiguration: { selection = .configuration },
           onOpenInputs: { selection = .variables })
        }
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
