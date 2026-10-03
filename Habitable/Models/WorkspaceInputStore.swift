import Foundation
import CryptoKit
import Security
import Darwin

enum WorkspaceInputStoreError: LocalizedError {
    case keychain(OSStatus)
    case missingSecret(String)
    case invalidStore

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Could not access the macOS Keychain (error \(status)). The remembered input could not be loaded or saved."
        case .missingSecret(let key): return "Remembered sensitive input ‘\(key)’ is unavailable in the macOS Keychain. Restore it before starting a run."
        case .invalidStore: return "Remembered workspace inputs could not be read safely."
        }
    }
}

protocol WorkspaceInputSecretStore {
    func read(id: String) throws -> String?
    func write(_ value: String, id: String) throws
    func delete(id: String) throws
}

struct KeychainWorkspaceInputSecretStore: WorkspaceInputSecretStore {
    func read(id: String) throws -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.thrashr888.Habitable.workspace-inputs",
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeAll()
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw WorkspaceInputStoreError.keychain(status)
        }
        return value
    }

    func write(_ value: String, id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.thrashr888.Habitable.workspace-inputs", kSecAttrAccount as String: id]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw WorkspaceInputStoreError.keychain(addStatus) }
        } else if status != errSecSuccess { throw WorkspaceInputStoreError.keychain(status) }
    }

    func delete(id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.thrashr888.Habitable.workspace-inputs", kSecAttrAccount as String: id]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceInputStoreError.keychain(status) }
    }
}

struct StoredWorkspaceInput: Codable, Equatable {
    enum Kind: String, Codable { case terraform, environment }
    var kind: Kind
    var key: String
    var value: String?
    var secretID: String?
    var description: String
    var sensitive: Bool
    var hcl: Bool
}

/// Per-canonical-workspace durable inputs. Secret values are resolved only into memory.
final class WorkspaceInputStore {
    private let root: URL
    private let secrets: WorkspaceInputSecretStore
    private let fileWriter: (Data, URL) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var pendingSecretCleanup = Set<String>()

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("Habitable/WorkspaceInputs", isDirectory: true),
         secrets: WorkspaceInputSecretStore = KeychainWorkspaceInputSecretStore(),
         fileWriter: ((Data, URL) throws -> Void)? = nil) {
        self.root = root
        self.secrets = secrets
        self.fileWriter = fileWriter ?? Self.atomicWrite
    }

    func load(workspace: URL) throws -> [(StoredWorkspaceInput, String)] {
        let records = try readRecords(workspace: workspace)
        return try records.map { record in
            if let id = record.secretID {
                guard let value = try secrets.read(id: id) else { throw WorkspaceInputStoreError.missingSecret(record.key) }
                try validate(value, for: record)
                return (record, value)
            }
            guard let value = record.value else { throw WorkspaceInputStoreError.invalidStore }
            try validate(value, for: record)
            return (record, value)
        }
    }

    func loadAllowingUnavailableSecrets(workspace: URL) throws -> [(StoredWorkspaceInput, String?)] {
        let records = try readRecords(workspace: workspace)
        return try records.map { record in
            if let id = record.secretID {
                guard let value = try secrets.read(id: id) else { return (record, nil) }
                try validate(value, for: record)
                return (record, value)
            }
            guard let value = record.value else { throw WorkspaceInputStoreError.invalidStore }
            try validate(value, for: record)
            return (record, value)
        }
    }

    @discardableResult
    func save(_ records: [StoredWorkspaceInput], workspace: URL) throws -> String? {
        let old = try readRecords(workspace: workspace)
        try validate(records, persisted: false)
        var prepared = records
        var created: [String] = []
        do {
            for index in prepared.indices {
                if prepared[index].sensitive {
                    if let value = prepared[index].value {
                        try validate(value, for: prepared[index])
                        let id = UUID().uuidString
                        try secrets.write(value, id: id)
                        created.append(id)
                        prepared[index].secretID = id
                    } else {
                        guard prepared[index].secretID != nil else { throw WorkspaceInputStoreError.invalidStore }
                    }
                    prepared[index].value = nil
                } else { prepared[index].secretID = nil }
            }
            try validate(prepared, persisted: true)
            try fileWriter(encoder.encode(prepared), url(for: workspace))
        } catch {
            for id in created { try? secrets.delete(id: id) }
            throw error
        }
        let retained = Set(prepared.compactMap(\.secretID))
        pendingSecretCleanup.formUnion(Set(old.compactMap(\.secretID)).subtracting(retained))
        var cleanupError: Error?
        for id in Array(pendingSecretCleanup) {
            do { try secrets.delete(id: id); pendingSecretCleanup.remove(id) }
            catch { cleanupError = error }
        }
        return cleanupError.map { "Remembered inputs were saved, but an old Keychain item could not be removed: \($0.localizedDescription)" }
    }

    private func readRecords(workspace: URL) throws -> [StoredWorkspaceInput] {
        let file = url(for: workspace)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let records = try decoder.decode([StoredWorkspaceInput].self, from: Data(contentsOf: file))
            try validate(records, persisted: true)
            return records
        }
        catch { throw WorkspaceInputStoreError.invalidStore }
    }

    private func validate(_ records: [StoredWorkspaceInput], persisted: Bool) throws {
        var keys = Set<String>()
        for record in records {
            let keyIsValid: Bool
            switch record.kind {
            case .terraform:
                keyIsValid = record.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            case .environment:
                keyIsValid = !record.hcl && !record.key.isEmpty && !record.key.contains("=") && !record.key.contains("\0")
            }
            guard keyIsValid, keys.insert("\(record.kind.rawValue):\(record.key)").inserted else {
                throw WorkspaceInputStoreError.invalidStore
            }
            if record.sensitive {
                if persisted {
                    guard record.value == nil, record.secretID?.isEmpty == false else { throw WorkspaceInputStoreError.invalidStore }
                } else {
                    guard record.value != nil || record.secretID?.isEmpty == false else { throw WorkspaceInputStoreError.invalidStore }
                }
            } else {
                guard record.value != nil, record.secretID == nil else { throw WorkspaceInputStoreError.invalidStore }
            }
            if let value = record.value { try validate(value, for: record) }
        }
    }

    private func validate(_ value: String, for record: StoredWorkspaceInput) throws {
        switch record.kind {
        case .environment:
            guard !value.contains("\0") else { throw WorkspaceInputStoreError.invalidStore }
        case .terraform where record.hcl:
            guard let data = value.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw WorkspaceInputStoreError.invalidStore
            }
        case .terraform:
            break
        }
    }

    private func url(for workspace: URL) -> URL {
        let canonical = RunHistoryStore.workspacePath(workspace)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let root = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let temporary = root.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var committed = false
        defer {
            if fd >= 0 { close(fd) }
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard close(fd) == 0 else { fd = -1; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fd = -1
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        committed = true
        let directoryFD = open(root.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); _ = close(directoryFD) }
    }
}
