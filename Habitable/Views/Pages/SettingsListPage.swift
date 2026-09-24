//
//  Settings.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct SettingsListPage: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        Form {
            Section("Workspace") {
                LabeledContent("Working directory") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(workspace.workingDirectory?.path ?? "No folder selected")
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                        Button("Choose folder…", action: workspace.addUrl)
                            .disabled(workspace.locked)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                    TextEditor(text: $workspace.description)
                        .accessibilityLabel("Description")
                        .multilineTextAlignment(.leading)
                        .frame(height: 64)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                }
            }

            TerraformVersionSettings(workspace: workspace)

            Section {
                Toggle("Apply automatically after planning", isOn: $workspace.autoApply)
                    .disabled(workspace.locked)
            } header: {
                Text("Execution")
            } footer: {
                Text("When enabled, a successful plan applies immediately without a review step.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Settings")
    }
}

struct SettingsListPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}


struct TerraformVersionSettings: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var catalog = TerraformReleaseCatalog()
    @State private var selection = ""

    var body: some View {
        Section {
            LabeledContent("Active version") {
                Text(workspace.terraformVersion)
                    .monospacedDigit()
                Text(workspace.managedTerraformVersion == nil ? "System" : "Managed")
                    .foregroundStyle(.secondary)
            }
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
            if let error = workspace.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("Terraform")
        } footer: {
            Text("Downloads are verified and stored by Habitable. Changing versions discards pending plans; queue a new plan before applying.")
        }
        .task {
            await catalog.refresh()
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
