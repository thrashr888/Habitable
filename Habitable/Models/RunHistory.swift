import CryptoKit
import Darwin
import Foundation

struct RunRecord: Codable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var number: Int
    var workspacePath: String
    var createdAt: Date
    var updatedAt: Date
    var status: RunStatus
    var terraformVersion: String
    var selectedTerraformWorkspace: String?
    var backendIdentity: String?
    var message: String?
    var planOutput: String?
    var applyOutput: String?
    var errorMessage: String?
    var added: Int?
    var changed: Int?
    var destroyed: Int?
}

struct RunHistoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One atomic record per run avoids stale windows overwriting each other's history.
/// A cross-process lock serializes number allocation and record replacement.
struct RunHistoryStore {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Habitable/RunHistory", isDirectory: true)
    let directory: URL

    private struct Index: Codable {
        var nextNumber: Int
        var entries: [Entry]
    }

    private struct DirtyMarker: Codable {
        var nextNumber: Int
    }

    private struct Entry: Codable {
        var id: UUID
        var number: Int
        var createdAt: Date
        var status: RunStatus
        var byteCount: Int64
    }

    struct Page: Sendable {
        let records: [RunRecord]
        let totalCount: Int
        let offset: Int
    }

    private static let pageLimit = 100

    init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    static func workspacePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func workspaceDirectory(_ workspace: URL) -> URL {
        let hash = SHA256.hash(data: Data(Self.workspacePath(workspace).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash, isDirectory: true)
    }

    func load(workspace: URL) throws -> [RunRecord] {
        let folder = workspaceDirectory(workspace)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try withLock(folder: folder) { try readRecords(workspace: workspace) }
    }

    /// Loads only one ordered page of record payloads. Index migration is performed by the
    /// caller, so UI callers should invoke this from a background queue.
    func loadPage(workspace: URL, offset: Int, limit: Int) throws -> Page {
        let folder = workspaceDirectory(workspace)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return Page(records: [], totalCount: 0, offset: 0)
        }
        return try withLock(folder: folder) {
            let index = try readOrBuildIndex(workspace: workspace)
            let sorted = index.entries.sorted { $0.number > $1.number }
            let boundedLimit = max(1, min(limit, Self.pageLimit))
            let lastPageOffset = sorted.isEmpty ? 0 : ((sorted.count - 1) / boundedLimit) * boundedLimit
            let start = min(max(offset, 0), lastPageOffset)
            let end = min(start + boundedLimit, sorted.count)
            let records = try sorted[start..<end].map { entry in
                let record = try decode(file: recordURL(id: entry.id, workspace: workspace), workspace: workspace)
                guard record.number == entry.number else { throw RunHistoryError(message: "Run history index does not match its record.") }
                return record
            }
            return Page(records: records, totalCount: index.entries.count, offset: start)
        }
    }

    func readPersistedRecord(id: UUID, workspace: URL) throws -> RunRecord {
        try withLock(folder: workspaceDirectory(workspace)) {
            try decode(file: recordURL(id: id, workspace: workspace), workspace: workspace)
        }
    }

    /// Returns terminal persisted runs old enough for a user-confirmed retention action.
    func retentionCandidates(workspace: URL, before date: Date, protecting ids: Set<UUID>) throws -> [UUID] {
        let folder = workspaceDirectory(workspace)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try withLock(folder: folder) {
            try readOrBuildIndex(workspace: workspace).entries.compactMap { entry in
                guard entry.createdAt < date, !ids.contains(entry.id), Self.isDeletable(entry.status) else { return nil }
                return entry.id
            }
        }
    }

    /// Deletion is limited to terminal records and requires an explicit caller action.
    func delete(workspace: URL, id: UUID, protecting ids: Set<UUID>) throws {
        guard !ids.contains(id) else {
            throw RunHistoryError(message: "An active run cannot be deleted.")
        }
        try withLock(folder: workspaceDirectory(workspace)) {
            var index = try readOrBuildIndex(workspace: workspace)
            guard index.entries.contains(where: { $0.id == id }) else { return }
            let record = try decode(file: recordURL(id: id, workspace: workspace), workspace: workspace)
            guard Self.isDeletable(record.status) else {
                throw RunHistoryError(message: "Only completed saved runs can be deleted.")
            }
            try markDirty(nextNumber: index.nextNumber, workspace: workspace)
            try FileManager.default.removeItem(at: recordURL(id: id, workspace: workspace))
            try synchronizeDirectory(workspaceDirectory(workspace))
            index.entries.removeAll { $0.id == id }
            try writeIndex(index, workspace: workspace)
            try clearDirtyMarker(workspace: workspace)
        }
    }

