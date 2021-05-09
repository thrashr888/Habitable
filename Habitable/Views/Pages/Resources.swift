//
//  Resource.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct ShowResourceView: View {
    @State var resource: ShowResource

    var body: some View {
        HStack {
            if resource.name != nil {
                Text("\"\(resource.name!)\"")
            }
            if resource.address != nil {
                Text("\(resource.address!)")
                    .font(.system(.body, design: .monospaced))
            }
            if resource.type != nil {
                Text("(\(resource.type!))")
            }
//            if resource.provider_name != nil {
//                Text("\(resource.provider_name!)")
//            }
//            if resource.values != nil {
//                Text("\(resource.values!)")
//            }
        }
    }
}

struct ShowView: View {
    @State var show: ShowMessage

    var body: some View {
        VStack(alignment: .leading) {
            if show.root_module.resources.count > 0 {
                Text("Resources")
                    .fontWeight(.bold)
                List(show.root_module.resources, id: \.id) { resource in
                    ShowResourceView(resource: resource)
                }
            }
            if show.values.outputs.count > 0 {
                Text("Outputs")
                    .fontWeight(.bold)
                OutputView(outputs: show.values.outputs)
            }
        }
    }
}

struct ShowModuleView: View {
    @State var run: TerraformRun
    var body: some View {
        Text("id: \(run.id)")
    }
}

struct ResourceListPage: View {
    @State var workspace: Workspace
    var count: Int {
        workspace.state != nil ? workspace.state!.root_module.resources.count : 0
    }

    var body: some View {
        VStack(alignment: .leading) {
            if workspace.state != nil {
                ShowView(show: workspace.state!)
            } else {
                Text("State not present")
                Button(action: { workspace.refreshResources() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle("Resources (\(count))")
        .toolbar {
            Button(action: { workspace.refreshResources() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .help("Refresh resources")
            }
        }
    }
}

struct ResourceListPage_Previews: PreviewProvider {
    static var previews: some View {
        ResourceListPage(workspace: Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
