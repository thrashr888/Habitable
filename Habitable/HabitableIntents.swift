import AppIntents
import AppKit
import Foundation

/// Shortcuts and Siri reach the same models the windows use
/// (design: "Native everywhere").
@MainActor
enum IntentRegistry {
    static weak var cloud: HCPWorkspaceViewerModel?
    static var recentFolders: () -> [URL] = { [] }
}

struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace")
    static let defaultQuery = WorkspaceQuery()
    let id: String
    let name: String
    let source: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(source)") }
}

struct WorkspaceQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [WorkspaceEntity] {
        var result: [WorkspaceEntity] = []
        if let cloud = IntentRegistry.cloud, cloud.isConnected {
            for workspace in cloud.workspaces {
                result.append(WorkspaceEntity(id: "cloud:\(workspace.id)", name: workspace.name, source: "\(cloud.selectedOrganization) · HCP Terraform"))
            }
        }
        for folder in IntentRegistry.recentFolders() {
            result.append(WorkspaceEntity(id: "local:\(folder.path)", name: folder.lastPathComponent, source: "This Mac"))
        }
        return result
    }
}

struct CheckDriftIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Drift"
    static let description = IntentDescription("Tells you whether an HCP Terraform workspace has resources that changed outside Terraform.")
    @Parameter(title: "Workspace") var workspace: WorkspaceEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard workspace.id.hasPrefix("cloud:"), let cloud = IntentRegistry.cloud, cloud.isConnected else {
            return .result(dialog: "Drift is checked by HCP Terraform's health assessments, so this works for cloud workspaces while Habitable is signed in.")
        }
        await cloud.refreshExplorer()
        guard let row = cloud.explorerRows[workspace.name] else {
            return .result(dialog: "\(workspace.name) has no health assessment yet.")
        }
        if row.drifted == true {
            let count = row.resourcesDrifted ?? 0
            return .result(dialog: "\(workspace.name): \(count) \(count == 1 ? "resource" : "resources") changed outside Terraform. Open Habitable to see which.")
        }
        return .result(dialog: "\(workspace.name) matches its code. No drift.")
    }
}

struct OpenWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Workspace"
    static let description = IntentDescription("Opens a workspace's Map in Habitable.")
    static let openAppWhenRun = true
    @Parameter(title: "Workspace") var workspace: WorkspaceEntity

    @MainActor func perform() async throws -> some IntentResult {
        if workspace.id.hasPrefix("local:") {
            let folder = URL(fileURLWithPath: String(workspace.id.dropFirst(6)), isDirectory: true)
            HabitableAppDelegate.requests.pending.append(folder)
        } else if let cloud = IntentRegistry.cloud {
            let id = String(workspace.id.dropFirst(6))
            let link = TerraformRemoteWorkspaceLink(hostname: cloud.hostname, organization: cloud.selectedOrganization, workspaceName: workspace.name,
                                                    url: cloud.workspaces.first { $0.id == id }?.htmlURL ?? URL(string: "https://\(cloud.hostname)")!)
            CloudOpenRequests.shared.pending.append(link)
        }
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }
}

struct HabitableShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckDriftIntent(), phrases: ["Check \(\.$workspace) for drift in \(.applicationName)", "Check for drift in \(.applicationName)"],
                    shortTitle: "Check for Drift", systemImageName: "diamond")
        AppShortcut(intent: OpenWorkspaceIntent(), phrases: ["Open \(\.$workspace) in \(.applicationName)"],
                    shortTitle: "Open Workspace", systemImageName: "map")
    }
}
