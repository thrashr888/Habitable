//
//  Workspace.swift
//  Habitable
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

    private var readiness: (title: String, detail: String, action: String) {
        if workspace.locked { return ("Terraform is running", "Wait for the current command to finish.", "") }
        if !workspace.isInitialized { return ("Initialization needed", "Install the selected backend and provider dependencies.", "Initialize") }
        if !workspace.isValid { return ("Configuration needs attention", "Validate the configuration, then review any errors before planning.", "Validate") }
        return ("Ready to plan", "The folder is initialized and its configuration is valid.", "Plan")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspace").font(.largeTitle)
                    if let directory = workspace.workingDirectory {
                        Text(directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent)
                            .font(.title3.weight(.medium))
                        Text(directory.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(workspace.executionContextDisplay)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                GroupBox("Readiness") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(readiness.title, systemImage: workspace.isInitialized && workspace.isValid ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.headline)
                        Text(readiness.detail).foregroundStyle(.secondary)
                        if !readiness.action.isEmpty {
                            Button(readiness.action) {
                                switch readiness.action {
                                case "Initialize": workspace.initialize()
                                case "Validate": workspace.validate()
                                default: workspace.validateAndQueueRun()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.locked)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Checks") {
                    VStack(alignment: .leading, spacing: 8) {
                        CheckView(label: "Initialized", check: workspace.isInitialized)
                        CheckView(label: "Configuration is valid", check: workspace.isValid)
                        CheckView(label: "State available", check: workspace.hasState, failureIsError: false)
                        CheckView(label: ".tfvars file exists (optional)", check: workspace.hasVariables, failureIsError: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if workspace.isInitialized {
                    Button("Reinitialize Terraform…", action: workspace.initialize)
                        .disabled(workspace.locked)
                        .help("Reinitialize the backend and provider dependencies for this folder.")
                }

                if let error = workspace.workspaceOpenError { ErrorView(message: error) }
                if let error = workspace.rememberedInputsError { ErrorView(message: error) }
                if let error = workspace.errorMessage { ErrorView(message: error) }

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

                if let text = workspace.textOutput {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Text("Command output").font(.headline)
                        TextLogView(text: text)
                            .frame(height: 240)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Workspace")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { workspace.initialize() }) {
                    Label(workspace.isInitialized ? "Reinitialize" : "Initialize", systemImage: "shippingbox")
                }
                .help(workspace.isInitialized ? "Reinitialize backend and provider dependencies" : "Initialize Terraform in this folder")
                .disabled(workspace.locked || workspace.workingDirectory == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { workspace.validate() }) {
                    Label("Validate", systemImage: "checkmark.seal")
                }
                .help("Validate Terraform configuration")
                .disabled(workspace.locked || workspace.workingDirectory == nil)
            }
        }
    }
}

struct WorkspacePage_Previews: PreviewProvider {
    static var previews: some View {
        WorkspacePage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
