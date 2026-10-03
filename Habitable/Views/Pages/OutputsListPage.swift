//
//  OutputsList.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/14/21.
//

import SwiftUI

struct OutputSummaryView: View {
    var output: Output
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(output.key)")
            if output.sensitive {
                Label("Sensitive value hidden", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else if let value = output.value {
                Text("\(value)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct OutputsListPage: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var selection: String?
    @State var searchText: String = ""
    
    var outputs: [Output] {
        workspace.state?.values.outputs ?? []
    }
    var filteredOutputs: [Output] {
        outputs.filter {
            searchText.isEmpty ||
                $0.key.localizedStandardContains(searchText)
        }.sorted { $0.key > $1.key }
    }
    
    func refresh() {
        workspace.refreshResources()
        if selection == nil { selection = filteredOutputs.first?.key }
    }

    var body: some View {
        List(selection: $selection) {
            if workspace.state == nil {
                statusView
            } else if filteredOutputs.isEmpty && !searchText.isEmpty {
                emptyMessage("No matching outputs", detail: "Try a different search.", symbol: "magnifyingglass")
            } else if filteredOutputs.isEmpty {
                emptyMessage("No outputs", detail: "This state has no outputs.", symbol: "chevron.right.square")
            } else {
                ForEach(filteredOutputs) { output in
                    OutputSummaryView(output: output)
                        .accessibilityElement(children: .combine)
                        .tag(output.key)
                }
            }
        }

//        .navigationSubtitle("\(outputs.count) outputs")
        .toolbar {
            QuietToolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .help("Refresh state")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workspace.locked)
                }
                ToolbarItem {
                    SearchField(search: $searchText, accessibilityLabel: "Search outputs")
                        .frame(minWidth: 100, idealWidth: 200, maxWidth: .infinity)
                }
            }
        }
        .onChange(of: filteredOutputs.map(\.key)) { keys in
            if workspace.state != nil, let selection, !keys.contains(selection) { self.selection = nil }
        }
        .onChange(of: workspace.state?.id) { _ in
            if let selection, let state = workspace.state,
               !state.outputs.contains(where: { $0.key == selection }) { self.selection = nil }
        }
    }

    private var statusTitle: String {
        if workspace.locked && workspace.canCancelCommand { return "Loading outputs" }
        if workspace.errorMessage != nil { return "Could not load outputs" }
        return "No state available"
    }

    private var statusMessage: String {
        if workspace.locked && workspace.canCancelCommand { return "Terraform is refreshing this workspace." }
        if let error = workspace.errorMessage { return error }
        return workspace.hasState ? "Refresh to check this workspace for outputs." : "No state is available for this workspace yet. Refresh to check again."
    }

    private var statusSymbol: String {
        if workspace.locked && workspace.canCancelCommand { return "arrow.clockwise" }
        return workspace.errorMessage == nil ? "tray" : "exclamationmark.triangle"
    }

    private var statusView: some View {
        VStack(spacing: 10) {
            Label(statusTitle, systemImage: statusSymbol).font(.headline)
            Text(statusMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(workspace.locked)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowSeparator(.hidden)
    }

    private func emptyMessage(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowSeparator(.hidden)
    }
}

struct OutputsListPage_Previews: PreviewProvider {
    static var previews: some View {
        OutputsListPage(selection: .constant(nil))
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
