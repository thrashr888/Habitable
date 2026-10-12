import AppKit
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Spotlight knows resource names, addresses and endpoints (design: "Native
/// everywhere"). One domain per workspace, replaced whenever its Map loads.
enum SpotlightIndex {
    struct Entry {
        let address: String
        let type: String
        let endpoints: [String]
    }

    static func index(localFolder: URL, entries: [Entry]) {
        index(domain: "local|\(localFolder.standardizedFileURL.path)", workspaceName: localFolder.lastPathComponent,
              source: "This Mac", entries: entries)
    }

    static func index(cloudHost: String, organization: String, workspaceName: String, entries: [Entry]) {
        index(domain: "cloud|\(cloudHost)|\(organization)|\(workspaceName)", workspaceName: workspaceName,
              source: "\(organization) · HCP Terraform", entries: entries)
    }

    private static func index(domain: String, workspaceName: String, source: String, entries: [Entry]) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        var items: [CSSearchableItem] = []
        let workspace = CSSearchableItemAttributeSet(contentType: .item)
        workspace.title = workspaceName
        workspace.contentDescription = "Workspace · \(source) · Open in Habitable"
        workspace.keywords = ["terraform", "habitable", "workspace", workspaceName]
        items.append(CSSearchableItem(uniqueIdentifier: domain, domainIdentifier: domain, attributeSet: workspace))
        for entry in entries.prefix(2000) {
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            let name = entry.address.split(separator: ".").last.map(String.init) ?? entry.address
            attributes.title = "\(name) · \(workspaceName)"
            attributes.contentDescription = ([entry.address, entry.type] + entry.endpoints).joined(separator: " · ")
            attributes.keywords = [entry.address, entry.type, name, workspaceName] + entry.endpoints
            items.append(CSSearchableItem(uniqueIdentifier: "\(domain)#\(entry.address)", domainIdentifier: domain, attributeSet: attributes))
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Opens what a Spotlight result stands for. Returns false for an unknown identifier.
    @MainActor static func open(identifier: String) -> Bool {
        let parts = identifier.split(separator: "#", maxSplits: 1).map(String.init)
        let domain = parts[0]
        let address = parts.count > 1 ? parts[1] : nil
        let fields = domain.split(separator: "|").map(String.init)
        if fields.first == "local", fields.count == 2 {
            CloudOpenRequests.shared.pendingResource = address
            HabitableAppDelegate.requests.pending.append(URL(fileURLWithPath: fields[1], isDirectory: true))
            return true
        }
        if fields.first == "cloud", fields.count == 4, let cloud = NotificationBridge.cloud {
            CloudOpenRequests.shared.pendingResource = address
            let link = TerraformRemoteWorkspaceLink(hostname: fields[1], organization: fields[2], workspaceName: fields[3],
                                                    url: cloud.workspaces.first { $0.name == fields[3] }?.htmlURL ?? URL(string: "https://\(fields[1])")!)
            CloudOpenRequests.shared.pending.append(link)
            return true
        }
        return false
    }
}
