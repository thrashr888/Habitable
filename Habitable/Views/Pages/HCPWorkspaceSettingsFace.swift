import SwiftUI

/// Workspace settings Habitable can change from this Mac: Terraform version,
/// apply without confirmation, execution mode and working directory. Nothing
/// is sent until Save, and the record shown afterwards is HCP's answer.
struct HCPWorkspaceSettingsFace: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @StateObject private var releases = TerraformReleaseCatalog()

    @State private var terraformVersion = ""
    @State private var autoApply = false
    @State private var executionMode = "remote"
    @State private var workingDirectory = ""
    @State private var description = ""
    @State private var loadedFor: String?
    @State private var saved = false

    private var workspace: HCPWorkspace? { model.selectedWorkspace }
    private var recordSignature: String {
        guard let workspace else { return "" }
        return [workspace.id, workspace.terraformVersion ?? "", workspace.executionMode ?? "", workspace.workingDirectory ?? "",
                workspace.autoApply ? "auto" : "confirm", workspace.description ?? "", workspace.locked ? "locked" : "open"].joined(separator: "|")
    }

    /// "latest", the workspace's own value, then released versions newest first.
    private var versionChoices: [String] {
        var choices = ["latest"]
        if let current = workspace?.terraformVersion, !choices.contains(current) { choices.append(current) }
        for release in releases.releases where !choices.contains(release.version) { choices.append(release.version) }
        return choices
    }

    private var executionModes: [String] {
        var modes = ["remote", "local"]
        if workspace?.executionMode == "agent" || executionMode == "agent" { modes.append("agent") }
        return modes
    }

    private var pending: HCPWorkspaceSettingsChange {
        guard let workspace else { return HCPWorkspaceSettingsChange() }
        var change = HCPWorkspaceSettingsChange()
        if terraformVersion != (workspace.terraformVersion ?? ""), !terraformVersion.isEmpty { change.terraformVersion = terraformVersion }
        if autoApply != workspace.autoApply { change.autoApply = autoApply }
        if executionMode != (workspace.executionMode ?? "remote") { change.executionMode = executionMode }
        let directory = workingDirectory.trimmingCharacters(in: .whitespaces)
        if directory != (workspace.workingDirectory ?? "") { change.workingDirectory = directory }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != (workspace.description ?? "") { change.description = text }
        return change
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let workspace {
                    section("Workspace") {
                        row("Description") {
                            TextField("What this workspace manages", text: $description, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(1...4).frame(maxWidth: 300)
                        }
                        row("Project") {
                            Text(workspace.projectName ?? "Default Project").font(.system(size: 13))
                        }
                        row("Lock") {
                            HStack(spacing: 10) {
                                HStack(spacing: 5) {
                                    Image(systemName: workspace.locked ? "lock.fill" : "lock.open")
                                    Text(workspace.locked ? "Locked" : "Unlocked")
                                }
                                .font(.system(size: 13))
                                Button(workspace.locked ? "Unlock" : "Lock…") {
                                    Task { _ = await model.setSelectedWorkspaceLocked(!workspace.locked) }
                                }
                                .disabled(model.isSavingWorkspaceSettings)
                                .help(workspace.locked ? "Lets runs start again" : "Queues new runs until the workspace is unlocked")
                            }
                        }
                    }
                    section("Terraform") {
                        row("Version") {
                            Picker("Terraform version", selection: $terraformVersion) {
                                ForEach(versionChoices, id: \.self) { version in
                                    Text(version == "latest" ? "Latest" : version).tag(version)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 160)
                        }
                        if releases.isLoading && releases.releases.isEmpty {
                            Text("Loading released versions…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        row("Execution mode") {
                            Picker("Execution mode", selection: $executionMode) {
                                ForEach(executionModes, id: \.self) { mode in Text(mode.capitalized).tag(mode) }
                            }
                            .labelsHidden().frame(maxWidth: 160)
                        }
                        row("Working directory") {
                            TextField("Repository root", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        }
                    }
                    section("Applying") {
                        Toggle(isOn: $autoApply) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply without confirmation").font(.system(size: 13))
                                Text("Runs apply as soon as their plan succeeds. Off means every apply waits for a confirmation here or in HCP Terraform.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .quickHelp(glossary: "auto-apply")
                    }
                    if workspace.locked {
                        Text("This workspace is locked in HCP Terraform; settings still save, but runs wait for the unlock.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let error = model.workspaceSettingsError {
                        Text(error).font(.system(size: 13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if saved {
                            Label("Saved", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revert") { load(workspace) }.disabled(pending.isEmpty || model.isSavingWorkspaceSettings)
                        Button(model.isSavingWorkspaceSettings ? "Saving…" : "Save") {
                            let change = pending
                            Task {
                                if await model.updateWorkspaceSettings(change) {
                                    saved = true
                                    if let workspace = model.selectedWorkspace { load(workspace) }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pending.isEmpty || model.isSavingWorkspaceSettings)
                    }
                    Text("Workspace settings are updated only when you choose Save.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let url = workspace.htmlURL {
                        ExternalLink(title: "All settings in HCP Terraform", url: url.appendingPathComponent("settings").appendingPathComponent("general"))
                            .buttonStyle(.link).font(.system(size: 13))
                    }
                } else {
                    Text("Choose a workspace to see its settings.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: workspace?.id) {
            if let workspace, loadedFor != workspace.id { load(workspace) }
            await releases.refreshIfNeeded()
        }
        // The record can arrive or change after the first load (a placeholder from
        // the remembered selection, a refresh); follow it unless edits are pending.
        .onChange(of: recordSignature) { _ in
            if let workspace, pending.isEmpty || loadedFor != workspace.id { load(workspace) }
        }
        .task(id: saved) {
            guard saved else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saved = false
        }
    }

    private func load(_ workspace: HCPWorkspace) {
        terraformVersion = workspace.terraformVersion ?? "latest"
        autoApply = workspace.autoApply
        executionMode = workspace.executionMode ?? "remote"
        workingDirectory = workspace.workingDirectory ?? ""
        description = workspace.description ?? ""
        loadedFor = workspace.id
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
