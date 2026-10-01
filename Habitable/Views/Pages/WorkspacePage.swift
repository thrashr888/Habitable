//
//  Workspace.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct CheckView: View {
    let label: String
    let check: Bool
    var failureIsError = true
    var body: some View {
        HStack {
            if check {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Image(systemName: failureIsError ? "nosign" : "minus.circle")
                    .foregroundStyle(failureIsError ? Color.red : Color.secondary)
            }
            Text(label)
        }
    }
}

struct WorkspacePage: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading) {
            Text("Checks")
                .font(.largeTitle)
                .padding(.bottom, 1)

            Text(workspace.executionContextDisplay)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.bottom, 8)

            CheckView(label: "Initialized", check: workspace.isInitialized)
            CheckView(label: "Config is valid", check: workspace.isValid)
            CheckView(label: "State available", check: workspace.hasState, failureIsError: false)
            CheckView(label: ".tfvars file exists (optional)", check: workspace.hasVariables, failureIsError: false)

            if workspace.workingDirectory == nil {
                Text("Working directory")
                    .font(.headline)
                    .padding(.top)
                Button("Choose folder", action: workspace.addUrl)
                    .disabled(workspace.locked)
            }

            if workspace.workingDirectory != nil && !workspace.isInitialized {
                Button("Initialize workspace") {
                    workspace.initialize()
                }
                .disabled(workspace.locked)
            }
            
            if workspace.canCancelCommand {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(workspace.isCancelingCommand ? "Stopping Terraform…" : "Terraform is running…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: workspace.cancelCommand)
                        .disabled(workspace.isCancelingCommand)
                }
            }

            if let error = workspace.errorMessage {
                ErrorView(message: error)
            }

            Spacer()

            if workspace.textOutput != nil {
                Divider()
                TextLogView(text: workspace.textOutput!)
                Spacer()
            }
        }
        .padding(.all)
        .navigationTitle("Workspace")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { workspace.initialize() }) {
                    Label("Initialize", systemImage: "chevron.right.square")
                        .help("Initialize")
                }
                .disabled(workspace.locked)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { workspace.validate() }) {
                    Label("Validate", systemImage: "checkmark.seal")
                        .help("Validate")
                }
                .disabled(workspace.locked)
            }
        }
    }
}

struct WorkspacePage_Previews: PreviewProvider {
    static var previews: some View {
        WorkspacePage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
