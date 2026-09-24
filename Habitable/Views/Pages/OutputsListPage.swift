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
                Text("◼︎◼︎◼︎◼︎◼︎◼︎◼︎")
            } else if let value = output.value {
                Text("\(value)")
                    .lineLimit(1)
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
            if outputs.count == 0 {
                VStack(alignment: .leading) {
                    Text("State not present")
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            
            ForEach(outputs.sorted { $0.key > $1.key }) { output in
                OutputSummaryView(output: output)
                    .tag(output.key)
            }
        }
        .navigationTitle("Outputs")
//        .navigationSubtitle("\(outputs.count) outputs")
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

struct OutputsListPage_Previews: PreviewProvider {
    static var previews: some View {
        OutputsListPage(selection: .constant(nil))
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
