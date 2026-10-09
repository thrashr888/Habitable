//
//  HabitableApp.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import AppKit
import SwiftUI

/// Folders handed to the app from outside: Finder's Open With, a drop on the
/// Dock icon, or `open -a Habitable <folder>`. Each one gets its own window.
@MainActor
final class FolderOpenRequests: ObservableObject {
    @Published var pending: [URL] = []
}

final class HabitableAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let requests = FolderOpenRequests()
    /// Folders that arrived from outside the app and have not been opened yet.
    /// Their window asks before `terraform init` runs anything.
    @MainActor private static var externalFolders = Set<String>()

    @MainActor static func markExternal(_ folder: URL) {
        externalFolders.insert(RecentWorkspaceStore.canonicalPath(folder))
    }

    /// True once for a folder that came from outside; the window consumes the mark.
    @MainActor static func consumeExternal(_ folder: URL?) -> Bool {
        guard let folder else { return false }
        return externalFolders.remove(RecentWorkspaceStore.canonicalPath(folder)) != nil
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard !folders.isEmpty else { return }
        Task { @MainActor in Self.requests.pending.append(contentsOf: folders) }
    }
}

@main
struct HabitableApp: App {
    @NSApplicationDelegateAdaptor private var delegate: HabitableAppDelegate
    @StateObject private var cloud = HCPWorkspaceViewerModel()
    @StateObject private var agentAccess = HabitableAgentAccess()
    @StateObject private var recentWorkspaces = RecentWorkspaceStore()
    var body: some Scene {
        WindowGroup("Workspace", id: "Workspace.viewer", for: URL.self) { $directory in
            ContentView(initialDirectory: directory, cloud: cloud, agentAccess: agentAccess, onOpenRemoteWorkspace: { link in
                Task { await cloud.openLinkedWorkspace(link) }
            })
                // The restored window value can arrive after the first render; rebuilding
                // on it keeps a Library window a Library and a folder window its folder.
                .id(directory)
                .frame(minWidth: 900, minHeight: 560)
                .background(FolderOpenHandler())
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands { WorkspaceCommands(recentWorkspaces: recentWorkspaces) }

        Window("HCP Terraform", id: "HCP.browser") {
            CloudWorkspaceWindow(model: cloud)
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowMenuMembership())
        }.windowToolbarStyle(.unifiedCompact).defaultSize(width: 1400, height: 880)

        Window("Settings", id: "App.settings") {
            ConnectionsSettingsWindow(model: cloud, agentAccess: agentAccess)
                .frame(minWidth: 660, minHeight: 560)
                .background(WindowMenuMembership())
        }.windowToolbarStyle(.unifiedCompact)
    }
}

