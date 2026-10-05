//
//  HabitableApp.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import SwiftUI

@main
struct HabitableApp: App {
    @StateObject private var cloud = HCPWorkspaceViewerModel()
    var body: some Scene {
        WindowGroup("Workspace", id: "Workspace.viewer", for: URL.self) { $directory in
            ContentView(initialDirectory: directory, onOpenRemoteWorkspace: { link in
                Task { await cloud.openLinkedWorkspace(link) }
            })
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands { WorkspaceCommands() }

        Window("HCP Terraform", id: "HCP.browser") {
            CloudWorkspaceWindow(model: cloud)
                .frame(minWidth: 900, minHeight: 560)
        }.windowToolbarStyle(.unifiedCompact).defaultSize(width: 1400, height: 880)

        Window("Settings", id: "App.settings") {
            ConnectionsSettingsWindow(model: cloud)
                .frame(minWidth: 660, minHeight: 560)
        }.windowToolbarStyle(.unifiedCompact)
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceWindowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "App.settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("New Local Workspace Window") { openWindow(id: "Workspace.viewer") }
            Button("HCP Terraform Window") { openWindow(id: "HCP.browser") }
            Divider()
            Button { actions?.openFolder() } label: { Label("Open…", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil)
            Menu("Open Recent") {
                if let actions, !actions.recentFolders.isEmpty {
                    ForEach(actions.recentFolders, id: \.path) { url in
                        Button("\(url.lastPathComponent) — \(url.path)") { actions.openRecent(url) }
                    }
                    Divider()
                    Button("Clear Recent Folders") { actions.clearRecents() }
                } else {
                    Text("No Recent Folders").disabled(true)
                }
            }
            .disabled(actions == nil)
        }
        CommandMenu("Terraform") {
            Button(actions?.planTitle ?? "Plan") { actions?.plan() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.canPlan != true)
            Divider()
            Button("Initialize Terraform") { actions?.initialize() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.canInitialize != true)
            Button("Validate Configuration") { actions?.validate() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.canValidate != true)
        }
    }
}

private struct CloudWorkspaceWindow: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var recentWorkspaces = RecentWorkspaceStore()
    @StateObject private var localLinks = LocalWorkspaceLinkIndex()

    /// Known local folders whose verified backend identity is the selected
    /// remote workspace. Folder names are never used to infer a match.
    private var linkedLocalFolders: [URL] {
        guard let workspace = model.selectedWorkspace else { return [] }
        return localLinks.folders(hostname: model.hostname, organization: model.selectedOrganization,
                                  workspaceName: workspace.name)
    }

    var body: some View {
        HCPWorkspaceViewer(model: model,
            onOpenConnections: { openWindow(id: "App.settings") })
            .navigationTitle(model.selectedWorkspace?.name ?? "HCP Terraform")
            .navigationSubtitle(model.isConnected ? "\(model.selectedOrganization) · HCP Terraform" : "")
            .toolbar {
                ToolbarItemGroup {
                    let folders = linkedLocalFolders
                    if folders.count == 1, let folder = folders.first {
                        Button { openWindow(id: "Workspace.viewer", value: folder) } label: {
                            Label("Open local folder", systemImage: "folder.badge.gearshape")
                        }
                        .help("Open \(folder.path), whose Terraform backend is this workspace")
                    } else if folders.count > 1 {
                        Menu {
                            ForEach(folders, id: \.path) { folder in
                                Button(folder.path) { openWindow(id: "Workspace.viewer", value: folder) }
                            }
                        } label: { Label("Open local folder", systemImage: "folder.badge.gearshape") }
                        .help("Local folders whose Terraform backend is this workspace")
                    } else {
                        Button { openWindow(id: "Workspace.viewer") } label: { Label("Local workspace", systemImage: "folder") }
                    }
                    Button { openWindow(id: "App.settings") } label: { Label("Connections", systemImage: "network") }
                }
            }
            .onAppear { model.setVisible(true) }
            .onDisappear { model.setVisible(false) }
            .task { if !model.isConnected && !model.isLoading && model.hasStoredCredential { await model.connect() } }
            .task(id: recentWorkspaces.paths) { await localLinks.refresh(folders: recentWorkspaces.folders) }
    }
}

private struct ConnectionsSettingsWindow: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsWindow(model: model,
            onOpenWorkspaces: { openWindow(id: "HCP.browser") },
            onOpenLocalWorkspace: { openWindow(id: "Workspace.viewer") })
            .navigationTitle("Settings")
    }
}
