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
    var onReviewRun: (UUID) -> Void = { _ in }

    private var latestRun: TerraformRun? {
        guard workspace.historyPageOffset == 0 else { return nil }
        return workspace.runs.max { $0.number < $1.number }
    }

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

                if !workspace.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(workspace.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 20) {
                    Label("\(workspace.state?.resources.count ?? 0) resources", systemImage: "cube")
                    Label("\(workspace.state?.outputs.count ?? 0) outputs", systemImage: "arrow.up.right.square")
                }
                .font(.callout).foregroundStyle(.secondary)

                GroupBox("Latest run") {
                    if let run = latestRun {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Run #\(run.number)").font(.headline)
                                Spacer()
                                Text(run.status.rawValue.capitalized).foregroundStyle(.secondary)
                            }
                            Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if let message = run.message, !message.isEmpty { Text(message) }
                            HStack(spacing: 16) {
                                if let count = run.added { Text("\(count) to create") }
                                if let count = run.changed { Text("\(count) to update") }
                                if let count = run.destroyed { Text("\(count) to destroy") }
                            }
                            .font(.callout)
                            Button("Review run") { onReviewRun(run.id) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(workspace.historyError ?? (workspace.historyLoading || workspace.historyPageOffset > 0
                             ? "Loading the latest run…" : "No saved runs. Create a plan to review the proposed changes."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Terraform context") {
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow { Text("Version").foregroundStyle(.secondary); Text(workspace.terraformVersion) }
                        GridRow { Text("State backend").foregroundStyle(.secondary); Text(workspace.backendIdentity) }
                        GridRow { Text("Terraform CLI").foregroundStyle(.secondary); Text("This Mac") }
                        GridRow {
                            Text("Execution").foregroundStyle(.secondary)
                            Text(workspace.backendIdentity == "local" ? "This Mac" : "Determined by Terraform configuration")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .onAppear {
            if workspace.historyPageOffset > 0, !workspace.locked { workspace.reloadRunHistory() }
        }
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
