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
        ScrollView {
            Form {
                Section {
                    Text("Working directory")
                        .font(.headline)
                        .padding(.bottom, 1)
                    VStack(alignment: .leading) {
                        if let workingDirectory = workspace.workingDirectory {
                            Text("\(workingDirectory.path)")
                        }
                        Button("Choose folder", action: workspace.addUrl)
                            .disabled(workspace.locked)
                    }
                    
                    TerraformVersionSettings(workspace: workspace)
                        .padding(.top)

                    Toggle("Auto apply", isOn: $workspace.autoApply)
                        .padding(.top)
                    
                    Text("Description")
                        .font(.headline)
                        .padding(.top)
                    ZStack {
                        TextEditor(text: $workspace.description)
                        Text(workspace.description)
                            .opacity(0)
                            .padding(.all, 8) // <- This will solve the issue if it is in the same ZStack
                    }
                }
            }
            .padding(.all)

        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("")
            }
        }
    }
}

struct SettingsListPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}


struct TerraformVersionSettings: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var catalog = TerraformReleaseCatalog()
    @State private var selection = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terraform").font(.headline)
            Text("Current: \(workspace.terraformVersion)")
            Text(workspace.runner.executableURL?.path ?? "Terraform not found")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .id(workspace.runner.executableURL?.path)
            Link("Official HashiCorp releases", destination: TerraformReleaseService.sourceURL)

            if let latest = catalog.releases.first {
                Text("Latest stable: \(latest.version)")
            }
            if !catalog.available.isEmpty {
                Picker("Version", selection: $selection) {
                    ForEach(catalog.available) { release in
                        Text(release.version + (catalog.installed.contains(release) ? " (installed)" : ""))
                            .tag(release.version)
                    }
                }
                .disabled(catalog.isInstalling)
                Button(catalog.installed.contains(where: { $0.version == selection }) ? "Use selected version" : "Download and use") {
                    installSelectedVersion()
                }
                .disabled(workspace.locked || catalog.isInstalling || selection.isEmpty || selection == workspace.managedTerraformVersion && catalog.service.isInstalled(version: selection))
            }
            HStack {
                Button("Refresh releases") {
                    Task { await catalog.refresh(); chooseDefault() }
                }
                .disabled(catalog.isLoading || catalog.isInstalling)
                Button("Use system Terraform") {
                    workspace.useTerraform(version: nil, executableURL: nil)
                }
                .disabled(workspace.locked || catalog.isInstalling || workspace.managedTerraformVersion == nil)
            }
            if catalog.isLoading || catalog.isInstalling {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(catalog.status ?? "Loading releases…")
                }
            }
            if let error = catalog.error {
                Text(error).foregroundColor(.red).textSelection(.enabled)
            }
            if let error = workspace.errorMessage {
                Text(error).foregroundColor(.red).textSelection(.enabled)
            }
            Text("Downloads are verified and stored by Habitable. Switching versions discards pending plans; queue a new plan before applying.")
                .font(.caption)
                .foregroundColor(.secondary)
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
