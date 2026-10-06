import Foundation

/// Plain numbers read from a classified map. Nothing here is inferred.
struct LibraryStateSummary: Equatable, Sendable, Codable {
    let resourceCount: Int
    let groupCount: Int
    let dataSourceCount: Int
    let kindCounts: [MapKind: Int]
    let recordedAt: Date?
    let serial: Int?
    let versionID: String?

    init(resourceCount: Int, groupCount: Int, dataSourceCount: Int, kindCounts: [MapKind: Int],
         recordedAt: Date?, serial: Int?, versionID: String?) {
        self.resourceCount = resourceCount
        self.groupCount = groupCount
        self.dataSourceCount = dataSourceCount
        self.kindCounts = kindCounts
        self.recordedAt = recordedAt
        self.serial = serial
        self.versionID = versionID
    }

    private enum CodingKeys: String, CodingKey {
        case resourceCount, groupCount, dataSourceCount, kindCounts, recordedAt, serial, versionID
    }

    /// `kindCounts` is stored as `{"<MapKind raw value>": count}` so the JSON stays an object.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resourceCount = try c.decode(Int.self, forKey: .resourceCount)
        groupCount = try c.decode(Int.self, forKey: .groupCount)
        dataSourceCount = try c.decode(Int.self, forKey: .dataSourceCount)
        let raw = try c.decode([String: Int].self, forKey: .kindCounts)
        var kinds: [MapKind: Int] = [:]
        for (key, count) in raw {
            if let value = Int(key), let kind = MapKind(rawValue: value) { kinds[kind] = count }
        }
        kindCounts = kinds
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt)
        serial = try c.decodeIfPresent(Int.self, forKey: .serial)
        versionID = try c.decodeIfPresent(String.self, forKey: .versionID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resourceCount, forKey: .resourceCount)
        try c.encode(groupCount, forKey: .groupCount)
        try c.encode(dataSourceCount, forKey: .dataSourceCount)
        try c.encode(Dictionary(uniqueKeysWithValues: kindCounts.map { (String($0.key.rawValue), $0.value) }), forKey: .kindCounts)
        try c.encodeIfPresent(recordedAt, forKey: .recordedAt)
        try c.encodeIfPresent(serial, forKey: .serial)
        try c.encodeIfPresent(versionID, forKey: .versionID)
    }
}

/// On-disk cache record. Only counts, dates, serial and version id per entry id.
struct LibraryCacheEntry: Codable, Equatable, Sendable {
    let id: String
    let savedAt: Date
    let summary: LibraryStateSummary
}

