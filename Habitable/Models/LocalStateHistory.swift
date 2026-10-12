import CryptoKit
import Foundation

/// One recorded moment of a folder's state, for time travel on the Map.
struct LocalStateVersion: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let resourceCount: Int
    let url: URL
}

/// Saved copies of a folder's `terraform show -json` output, one per distinct
/// state, under Application Support. Nothing is written into the folder itself.
/// Built so the timeline playhead has somewhere to go (design: "Time travel").
final class LocalStateHistory: @unchecked Sendable {
    static let shared = LocalStateHistory()
    static let keepCount = 40

    private let root: URL
    private let queue = DispatchQueue(label: "habitable.state-history")

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habitable", isDirectory: true)
            .appendingPathComponent("state-history", isDirectory: true)
    }

    private func folderDirectory(_ folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Records `data` for `folder` unless it matches the latest recording.
    /// Returns the new version, or nil when nothing changed.
    @discardableResult
    func record(folder: URL, data: Data, resourceCount: Int) -> LocalStateVersion? {
        let directory = folderDirectory(folder)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return queue.sync {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let existing = versionsLocked(directory)
            if let latest = existing.last, latest.id.hasSuffix(hash.prefix(16)) { return nil }
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let name = "\(stamp)-\(resourceCount)-\(hash.prefix(16)).json"
            let url = directory.appendingPathComponent(name)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let all = versionsLocked(directory)
            for old in all.dropLast(Self.keepCount) { try? fileManager.removeItem(at: old.url) }
            return all.last
        }
    }

    /// Recorded versions, oldest first.
    func versions(for folder: URL) -> [LocalStateVersion] {
        queue.sync { versionsLocked(folderDirectory(folder)) }
    }

    func load(_ version: LocalStateVersion) -> Data? { try? Data(contentsOf: version.url) }

    func clear(folder: URL) { queue.sync { try? FileManager.default.removeItem(at: folderDirectory(folder)) } }

    private func versionsLocked(_ directory: URL) -> [LocalStateVersion] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> LocalStateVersion? in
            guard name.hasSuffix(".json") else { return nil }
            let parts = name.dropLast(5).split(separator: "-")
            guard parts.count == 3, let stamp = Double(parts[0]), let count = Int(parts[1]) else { return nil }
            return LocalStateVersion(id: String(name.dropLast(5)), date: Date(timeIntervalSince1970: stamp / 1000),
                                     resourceCount: count, url: directory.appendingPathComponent(name))
        }
        .sorted { $0.date < $1.date }
    }
}