/// Opens a window for each folder the system hands the app. Any one window
/// drains the queue; the rest see it empty.
private struct FolderOpenHandler: View {
    @ObservedObject private var requests = HabitableAppDelegate.requests
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onReceive(requests.$pending.dropFirst()) { folders in
                guard !folders.isEmpty else { return }
                requests.pending = []
                for folder in folders {
                    let url = folder.standardizedFileURL
                    // One window per folder: a second open brings the existing window forward.
                    if let existing = NSApp.windows.first(where: { $0.representedURL?.standardizedFileURL == url }) {
                        existing.makeKeyAndOrderFront(nil)
                    } else {
                        HabitableAppDelegate.markExternal(url)
                        openWindow(id: "Workspace.viewer", value: url)
                    }
                }
            }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceWindowActions) private var actions
    /// Open… and Open Recent work with no window in front: they open a new one.
    @ObservedObject var recentWorkspaces: RecentWorkspaceStore

    private func openFolderInNewWindow() {
        let panel = NSOpenPanel()
        panel.title = "Open Terraform Folder"
        panel.message = "Choose a local folder containing your Terraform configuration."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openWindow(id: "Workspace.viewer", value: url.standardizedFileURL)
        }
    }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "App.settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Library") { openWindow(id: "Workspace.viewer", value: ContentView.libraryURL) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("New Local Workspace Window") { openWindow(id: "Workspace.viewer") }
            Button("HCP Terraform Window") { openWindow(id: "HCP.browser") }
            Divider()
            Button {
                if let actions { actions.openFolder() } else { openFolderInNewWindow() }
            } label: { Label("Open…", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                let folders = actions?.recentFolders ?? recentWorkspaces.folders
                if !folders.isEmpty {
                    ForEach(folders, id: \.path) { url in
                        Button("\(url.lastPathComponent) — \(url.path)") {
                            if let actions { actions.openRecent(url) } else { openWindow(id: "Workspace.viewer", value: url) }
                        }
                    }
                    Divider()
                    Button("Clear Recent Folders") {
                        if let actions { actions.clearRecents() } else { recentWorkspaces.clear() }
                    }
                } else {
                    Text("No Recent Folders").disabled(true)
                }
            }
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
    @StateObject private var checkout = WorkspaceCheckoutCoordinator()

    /// Known local folders whose verified backend identity is the selected
    /// remote workspace, plus folders this app checked out from it. Folder
    /// names are never used to infer a match.
    private var linkedLocalFolders: [URL] {
        guard let workspace = model.selectedWorkspace else { return [] }
        var folders = localLinks.folders(hostname: model.hostname, organization: model.selectedOrganization,
                                         workspaceName: workspace.name)
        for record in checkout.store.records(hostname: model.hostname, organization: model.selectedOrganization, workspaceID: workspace.id) {
            let url = URL(fileURLWithPath: record.path, isDirectory: true)
            if !folders.contains(where: { RecentWorkspaceStore.canonicalPath($0) == record.path }) { folders.append(url) }
        }
        return folders
    }

    var body: some View {
        HCPWorkspaceViewer(model: model,
            onOpenConnections: { openWindow(id: "App.settings") },
            linkedFolders: linkedLocalFolders,
            onCheckOut: model.selectedWorkspace.map { workspace in
                { checkout.checkOut(workspace: workspace, organization: model.selectedOrganization, hostname: model.hostname) { _ in } }
            })
            .navigationTitle(model.selectedWorkspace?.name ?? "HCP Terraform")
            .navigationSubtitle(model.isConnected ? "\(model.selectedOrganization) · HCP Terraform" : "")
            .toolbar {
                ToolbarItemGroup {
                    let folders = linkedLocalFolders
                    if folders.count == 1, let folder = folders.first {
                        Button { openWindow(id: "Workspace.viewer", value: folder) } label: {
                            Label("Open Folder", systemImage: "folder.badge.gearshape").labelStyle(.titleAndIcon)
                        }
                        .help("Open \(folder.path), whose Terraform backend is this workspace")
                    } else if folders.count > 1 {
                        Menu {
                            ForEach(folders, id: \.path) { folder in
                                Button(folder.path) { openWindow(id: "Workspace.viewer", value: folder) }
                            }
                        } label: { Label("Open Folder", systemImage: "folder.badge.gearshape").labelStyle(.titleAndIcon) }
                        .help("Local folders whose Terraform backend is this workspace")
                    } else if let workspace = model.selectedWorkspace, workspace.vcs?.cloneURL != nil {
                        if checkout.job != nil {
                            LoadingIndicator(size: 14, label: "Checking out…")
                        } else {
                            Button {
                                checkout.checkOut(workspace: workspace, organization: model.selectedOrganization, hostname: model.hostname) { folder in
                                    openWindow(id: "Workspace.viewer", value: folder)
                                }
                            } label: { Label("Check Out…", systemImage: "arrow.down.to.line").labelStyle(.titleAndIcon) }
                            .help("Clone \(workspace.vcs?.displayName ?? "the repository") onto this Mac and open it")
                        }
                    } else {
                        Button { openWindow(id: "Workspace.viewer") } label: { Label("Local Folder", systemImage: "folder").labelStyle(.titleAndIcon) }
                    }
                    Button { openWindow(id: "App.settings") } label: { Label("Connections", systemImage: "network").labelStyle(.titleAndIcon) }
                }
            }
            .onAppear { model.setVisible(true) }
            .onDisappear { model.setVisible(false) }
            .task { if !model.isConnected && !model.isLoading && model.hasStoredCredential { await model.connect() } }
            .task(id: recentWorkspaces.paths) { await localLinks.refresh(folders: recentWorkspaces.folders) }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in checkout.store.reload() }
            .alert("Check Out", isPresented: Binding(get: { checkout.errorMessage != nil }, set: { if !$0 { checkout.errorMessage = nil } })) {
                Button("OK", role: .cancel) { checkout.errorMessage = nil }
            } message: { Text(checkout.errorMessage ?? "") }
    }
}

private struct ConnectionsSettingsWindow: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @ObservedObject var agentAccess: HabitableAgentAccess
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsWindow(model: model, agentAccess: agentAccess,
            onOpenWorkspaces: { openWindow(id: "HCP.browser") },
            onOpenLocalWorkspace: { openWindow(id: "Workspace.viewer") })
            .navigationTitle("Settings")
    }
}