    func delete(workspace: URL, ids: [UUID], protecting protectedIDs: Set<UUID>) throws {
        for id in ids { try delete(workspace: workspace, id: id, protecting: protectedIDs) }
    }

    /// Encodes only the persisted record and applies output redaction again for legacy files.
    func exportData(id: UUID, workspace: URL) throws -> Data {
        var record = try readPersistedRecord(id: id, workspace: workspace)
        record.planOutput = Self.redactSensitiveOutputs(record.planOutput)
        record.applyOutput = Self.redactSensitiveOutputs(record.applyOutput)
        record.errorMessage = Self.redactSensitiveOutputs(record.errorMessage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    func export(id: UUID, workspace: URL, to destination: URL) throws {
        let data = try exportData(id: id, workspace: workspace)
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".habitable-export-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw RunHistoryError(message: "Could not write the exported run.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(folder)
    }

    func create(workspace: URL, terraformVersion: String, message: String?,
                selectedTerraformWorkspace: String? = nil, backendIdentity: String? = nil) throws -> RunRecord {
        try withLock(folder: workspaceDirectory(workspace)) {
            var index = try readOrBuildIndex(workspace: workspace)
            let now = Date()
            let record = RunRecord(id: UUID(), number: index.nextNumber,
                                   workspacePath: Self.workspacePath(workspace), createdAt: now,
                                   updatedAt: now, status: .pending, terraformVersion: terraformVersion,
                                   selectedTerraformWorkspace: selectedTerraformWorkspace,
                                   backendIdentity: backendIdentity, message: message)
            try markDirty(nextNumber: index.nextNumber, workspace: workspace)
            try write(record, workspace: workspace)
            index.nextNumber = record.number + 1
            index.entries.append(try makeEntry(record, workspace: workspace))
            try writeIndex(index, workspace: workspace)
            try clearDirtyMarker(workspace: workspace)
            return record
        }
    }

    func save(_ record: RunRecord, workspace: URL) throws {
        try withLock(folder: workspaceDirectory(workspace)) {
            let existing = try decode(file: recordURL(id: record.id, workspace: workspace), workspace: workspace)
            guard existing.number == record.number, existing.createdAt == record.createdAt,
                  existing.updatedAt <= record.updatedAt else {
                throw RunHistoryError(message: "Run history changed in another session. Reopen the workspace before continuing.")
            }
            var index = try readOrBuildIndex(workspace: workspace)
            try markDirty(nextNumber: index.nextNumber, workspace: workspace)
            try write(record, workspace: workspace)
            if let position = index.entries.firstIndex(where: { $0.id == record.id }) {
                index.entries[position] = try makeEntry(record, workspace: workspace)
            } else {
                index.entries.append(try makeEntry(record, workspace: workspace))
                index.nextNumber = max(index.nextNumber, record.number + 1)
            }
            try writeIndex(index, workspace: workspace)
            try clearDirtyMarker(workspace: workspace)
        }
    }

    func recordURL(id: UUID, workspace: URL) -> URL {
        workspaceDirectory(workspace).appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func readRecords(workspace: URL) throws -> [RunRecord] {
        try FileManager.default.contentsOfDirectory(at: workspaceDirectory(workspace), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { try decode(file: $0, workspace: workspace) }
            .sorted { $0.number < $1.number }
    }

    private func readOrBuildIndex(workspace: URL) throws -> Index {
        let url = indexURL(workspace: workspace)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
                guard index.nextNumber > 0, index.entries.allSatisfy({ $0.number > 0 }),
                      Set(index.entries.map(\.id)).count == index.entries.count,
                      Set(index.entries.map(\.number)).count == index.entries.count,
                      index.nextNumber > (index.entries.map(\.number).max() ?? 0) else {
                    throw RunHistoryError(message: "Run history index is invalid.")
                }
                let markerURL = dirtyMarkerURL(workspace: workspace)
                if FileManager.default.fileExists(atPath: markerURL.path) {
                    let marker = try JSONDecoder().decode(DirtyMarker.self, from: Data(contentsOf: markerURL))
                    try rebuildIndex(workspace: workspace, preservingNextNumber: marker.nextNumber)
                    return try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
                }
                try validateIndexedFiles(index, workspace: workspace)
                return index
            } catch {
                throw RunHistoryError(message: "Cannot read run history index at \(url.path). Files have been preserved. \(error.localizedDescription)")
            }
        }
        let records = try readRecords(workspace: workspace)
        let markerURL = dirtyMarkerURL(workspace: workspace)
        let preservedNumber = (try? JSONDecoder().decode(DirtyMarker.self, from: Data(contentsOf: markerURL)))?.nextNumber ?? 1
        let index = Index(nextNumber: max(preservedNumber, (records.map(\.number).max() ?? 0) + 1),
                          entries: try records.map { try makeEntry($0, workspace: workspace) })
        try writeIndex(index, workspace: workspace)
        if FileManager.default.fileExists(atPath: markerURL.path) { try clearDirtyMarker(workspace: workspace) }
        return index
    }

    private func indexURL(workspace: URL) -> URL {
        workspaceDirectory(workspace).appendingPathComponent("index.json")
    }

    private func writeIndex(_ index: Index, workspace: URL) throws {
        let target = indexURL(workspace: workspace)
        let data = try JSONEncoder().encode(index)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".index-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RunHistoryError(message: "Could not update the run history index.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    private func dirtyMarkerURL(workspace: URL) -> URL {
        workspaceDirectory(workspace).appendingPathComponent(".dirty")
    }

    private func markDirty(nextNumber: Int, workspace: URL) throws {
        let url = dirtyMarkerURL(workspace: workspace)
        let data = try JSONEncoder().encode(DirtyMarker(nextNumber: nextNumber))
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RunHistoryError(message: "Could not prepare a run history update.")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func clearDirtyMarker(workspace: URL) throws {
        try FileManager.default.removeItem(at: dirtyMarkerURL(workspace: workspace))
        try synchronizeDirectory(workspaceDirectory(workspace))
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func rebuildIndex(workspace: URL, preservingNextNumber: Int) throws {
        let records = try readRecords(workspace: workspace)
        let index = Index(nextNumber: max(preservingNextNumber, (records.map(\.number).max() ?? 0) + 1),
                          entries: try records.map { try makeEntry($0, workspace: workspace) })
        try writeIndex(index, workspace: workspace)
        try clearDirtyMarker(workspace: workspace)
    }

    private func validateIndexedFiles(_ index: Index, workspace: URL) throws {
        for entry in index.entries {
            let file = recordURL(id: entry.id, workspace: workspace)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  (attributes[.size] as? NSNumber)?.int64Value == entry.byteCount else {
                throw RunHistoryError(message: "Run history changed outside Habitable. Reopen the workspace to recover history before starting another run.")
            }
        }
    }

    private func makeEntry(_ record: RunRecord, workspace: URL) throws -> Entry {
        let file = recordURL(id: record.id, workspace: workspace)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
            throw RunHistoryError(message: "Could not verify the saved run record.")
        }
        return Entry(id: record.id, number: record.number, createdAt: record.createdAt, status: record.status, byteCount: byteCount)
    }

    private static func isDeletable(_ status: RunStatus) -> Bool {
        [.applied, .discarded, .errored, .canceled, .expired].contains(status)
    }

    private func decode(file: URL, workspace: URL) throws -> RunRecord {
        do {
            let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: file))
            guard record.schemaVersion == 1, record.number > 0,
                  record.workspacePath == Self.workspacePath(workspace),
                  file.deletingPathExtension().lastPathComponent == record.id.uuidString else {
                throw RunHistoryError(message: "Unsupported or mismatched run record.")
            }
            return record
        } catch {
            throw RunHistoryError(message: "Cannot read run history at \(file.path). Files have been preserved. \(error.localizedDescription)")
        }
    }

    private func write(_ record: RunRecord, workspace: URL) throws {
        guard record.schemaVersion == 1, record.workspacePath == Self.workspacePath(workspace) else {
            throw RunHistoryError(message: "Refusing to save a run under a different workspace.")
        }
        var safeRecord = record
        safeRecord.planOutput = Self.redactSensitiveOutputs(record.planOutput)
        safeRecord.applyOutput = Self.redactSensitiveOutputs(record.applyOutput)
        safeRecord.errorMessage = Self.redactSensitiveOutputs(record.errorMessage)
        let data = try JSONEncoder().encode(safeRecord)
        let target = recordURL(id: record.id, workspace: workspace)
        // Stage with private permissions before the atomic replacement becomes visible.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RunHistoryError(message: "Could not write run history at \(target.path).")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(staging.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    private func withLock<T>(folder: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Terraform marks output values as sensitive in JSON, even though their values are plaintext.
    static func redactSensitiveOutputs(_ text: String?) -> String? {
        text.map { text in
            text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard let data = line.data(using: .utf8),
                      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      var outputs = json["outputs"] as? [String: [String: Any]] else { return String(line) }
                for (key, var output) in outputs where output["sensitive"] as? Bool == true {
                    output["value"] = "(sensitive)"
                    outputs[key] = output
                }
                json["outputs"] = outputs
                guard let encoded = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                      let sanitized = String(data: encoded, encoding: .utf8) else { return String(line) }
                return sanitized
            }.joined(separator: "\n")
        }
    }
}
