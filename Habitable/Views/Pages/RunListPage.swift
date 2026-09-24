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
        List(selection: $selection) {
            if workspace.runs.count == 0 {
                Text("No runs yet. Queue a plan to view potential changes.")
            }
            
            ForEach(workspace.runs.sorted { $0.number > $1.number }) { run in
                RunSummaryView(run: run)
                    .tag(run.id)
            }
        }
        .navigationTitle("Runs")
//        .navigationSubtitle("\(workspace.runs.count) runs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    workspace.queueRun()
                    selection = workspace.runs.last?.id
                }) {
                    Label("Queue plan", systemImage: "text.badge.plus")
                }
                .labelStyle(.iconOnly)
                .help("Queue a Terraform plan")
                .disabled(workspace.locked || !workspace.isValid)
            }
        }
    }
}

struct RunListPage_Previews: PreviewProvider {
    static let workspace: Workspace = {
        let model = Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable"))
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
