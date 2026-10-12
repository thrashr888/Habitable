import CryptoKit
import Foundation
import SwiftyJSON

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
    /// Sensitive values are removed before anything is written: the recording
    /// keeps addresses, types and plain attributes, never secrets.
    /// Returns the new version, or nil when nothing changed.
    @discardableResult
    func record(folder: URL, data rawData: Data, resourceCount: Int) -> LocalStateVersion? {
        let data = Self.redacted(rawData)
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

    /// `terraform show -json` carries real values beside a `sensitive_values`
    /// map; every value that map marks is replaced, and sensitive outputs too.
    static func redacted(_ data: Data) -> Data {
        guard var json = try? JSON(data: data) else { return data }
        func scrub(module: JSON) -> JSON {
            var module = module
            var resources = module["resources"].arrayValue
            for index in resources.indices {
                let marks = resources[index]["sensitive_values"]
                if marks.exists() {
                    resources[index]["values"] = scrubValues(resources[index]["values"], marks: marks)
                    resources[index]["sensitive_values"] = marks
                }
            }
            if !resources.isEmpty { module["resources"] = JSON(resources.map { $0.object }) }
            var children = module["child_modules"].arrayValue
            for index in children.indices { children[index] = scrub(module: children[index]) }
            if !children.isEmpty { module["child_modules"] = JSON(children.map { $0.object }) }
            return module
        }
        func scrubValues(_ values: JSON, marks: JSON) -> JSON {
            if marks.type == .bool { return marks.boolValue ? JSON("(sensitive value)") : values }
            var result = values
            if marks.type == .dictionary {
                for (key, mark) in marks.dictionaryValue where values[key].exists() {
                    result[key] = scrubValues(values[key], marks: mark)
                }
            } else if marks.type == .array {
                var items = values.arrayValue
                for (index, mark) in marks.arrayValue.enumerated() where items.indices.contains(index) {
                    items[index] = scrubValues(items[index], marks: mark)
                }
                result = JSON(items.map { $0.object })
            }
            return result
        }
        if json["values"]["root_module"].exists() {
            json["values"]["root_module"] = scrub(module: json["values"]["root_module"])
        }
        if let outputs = json["values"]["outputs"].dictionary {
            for (name, output) in outputs where output["sensitive"].boolValue {
                json["values"]["outputs"][name]["value"] = JSON("(sensitive value)")
            }
        }
        return (try? json.rawData()) ?? data
    }

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
