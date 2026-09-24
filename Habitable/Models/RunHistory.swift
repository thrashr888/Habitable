import CryptoKit
import Darwin
import Foundation

struct RunRecord: Codable {
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

    func create(workspace: URL, terraformVersion: String, message: String?,
                selectedTerraformWorkspace: String? = nil, backendIdentity: String? = nil) throws -> RunRecord {
        try withLock(folder: workspaceDirectory(workspace)) {
            let records = try readRecords(workspace: workspace)
            let now = Date()
            let record = RunRecord(id: UUID(), number: (records.map(\.number).max() ?? 0) + 1,
                                   workspacePath: Self.workspacePath(workspace), createdAt: now,
                                   updatedAt: now, status: .pending, terraformVersion: terraformVersion,
                                   selectedTerraformWorkspace: selectedTerraformWorkspace,
                                   backendIdentity: backendIdentity, message: message)
            try write(record, workspace: workspace)
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
            try write(record, workspace: workspace)
        }
    }

    func recordURL(id: UUID, workspace: URL) -> URL {
        workspaceDirectory(workspace).appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func readRecords(workspace: URL) throws -> [RunRecord] {
        try FileManager.default.contentsOfDirectory(at: workspaceDirectory(workspace), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decode(file: $0, workspace: workspace) }
            .sorted { $0.number < $1.number }
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
