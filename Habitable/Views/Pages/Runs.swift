//
//  Run.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct RunSummaryView: View {
    @State var run: TerraformRun
    var body: some View {
        Text("\(run.id) | \(run.message)")
    }
}

struct RunsListPage: View {
    var workspace: Workspace
    @State var runs: [TerraformRun] = []
    var body: some View {
        List(runs, id: \.id) { run in
            RunSummaryView(run: run)
        }
        .navigationTitle("Runs (\(runs.count))")
        .toolbar {
            ToolbarItem(placement: .status) {
                if workspace.locked {
                    Label("Locked", systemImage: "lock.fill")
                        .help("Locked")
                } else {
                    Label("Unlocked", systemImage: "lock.open.fill")
                        .help("Unlocked")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    workspace.queueRun()
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                        Text("Queue plan")
                    }
                }
            }
        }
    }
}

struct RunsListPage_Previews: PreviewProvider {
    static var previews: some View {
        RunsListPage(workspace: Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")), runs: Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")).runs)
    }
}
