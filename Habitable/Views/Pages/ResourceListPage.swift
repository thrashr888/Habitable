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
                $0.address?.localizedStandardContains(searchText) != nil
        }.sorted { $0.address! > $1.address! }
    }
    
    func refresh() {
        workspace.refreshResources()
        if selection == nil { selection = filteredResources.first?.address }
    }

    var body: some View {
        List(selection: $selection) {
            if resources.count == 0 {
                VStack(alignment: .leading) {
                    Text("State not present")
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                Spacer()
            }
            if searchText != "" {
                Text("Searching: \(searchText)")
            }
            ForEach(filteredResources) { resource in
                ResourceSummaryView(resource: resource)
                    .lineLimit(2)
                    .tag(resource.address ?? resource.id.uuidString)
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
    }
}

struct ResourceListPage_Previews: PreviewProvider {
    static var previews: some View {
        ResourceListPage(selection: .constant(nil))
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