struct LibraryCacheFile: Codable, Equatable, Sendable {
    var version = 1
    var entries: [LibraryCacheEntry]
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
    nonisolated static let maximumCacheBytes = 4 * 1_048_576
    nonisolated static let cacheLifetime: TimeInterval = 30 * 86_400
    nonisolated static let cacheSaveDelay: Duration = .seconds(1)

    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Habitable", isDirectory: true)
            .appendingPathComponent("library-summaries.json")
    }

    @Published private(set) var localEntries: [LibraryEntry] = []
    @Published private(set) var summaries: [String: LibraryStateSummary] = [:] {
        didSet { if summaries != oldValue { scheduleCacheSave() } }
    }
    /// True once init has loaded the on-disk cache (even if it held nothing usable).
    @Published private(set) var cacheRestored = false
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var lastRefresh: Date?
    private var isRefreshingAll = false
    private let cacheURL: URL?
    private var verifiedAt: [String: Date] = [:]
    private var pendingSave: Task<Void, Never>?

    init(cacheURL: URL? = LibraryModel.defaultCacheURL) {
        self.cacheURL = cacheURL
        if let cacheURL {
            let restored = Self.readCache(at: cacheURL, now: Date())
            for entry in restored {
                verifiedAt[entry.id] = entry.savedAt
                summaries[entry.id] = entry.summary
            }
        }
        cacheRestored = true
    }

    // MARK: Cache

    /// Reads the cache, dropping oversized, unreadable and expired content.
    nonisolated static func readCache(at url: URL, now: Date) -> [LibraryCacheEntry] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumCacheBytes,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(LibraryCacheFile.self, from: data),
              file.version == 1 else { return [] }
        return file.entries.filter { now.timeIntervalSince($0.savedAt) <= cacheLifetime }
    }

    nonisolated private static func writeCache(_ entries: [LibraryCacheEntry], to url: URL) {
        do {
            let data = try JSONEncoder().encode(LibraryCacheFile(entries: entries.sorted { $0.id < $1.id }))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // No persistence is better than a failed refresh.
        }
    }

    private func cacheSnapshot() -> [LibraryCacheEntry] {
        let now = Date()
        return summaries.map { LibraryCacheEntry(id: $0.key, savedAt: verifiedAt[$0.key] ?? now, summary: $0.value) }
    }

    private func markVerified(_ id: String) {
        verifiedAt[id] = Date()
        scheduleCacheSave()
    }

    private func scheduleCacheSave() {
        guard cacheURL != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.cacheSaveDelay)
            guard !Task.isCancelled else { return }
            await self?.flushCache()
        }
    }

    /// Writes the cache now (encode and write run off the main actor). Normally called by the debounce.
    func flushCache() async {
        pendingSave?.cancel()
        pendingSave = nil
        guard let cacheURL else { return }
        let snapshot = cacheSnapshot()
        await Task.detached(priority: .utility) { Self.writeCache(snapshot, to: cacheURL) }.value
    }

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
        case unchanged
        case unreadable
        case summary(LibraryStateSummary)
    }

    /// Pure: a cloud summary is reloaded only when the current state version differs
    /// from the cached one. No current version means there is nothing to download.
    nonisolated static func needsCloudReload(cached: LibraryStateSummary?, currentVersionID: String?) -> Bool {
        guard let currentVersionID else { return false }
        return cached?.versionID != currentVersionID
    }

    /// Pure: a local summary is re-read when the file's modification date changed.
    nonisolated static func needsLocalReload(cached: LibraryStateSummary?, modified: Date?) -> Bool {
        guard let cached, let cachedDate = cached.recordedAt, let modified else { return true }
        return cachedDate != modified
    }

    nonisolated private static func readLocalState(folder: URL, cached: LibraryStateSummary?) -> LocalRead {
        let file = folder.appendingPathComponent("terraform.tfstate")
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumStateBytes else { return .unreadable }
        let modified = attributes[.modificationDate] as? Date
        guard needsLocalReload(cached: cached, modified: modified) else { return .unchanged }
        guard let data = try? Data(contentsOf: file),
              let resources = try? ResourceMapStateReader.read(data),
              let map = try? ResourceMapClassifier().classify(resources) else { return .unreadable }
        let serial = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["serial"] as? Int
        return .summary(summary(for: map, recordedAt: modified, serial: serial, versionID: nil))
    }

    /// Loads or refreshes one entry. Local: re-reads when the state file changed.
    /// Cloud: asks for the current state version id first and skips the download
    /// when it matches the cached summary.
    func loadSummary(for entry: LibraryEntry, cloud: HCPWorkspaceViewerModel?) async {
        guard !loading.contains(entry.id) else { return }
        switch entry.kind {
        case .localFolder(let folder, _):
            loading.insert(entry.id)
            defer { loading.remove(entry.id) }
            let cached = summaries[entry.id]
            let result = await Task.detached(priority: .utility) {
                Self.readLocalState(folder: folder, cached: cached)
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .unchanged:
                failures[entry.id] = nil
                markVerified(entry.id)
            case .absent:
                summaries[entry.id] = nil
                failures[entry.id] = nil
            case .unreadable:
                summaries[entry.id] = nil
                failures[entry.id] = "State file couldn’t be read."
            case .summary(let summary):
                summaries[entry.id] = summary
                failures[entry.id] = nil
                markVerified(entry.id)
            }
        case .cloud(let workspace, _, _):
            guard let cloud else { return }
            loading.insert(entry.id)
            defer { loading.remove(entry.id) }
            do {
                let versionID = try await cloud.librarySnapshotVersionID(for: workspace)
                guard !Task.isCancelled else { return }
                guard let versionID else {
                    summaries[entry.id] = nil   // No current state version: no summary, not a failure.
                    failures[entry.id] = nil
                    return
                }
                guard Self.needsCloudReload(cached: summaries[entry.id], currentVersionID: versionID) else {
                    failures[entry.id] = nil
                    markVerified(entry.id)
                    return
                }
                let snapshot = try await cloud.librarySnapshot(for: workspace)
                guard !Task.isCancelled else { return }
                summaries[entry.id] = Self.summary(for: snapshot.map, recordedAt: snapshot.stateCreatedAt,
                                                   serial: snapshot.stateSerial, versionID: snapshot.versionID)
                failures[entry.id] = nil
                markVerified(entry.id)
            } catch {
                guard !Task.isCancelled else { return }
                if case HCPViewerError.response(status: 404, message: _) = error {
                    failures[entry.id] = nil
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

    /// Loads or refreshes summaries for all entries with bounded concurrency (3),
    /// local first, then cloud. A second call while one runs is ignored.
    func refreshAll(_ entries: [LibraryEntry], cloud: HCPWorkspaceViewerModel?) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        let ordered = entries.filter(\.isLocal) + entries.filter(\.isCloud)
        // Fixed worker pool: three workers pull from a shared queue on the main actor.
        let queue = WorkQueue(ordered)
        let workers = (0..<min(3, ordered.count)).map { _ in
            Task { @MainActor in
                while let entry = queue.next() { await self.loadSummary(for: entry, cloud: cloud) }
            }
        }
        await withTaskCancellationHandler {
            for worker in workers { await worker.value }
        } onCancel: {
            for worker in workers { worker.cancel() }
        }
        if !Task.isCancelled { lastRefresh = Date() }
    }
}

@MainActor
private final class WorkQueue {
    private var items: [LibraryEntry]
    init(_ items: [LibraryEntry]) { self.items = items.reversed() }
    func next() -> LibraryEntry? { Task.isCancelled ? nil : items.popLast() }
}
