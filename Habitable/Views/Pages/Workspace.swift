//
//  Workspace.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct CheckView: View {
    @State var label: String
    @State var check: Bool
    var body: some View {
        HStack {
            if check {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Image(systemName: "circle.fill").foregroundColor(.red)
            }
            Text(label)
        }
    }
}

struct WorkspacePage: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading) {
            Text("Checks")
                .font(.largeTitle)
                .padding(.bottom, 1)

            CheckView(label: "Initialized", check: workspace.isInitialized)
            CheckView(label: "Config is valid", check: workspace.isValid)
            CheckView(label: "State file exists", check: workspace.hasState)
            CheckView(label: ".tfvars file exists", check: workspace.hasVariables)

            if workspace.workingDirectory == nil {
                Text("Working directory")
                    .font(.headline)
                    .padding(.top)
                Button("Choose folder", action: workspace.addUrl)
            }

            if workspace.workingDirectory != nil && !workspace.isInitialized {
                Button("Initialize workspace") {
                    workspace.initialize()
                }
            }

            if workspace.textOutput != nil {
                Divider()
                TextLogView(text: workspace.textOutput!)
                Spacer()
            }
        }
        .padding(.bottom)
        .navigationTitle("Workspace")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { workspace.initialize() }) {
                    Label("Initialize", systemImage: "chevron.right.square")
                        .help("Initialize")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { workspace.validate() }) {
                    Label("Validate", systemImage: "checkmark.seal")
                        .help("Validate")
                }
            }
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

struct WorkspacePage_Previews: PreviewProvider {
    static var previews: some View {
        WorkspacePage(workspace: Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
