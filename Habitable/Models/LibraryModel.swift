import Foundation

/// Plain numbers read from a classified map. Nothing here is inferred.
struct LibraryStateSummary: Equatable, Sendable {
    let resourceCount: Int
    let groupCount: Int
    let dataSourceCount: Int
    let kindCounts: [MapKind: Int]
    let recordedAt: Date?
    let serial: Int?
    let versionID: String?
}

enum LibraryEntryKind: Equatable, Sendable {
    case localFolder(URL, remote: TerraformRemoteWorkspaceLink?)
    case cloud(HCPWorkspace, organization: String, hostname: String)
}

struct LibraryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let location: String
    let kind: LibraryEntryKind

    var isLocal: Bool { if case .localFolder = kind { return true } else { return false } }
    var isCloud: Bool { if case .cloud = kind { return true } else { return false } }
}

@MainActor
final class LibraryModel: ObservableObject {
    nonisolated static let maximumLocalEntries = 20
    nonisolated static let maximumStateBytes = 32 * 1_048_576

    @Published private(set) var localEntries: [LibraryEntry] = []
    @Published private(set) var summaries: [String: LibraryStateSummary] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var failures: [String: String] = [:]

    // MARK: Entries

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    func refreshLocal(folders: [URL], helper: URL? = nil) async {
        var seen = Set<String>()
        var candidates: [URL] = []
        for folder in folders {
            let canonical = URL(fileURLWithPath: Self.canonicalPath(folder), isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, seen.insert(canonical.path).inserted else { continue }
            candidates.append(canonical)
            if candidates.count == Self.maximumLocalEntries { break }
        }
        let resolved = await Task.detached(priority: .utility) { () -> [(URL, TerraformRemoteWorkspaceLink?)] in
            var result: [(URL, TerraformRemoteWorkspaceLink?)] = []
            for folder in candidates {
                if Task.isCancelled { break }
                result.append((folder, TerraformRemoteWorkspaceLink.resolve(workingDirectory: folder, helper: helper)))
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        localEntries = resolved.map { folder, link in
            LibraryEntry(id: "local:\(folder.path)", title: folder.lastPathComponent,
                         location: Self.abbreviatedPath(folder.path),
                         kind: .localFolder(folder, remote: link))
        }
    }

    static func cloudEntries(workspaces: [HCPWorkspace], organization: String, hostname: String) -> [LibraryEntry] {
        workspaces.map { workspace in
            LibraryEntry(id: "cloud:\(hostname)/\(organization)/\(workspace.id)", title: workspace.name,
                         location: "\(organization) · HCP Terraform",
                         kind: .cloud(workspace, organization: organization, hostname: hostname))
        }
    }

    // MARK: Summaries

    nonisolated static func summary(for map: ResourceMap, recordedAt: Date?, serial: Int?, versionID: String?) -> LibraryStateSummary {
        var kinds: [MapKind: Int] = [:]
        for tile in map.tiles { kinds[tile.kind, default: 0] += 1 }
        return LibraryStateSummary(resourceCount: map.tiles.reduce(0) { $0 + $1.resources.count },
                                   groupCount: map.tiles.count, dataSourceCount: map.dataSources.count,
                                   kindCounts: kinds, recordedAt: recordedAt, serial: serial, versionID: versionID)
    }

    private enum LocalRead: Sendable {
        case absent
        case unreadable
        case summary(LibraryStateSummary)
    }

    nonisolated private static func readLocalState(folder: URL) -> LocalRead {
        let file = folder.appendingPathComponent("terraform.tfstate")
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumStateBytes,
              let data = try? Data(contentsOf: file),
              let resources = try? ResourceMapStateReader.read(data),
              let map = try? ResourceMapClassifier().classify(resources) else { return .unreadable }
        let serial = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["serial"] as? Int
        return .summary(summary(for: map, recordedAt: attributes[.modificationDate] as? Date,
                                serial: serial, versionID: nil))
    }

    func loadSummary(for entry: LibraryEntry, cloud: HCPWorkspaceViewerModel?) async {
        guard !loading.contains(entry.id) else { return }
        switch entry.kind {
        case .localFolder(let folder, _):
            guard summaries[entry.id] == nil else { return }
            loading.insert(entry.id)
            defer { loading.remove(entry.id) }
            let result = await Task.detached(priority: .utility) { Self.readLocalState(folder: folder) }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .absent: failures[entry.id] = nil
            case .unreadable: failures[entry.id] = "State file couldn’t be read."
            case .summary(let summary):
                summaries[entry.id] = summary
                failures[entry.id] = nil
            }
        case .cloud(let workspace, _, _):
            guard let cloud else { return }
            loading.insert(entry.id)
            defer { loading.remove(entry.id) }
            do {
                let snapshot = try await cloud.librarySnapshot(for: workspace)
                guard !Task.isCancelled else { return }
                if summaries[entry.id]?.versionID == snapshot.versionID { return }
                summaries[entry.id] = Self.summary(for: snapshot.map, recordedAt: snapshot.stateCreatedAt,
                                                   serial: snapshot.stateSerial, versionID: snapshot.versionID)
                failures[entry.id] = nil
            } catch {
                guard !Task.isCancelled else { return }
                if case HCPViewerError.response(status: 404, message: _) = error {
                    failures[entry.id] = nil   // No current state version: no summary, not a failure.
                } else if case HCPViewerError.response(status: 403, message: _) = error {
                    failures[entry.id] = "Your credential cannot read this workspace’s state."
                } else if case HCPViewerError.noCredential = error {
                    failures[entry.id] = "Your HCP credential is unavailable."
                } else {
                    failures[entry.id] = "State couldn’t be loaded."
                }
            }
        }
    }
}
