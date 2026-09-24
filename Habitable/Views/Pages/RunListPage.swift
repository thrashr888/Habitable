//
//  Run.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct RunListPage: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.historyError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Button("Reload history", action: workspace.reloadRunHistory)
                        .disabled(workspace.locked)
                }
                .padding()
            }
            List(selection: $selection) {
                if workspace.runs.isEmpty {
                    Text("No runs yet. Queue a plan to view potential changes.")
                }
                ForEach(workspace.runs.sorted { $0.number > $1.number }) { run in
                    RunSummaryView(run: run)
                        .tag(run.id)
                }
            }
        }
        .navigationTitle("Runs")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: workspace.reloadRunHistory) {
                    Label("Reload history", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Reload saved run history")
                .disabled(workspace.locked)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    workspace.queueRun()
                    selection = workspace.runs.last?.id
                }) {
                    Label("Queue plan", systemImage: "text.badge.plus")
                }
                .labelStyle(.iconOnly)
                .help("Queue a Terraform plan")
                .disabled(workspace.locked || !workspace.isValid || workspace.historyError != nil)
            }
        }
    }
}

struct RunListPage_Previews: PreviewProvider {
    static let workspace: Workspace = {
        let model = Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable"))
        model.runs = [
            TerraformRun(workspace: model),
            TerraformRun(workspace: model),
        ]
        return model
    }()
    
    static var previews: some View {
        RunListPage(selection: .constant(nil))
            .environmentObject(workspace)
    }
}
