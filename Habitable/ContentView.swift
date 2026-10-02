import SwiftUI

struct ContentView: View {
    enum NavigationItem: String {
        case workspace, runs, resources, outputs, variables, envVariables, settings

        var hasDetailList: Bool {
            self == .runs || self == .resources || self == .outputs
        }
    }

    @StateObject var workspace = Workspace()
    @State private var selection: NavigationItem? = .workspace
    @State private var selectedRun: UUID?
    @State private var selectedResource: String?
    @State private var selectedOutput: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if workspace.workingDirectory == nil {
                BlankSlateView()
            } else if selection?.hasDetailList == true {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } content: {
                    collection
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                } detail: {
                    detail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .environmentObject(workspace)
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
            Label("Runs (\(max(workspace.historyTotalCount, workspace.runs.count)))", systemImage: "list.bullet.rectangle").tag(NavigationItem.runs)
            Label("Resources (\(workspace.state?.resources.count ?? 0))", systemImage: "globe").tag(NavigationItem.resources)
            Label("Outputs (\(workspace.state?.outputs.count ?? 0))", systemImage: "chevron.right.square").tag(NavigationItem.outputs)
            Label("Variables (\(workspace.terraformVariables.count))", systemImage: "dollarsign.circle").tag(NavigationItem.variables)
            Label("Env Vars (\(workspace.environmentVariables.count))", systemImage: "dollarsign.circle").tag(NavigationItem.envVariables)
            Label("Settings", systemImage: "gear").tag(NavigationItem.settings)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if workspace.locked {
                    ProgressView().controlSize(.small)
                    Text("Running Terraform").lineLimit(1)
                } else {
                    Label("Ready", systemImage: "checkmark.circle")
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
                ShowResourceView(resource: resource)
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
        case .variables: VariableListPage()
        case .envVariables: EnvVarListPage()
        case .settings: SettingsListPage()
        default: WorkspacePage()
        }
    }

    private func placeholder(_ title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title2)
            Text(message).foregroundColor(.secondary)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
