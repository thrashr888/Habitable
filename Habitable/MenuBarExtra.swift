import AppKit
import SwiftUI
import UserNotifications

/// Runs in flight, approvals and drift in the menu bar, with actionable
/// notifications (design: "Menu bar extra and notifications"). Polls the
/// connected organization once a minute; everything shown comes from the
/// same model the HCP Terraform window uses.
@MainActor
final class AttentionCenter: ObservableObject {
    @Published private(set) var items: [AttentionItem] = []
    @Published private(set) var lastChecked: Date?
    private let cloud: HCPWorkspaceViewerModel
    private var loop: Task<Void, Never>?
    private var known: Set<String> = []
    private var primed = false

    init(cloud: HCPWorkspaceViewerModel) {
        self.cloud = cloud
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    deinit { loop?.cancel() }

    func check() async {
        guard cloud.isConnected, !cloud.isSample else { items = []; return }
        await cloud.refreshWorkspaces()
        await cloud.refreshExplorer()
        let fresh = AttentionModel.items(workspaces: cloud.workspaces, explorer: cloud.explorerRows)
        lastChecked = Date()
        let ids = Set(fresh.map(\.id))
        if primed {
            for item in fresh where !known.contains(item.id) { NotificationBridge.post(item, organization: cloud.selectedOrganization) }
        }
        primed = true
        known = ids
        items = fresh
    }

    var attentionCount: Int { items.filter { if case .running = $0.kind { return false }; return true }.count }
}

/// The scene: a cloud in the menu bar, a count when something waits.
struct HabitableMenuBar: View {
    @ObservedObject var cloud: HCPWorkspaceViewerModel
    @ObservedObject var attention: AttentionCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !cloud.isConnected {
            Text("Not signed in to HCP Terraform").foregroundStyle(.secondary)
            Button("Connections…") { openWindow(id: "App.settings"); NSApp.activate(ignoringOtherApps: true) }
        } else if attention.items.isEmpty {
            Text(cloud.selectedOrganization + " · nothing needs you").foregroundStyle(.secondary)
        } else {
            section("Waiting for your approval") { if case .approval = $0.kind { return true }; return false }
            section("Runs in flight") { if case .running = $0.kind { return true }; return false }
            section("Drift detected") { if case .drift = $0.kind { return true }; return false }
        }
        Divider()
        Button("Check now") { Task { await attention.check() } }
        if let checked = attention.lastChecked {
            Text("Checked \(checked.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
        }
        Divider()
        Button("Open Habitable") { openWindow(id: "Workspace.viewer", value: ContentView.libraryURL); NSApp.activate(ignoringOtherApps: true) }
        Button("HCP Terraform Window") { openWindow(id: "HCP.browser"); NSApp.activate(ignoringOtherApps: true) }
    }

    @ViewBuilder private func section(_ title: String, _ belongs: @escaping (AttentionItem) -> Bool) -> some View {
        let rows = attention.items.filter(belongs)
        if !rows.isEmpty {
            Text(title)
            ForEach(rows) { item in
                Button {
                    open(item)
                } label: {
                    Text("\(item.workspaceName) · \(item.title)\(elapsed(item.since))")
                }
            }
            Divider()
        }
    }

    private func elapsed(_ since: Date?) -> String {
        guard let since else { return "" }
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return " · \(seconds)s" }
        if seconds < 3600 { return " · \(seconds / 60) min" }
        if seconds < 172_800 { return " · \(seconds / 3600) h" }
        if seconds < 60 * 86_400 { return " · \(seconds / 86_400) days" }
        return " · since \(since.formatted(date: .abbreviated, time: .omitted))"
    }

