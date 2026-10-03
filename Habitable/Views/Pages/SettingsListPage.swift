//
//  Settings.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI
import AppKit

struct SettingsListPage: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var catalog: TerraformReleaseCatalog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("Workspace") {
                    if let error = workspace.workspaceOpenError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local folder").font(.headline)
                        HStack(alignment: .top, spacing: 12) {
                            Text(workspace.workingDirectory?.path ?? "No folder selected")
                                .textSelection(.enabled)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Choose folder…", action: workspace.addUrl)
                                .disabled(workspace.locked)
                            if let directory = workspace.workingDirectory {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                                }
                                .disabled(!FileManager.default.fileExists(atPath: directory.path))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                        TextEditor(text: $workspace.description)
                            .accessibilityLabel("Description")
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: 80, maxHeight: 120)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        if let error = workspace.descriptionPersistenceError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if workspace.descriptionNeedsSave {
                            Button("Retry saving description", action: workspace.retrySavingWorkspaceDescription)
                                .disabled(workspace.locked)
                        }
                    }
                }

                if let error = workspace.errorMessage {
                    SettingsSection("Workspace status") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                if workspace.coordinationRecoveryRequired || workspace.coordinationRecoveryNotice != nil {
                    SettingsSection("Workspace coordination") {
                        if workspace.coordinationRecoveryRequired {
                            Text("A previous write failed while updating saved-plan coordination. Recovery checks that no Terraform command is using this workspace, advances its generation, and then clears the failure marker. Existing saved plans will no longer be usable; create a new plan before applying.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Recover coordination", action: workspace.recoverCoordination)
                                .disabled(workspace.locked)
                        }
                        if let notice = workspace.coordinationRecoveryNotice {
                            Label(notice, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                TerraformVersionSettings(workspace: workspace, catalog: catalog)

                SettingsSection("Execution", footer: "When enabled, a successful plan applies immediately without a review step.") {
                    Toggle("Apply automatically after planning", isOn: $workspace.autoApply)
                        .disabled(workspace.locked)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Settings")
    }
}

struct SettingsListPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsListPage(catalog: TerraformReleaseCatalog())
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}


struct TerraformVersionSettings: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: TerraformReleaseCatalog
    @State private var selection = ""

    var body: some View {
        SettingsSection("Terraform", footer: "Downloads are verified and stored by Habitable. Changing versions discards pending plans; queue a new plan before applying.") {
            LabeledContent("Active version") {
                Text(workspace.terraformVersion)
                    .monospacedDigit()
                Text(workspace.managedTerraformVersion == nil ? "System" : "Managed")
                    .foregroundStyle(.secondary)
            }
            .id("\(workspace.terraformVersion)-\(workspace.managedTerraformVersion ?? "system")")
            if !catalog.available.isEmpty {
                Picker("Release", selection: $selection) {
                    ForEach(catalog.available) { release in
                        Text(release.version + (catalog.installed.contains(release) ? " (installed)" : ""))
                            .tag(release.version)
                    }
                }
                .disabled(workspace.locked || catalog.isInstalling)

                HStack {
                    if let latest = catalog.releases.first {
                        Text("Latest stable: \(latest.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(catalog.installed.contains(where: { $0.version == selection }) ? "Use selected version" : "Download and use") {
                        installSelectedVersion()
                    }
                    .disabled(workspace.locked || catalog.isInstalling || selection.isEmpty || selection == workspace.managedTerraformVersion && catalog.service.isInstalled(version: selection))
                }
            }
            HStack {
                Link("HashiCorp releases", destination: TerraformReleaseService.sourceURL)
                Spacer()
                Button {
                    Task { await catalog.refresh(); chooseDefault() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isLoading || catalog.isInstalling)
                Button("Use system Terraform") {
                    workspace.useTerraform(version: nil, executableURL: nil)
                }
                .disabled(workspace.locked || catalog.isInstalling || workspace.managedTerraformVersion == nil)
            }
            DisclosureGroup("Executable location") {
                Text(workspace.runner.executableURL?.path ?? "Terraform not found")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(workspace.runner.executableURL?.path)
            }
            if catalog.isLoading || catalog.isInstalling {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(catalog.status ?? "Loading releases…")
                }
            }
            if let error = catalog.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task {
            await catalog.refreshIfNeeded()
            chooseDefault()
        }
    }

    private func chooseDefault() {
        if !catalog.available.contains(where: { $0.version == selection }) {
            selection = catalog.releases.first?.version ?? catalog.installed.first?.version ?? ""
        }
    }

    private func installSelectedVersion() {
        guard !workspace.locked, let release = catalog.available.first(where: { $0.version == selection }) else { return }
        workspace.lock()
        Task {
            let executable = await catalog.install(release)
            workspace.unlock()
            if let executable = executable {
                workspace.useTerraform(version: release.version, executableURL: executable)
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } label: {
                Text(title).font(.headline)
            }
            if let footer {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
    }
}
