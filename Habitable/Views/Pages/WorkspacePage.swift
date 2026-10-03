//
//  Workspace.swift
//  Habitable
//

import SwiftUI
import MarkdownUI

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
    var onReviewRun: @MainActor @Sendable (UUID) -> Void = { _ in }
    var onOpenConfiguration: () -> Void = {}
    var onOpenInputs: () -> Void = {}

    private var latestRun: TerraformRun? {
        guard workspace.historyPageOffset == 0 else { return nil }
        return workspace.runs.max { $0.number < $1.number }
    }

    private var readiness: (title: String, detail: String, action: String) {
        if workspace.locked { return ("Terraform is running", "Wait for the current command to finish.", "") }
        if workspace.isInspectingInputs { return ("Reading configuration inputs", "Discovering variables and their value sources…", "") }
        let missing = workspace.terraformVariables.filter {
            $0.declaration?.required == true && !$0.isUserInput && $0.discoveredSource == nil && !$0.hasUnresolvedDiscoveredValue
        }.count
        if missing > 0 { return ("\(missing) required input\(missing == 1 ? "" : "s") need values", "Supply the missing values before creating a plan.", "Inputs") }
        if !workspace.isInitialized { return ("Initialization needed", "Install the selected backend and provider dependencies.", "Initialize") }
        if !workspace.isValid { return ("Configuration needs attention", "Validate the configuration, then review any errors before planning.", "Validate") }
        return ("Ready to plan", "The folder is initialized and its configuration is valid.", workspace.autoApply ? "Plan and apply automatically" : "Plan")
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

                GroupBox("Readiness") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(readiness.title, systemImage: readiness.action == "Plan" || readiness.action == "Plan and apply automatically" ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.headline)
                        Text(readiness.detail).foregroundStyle(.secondary)
                        if workspace.autoApply {
                            Label("Automatic apply is on. A successful plan will apply changes without another confirmation.", systemImage: "exclamationmark.triangle")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if workspace.canCancelCommand {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(workspace.isCancelingCommand ? "Stopping Terraform…" : "Terraform is running…")
                                Spacer()
                                Button("Cancel", action: workspace.cancelCommand).disabled(workspace.isCancelingCommand)
                            }
                        }
                        if !readiness.action.isEmpty {
                            Button(readiness.action) {
                                switch readiness.action {
                                case "Inputs": onOpenInputs()
                                case "Initialize": workspace.initialize()
                                case "Validate": workspace.validate()
                                default: workspace.validateAndQueueRun(onCreated: onReviewRun)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.locked)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                DisclosureGroup("Getting started with Terraform") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Describe what you want").font(.headline)
                            Text("Configuration files describe your resources. Providers connect Terraform to services; this app can also run local examples.")
                                .foregroundStyle(.secondary)
                            Button("Browse configuration", action: onOpenConfiguration)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("2. Supply your inputs").font(.headline)
                            Text("Variables customize your configuration. Required inputs need values; defaults can be left alone.")
                                .foregroundStyle(.secondary)
                            Button("Review variables", action: onOpenInputs)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("3. Initialize, validate, and plan").font(.headline)
                            Text("Initialize prepares dependencies. Validate checks the configuration. A plan previews changes before you decide to apply them.")
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("4. Review before applying").font(.headline)
                            Text("Review creations, updates, and deletions. A replacement recreates a resource and may interrupt it. State records what Terraform manages; keep it secure.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                }

                GroupBox("Checks") {
                    VStack(alignment: .leading, spacing: 8) {
                        CheckView(label: "Initialized", check: workspace.isInitialized)
                        CheckView(label: "Configuration is valid", check: workspace.isValid)
                        CheckView(label: "State available", check: workspace.hasState, failureIsError: false)
                        CheckView(label: "Configuration inputs discovered", check: workspace.hasVariables, failureIsError: false)
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

struct WorkspaceReadmePage: View {
    let directory: URL?
    @ObservedObject var presentation: WorkspaceReadmePresentation
    @State private var refreshID = UUID()

    var body: some View {
        ScrollView {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if presentation.loading || !presentation.matches(directory: directory) {
                        ProgressView("Reading README…")
                    } else if let document = presentation.prepared?.document {
                        Text(document.file.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let markdown = presentation.prepared?.markdown {
                            Markdown(markdown, baseURL: document.file.deletingLastPathComponent())
                                .markdownImageProvider(ReadmeImageLinks())
                                .markdownTextStyle { FontSize(14) }
                                .textSelection(.enabled)
                                .environment(\.openURL, OpenURLAction { url in
                                    guard WorkspaceReadme.canOpen(url, relativeTo: document.root) else { return .discarded }
                                    return .systemAction
                                })
                        } else {
                            Text(document.content).textSelection(.enabled)
                        }
                        ExternalEditorPicker(file: document.file)
                    } else {
                        Text(presentation.loadError ?? "Add a README.md to your repository to describe this workspace and how to use it.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack {
                    Text("README").font(.headline)
                    Spacer()
                    Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Refresh README")
                        .accessibilityLabel("Refresh README")
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("README")
        .task(id: "\(directory?.path ?? "")-\(refreshID)") {
            await presentation.load(directory: directory)
        }
    }
}

/// Documentation images remain explicit links instead of making background network requests.
private struct ReadmeImageLinks: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url {
            Link(destination: url) {
                Label("Open image", systemImage: "photo")
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

// MarkdownUI's parsed tree is immutable, composed of value-type nodes, and is
// constructed off the main actor before being handed to the rendering actor.
struct PreparedWorkspaceReadme: @unchecked Sendable {
    let document: WorkspaceReadme
    let markdown: MarkdownContent?
}

@MainActor
final class WorkspaceReadmePresentation: ObservableObject {
    @Published private(set) var prepared: PreparedWorkspaceReadme?
    @Published private(set) var loadError: String?
    @Published private(set) var loading = true
    private var directory: URL?
    private var requestID = UUID()

    func matches(directory: URL?) -> Bool { self.directory == directory }

    func load(directory: URL?) async {
        let id = UUID()
        requestID = id
        if self.directory != directory {
            prepared = nil
            loadError = nil
        }
        self.directory = directory
        loading = prepared == nil
        let previous = prepared
        let result = await Task.detached(priority: .utility) { () -> Result<PreparedWorkspaceReadme?, Error> in
            Result {
                guard let document = try directory.flatMap({ try WorkspaceReadme.load(directory: $0) }) else { return nil }
                if let previous, previous.document.file == document.file, previous.document.content == document.content {
                    return previous
                }
                return PreparedWorkspaceReadme(document: document,
                    markdown: document.isMarkdown ? MarkdownContent(document.content) : nil)
            }
        }.value
        guard !Task.isCancelled, requestID == id else { return }
        switch result {
        case .success(let value): prepared = value; loadError = nil
        case .failure(let error): prepared = nil; loadError = error.localizedDescription
        }
        loading = false
    }
}