    private func open(_ item: AttentionItem) {
        let link = TerraformRemoteWorkspaceLink(hostname: cloud.hostname, organization: cloud.selectedOrganization,
                                                workspaceName: item.workspaceName, url: cloud.workspaces.first { $0.id == item.workspaceID }?.htmlURL ?? URL(string: "https://\(cloud.hostname)")!)
        Task { await cloud.openLinkedWorkspace(link) }
        openWindow(id: "HCP.browser")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The label in the menu bar; it also hosts the handler that opens windows for
/// notification actions, since it is the one view that always exists.
struct HabitableMenuBarLabel: View {
    @ObservedObject var attention: AttentionCenter
    var body: some View {
        HStack(spacing: 3) {
            CloudOpenHandler().frame(width: 0, height: 0)
            Image(systemName: attention.attentionCount > 0 ? "cloud.fill" : "cloud")
            if attention.attentionCount > 0 { Text("\(attention.attentionCount)").monospacedDigit() }
        }
        .accessibilityLabel(attention.attentionCount > 0 ? "Habitable, \(attention.attentionCount) items need you" : "Habitable")
    }
}

/// Cloud workspaces handed to the app from a notification, Spotlight or an intent.
@MainActor
final class CloudOpenRequests: ObservableObject {
    static let shared = CloudOpenRequests()
    @Published var pending: [TerraformRemoteWorkspaceLink] = []
    @Published var pendingResource: String?
}

private struct CloudOpenHandler: View {
    @ObservedObject private var requests = CloudOpenRequests.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .onReceive(requests.$pending.dropFirst()) { links in
                guard let link = links.last, let cloud = NotificationBridge.cloud else { return }
                requests.pending = []
                Task { await cloud.openLinkedWorkspace(link) }
                openWindow(id: "HCP.browser")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// Posts and answers notifications. Approving from Notification Center calls
/// the same confirm the HCP window uses; nothing applies from this Mac.
enum NotificationBridge {
    static let approvalCategory = "habitable.approval"
    static let driftCategory = "habitable.drift"
    static let reviewAction = "review"
    static let confirmAction = "confirm"
    @MainActor static weak var cloud: HCPWorkspaceViewerModel?

    static func configure(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let review = UNNotificationAction(identifier: reviewAction, title: "Review in Habitable", options: [.foreground])
        let confirm = UNNotificationAction(identifier: confirmAction, title: "Confirm Apply", options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [review, confirm], intentIdentifiers: []),
            UNNotificationCategory(identifier: driftCategory, actions: [review], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    @MainActor static func post(_ item: AttentionItem, organization: String) {
        let content = UNMutableNotificationContent()
        switch item.kind {
        case .approval:
            content.title = "\(item.workspaceName) is waiting for your approval"
            content.body = "The plan is ready in HCP Terraform. Review it on the Map, or confirm the apply from here."
            content.categoryIdentifier = approvalCategory
        case .drift(let count):
            content.title = "Drift detected in \(item.workspaceName)"
            content.body = count == 1 ? "1 resource changed outside Terraform." : "\(count) resources changed outside Terraform."
            content.categoryIdentifier = driftCategory
        case .running:
            return
        }
        var info: [String: String] = ["workspaceID": item.workspaceID, "workspaceName": item.workspaceName, "organization": organization]
        if let runID = item.runID { info["runID"] = runID }
        content.userInfo = info
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    @MainActor static func handle(action: String, workspaceID id: String, workspaceName name: String, runID: String?) async {
        guard let cloud else { return }
        let link = TerraformRemoteWorkspaceLink(hostname: cloud.hostname, organization: cloud.selectedOrganization, workspaceName: name,
                                                url: cloud.workspaces.first { $0.id == id }?.htmlURL ?? URL(string: "https://\(cloud.hostname)")!)
        switch action {
        case confirmAction:
            // Only the exact run the notification named, and only while it still waits.
            let confirmed: Bool
            if let runID { confirmed = await cloud.confirmRunFromNotification(workspaceID: id, runID: runID) } else { confirmed = false }
            if !confirmed { CloudOpenRequests.shared.pending.append(link) }
        default:
            CloudOpenRequests.shared.pending.append(link)
        }
    }
}

extension HabitableAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let name = info["workspaceName"] as? String, let id = info["workspaceID"] as? String else { return }
        let runID = info["runID"] as? String
        await NotificationBridge.handle(action: action, workspaceID: id, workspaceName: name, runID: runID)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
