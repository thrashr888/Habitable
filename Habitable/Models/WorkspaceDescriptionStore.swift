import CryptoKit
import Darwin
import Foundation

/// Stores one locally edited description per canonical workspace directory.
struct WorkspaceDescriptionStore: Sendable {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Habitable/WorkspaceDescriptions", isDirectory: true)

    private struct Record: Codable {
        var schemaVersion = 1
        var workspacePath: String
        var description: String
    }

    let directory: URL

    init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    func load(workspace: URL) throws -> String {
        let canonicalPath = RunHistoryStore.workspacePath(workspace)
        let file = recordURL(canonicalPath: canonicalPath)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }

        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard record.schemaVersion == 1, record.workspacePath == canonicalPath else {
                throw WorkspaceDescriptionError.invalidRecord(file)
            }
            return record.description
        } catch let error as WorkspaceDescriptionError {
            throw error
        } catch {
            throw WorkspaceDescriptionError.readFailed(file, error)
        }
    }

    func save(_ description: String, workspace: URL) throws {
        let canonicalPath = RunHistoryStore.workspacePath(workspace)
        let file = recordURL(canonicalPath: canonicalPath)
        let data: Data
        do {
            data = try JSONEncoder().encode(Record(workspacePath: canonicalPath, description: description))
        } catch {
            throw WorkspaceDescriptionError.writeFailed(file, error)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw WorkspaceDescriptionError.writeFailed(file, CocoaError(.fileWriteUnknown))
            }
            defer { try? FileManager.default.removeItem(at: staging) }
            let handle = try FileHandle(forWritingTo: staging)
            try handle.synchronize()
            try handle.close()
            guard rename(staging.path, file.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let descriptor = open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch let error as WorkspaceDescriptionError {
            throw error
        } catch {
            throw WorkspaceDescriptionError.writeFailed(file, error)
        }
    }

    private func recordURL(canonicalPath: String) -> URL {
        let key = SHA256.hash(data: Data(canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }
}

enum WorkspaceDescriptionError: LocalizedError, Sendable {
    case invalidRecord(URL)
    case readFailed(URL, Error)
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let file):
            return "Cannot read the saved workspace description at \(file.path). The file was preserved."
        case .readFailed(let file, let error):
            return "Cannot read the saved workspace description at \(file.path). The file was preserved. \(error.localizedDescription)"
        case .writeFailed(let file, let error):
            return "Cannot save the workspace description at \(file.path). \(error.localizedDescription)"
        }
    }
}
