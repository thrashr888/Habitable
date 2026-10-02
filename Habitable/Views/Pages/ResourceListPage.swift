//
//  Resource.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct ResourceSummaryView: View {
    var resource: ShowResource

    var body: some View {
        VStack(alignment: .leading) {
//            if resource.name != nil {
//                Text("\"\(resource.name!)\"")
//            }
            if resource.address != nil {
                Text("\(resource.address!)")
                    .font(.system(.body, design: .monospaced))
            }
//            if resource.type != nil {
//                Text("(\(resource.type!))")
//            }
//            if resource.provider_name != nil {
//                Text("\(resource.provider_name!)")
//            }
//            if resource.values != nil {
//                Text("\(resource.values!)")
//            }
        }
    }
}

struct ResourceListPage: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var selection: String?
    @State var searchText: String = ""
    
    var resources: [ShowResource] {
        workspace.state?.root_module.resources ?? []
    }
    var filteredResources: [ShowResource] {
        resources.filter {
            searchText.isEmpty ||
                ($0.address?.localizedStandardContains(searchText) ?? false)
        }.sorted { ($0.address ?? $0.id.uuidString) > ($1.address ?? $1.id.uuidString) }
    }
    
    func refresh() {
        workspace.refreshResources()
        if selection == nil { selection = filteredResources.first?.address }
    }

    var body: some View {
        List(selection: $selection) {
            if workspace.state == nil {
                statusView
            } else if filteredResources.isEmpty && !searchText.isEmpty {
                emptyMessage("No matching resources", detail: "Try a different search.", symbol: "magnifyingglass")
            } else if filteredResources.isEmpty {
                emptyMessage("No resources", detail: "This state has no resources.", symbol: "globe")
            } else {
                ForEach(filteredResources) { resource in
                    ResourceSummaryView(resource: resource)
                        .lineLimit(2)
                        .tag(resource.address ?? resource.id.uuidString)
                }
            }
        }
        .navigationTitle("Resources")
//        .navigationSubtitle("\(resources.count) resources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .help("Refresh state")
                }
            }
            ToolbarItem {
                SearchField(search: $searchText)
                    .frame(minWidth: 100, idealWidth: 200, maxWidth: .infinity)
            }
        }
        .onChange(of: filteredResources.map { $0.address ?? $0.id.uuidString }) { addresses in
            if workspace.state != nil, let selection, !addresses.contains(selection) {
                self.selection = nil
            }
        }
        .onChange(of: workspace.state?.id) { _ in
            if let selection, let state = workspace.state,
               !state.resources.contains(where: { ($0.address ?? $0.id.uuidString) == selection }) {
                self.selection = nil
            }
        }
    }

    private var statusTitle: String {
        if workspace.locked && workspace.canCancelCommand { return "Loading resources" }
        if workspace.errorMessage != nil { return "Could not load resources" }
        return "No state available"
    }

    private var statusMessage: String {
        if workspace.locked && workspace.canCancelCommand { return "Terraform is refreshing this workspace." }
        if let error = workspace.errorMessage { return error }
        return workspace.hasState ? "Refresh to check this workspace for resources." : "No state is available for this workspace yet. Refresh to check again."
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

struct ResourceListPage_Previews: PreviewProvider {
    static var previews: some View {
        ResourceListPage(selection: .constant(nil))
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
