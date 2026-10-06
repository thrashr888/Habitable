import Foundation

/// Builds the gzip'd tar that HCP Terraform accepts as a configuration version upload.
struct ConfigurationArchive {
    static let maxBytes = 50 * 1024 * 1024

    enum ArchiveError: LocalizedError, Equatable {
        case tooLarge
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge: "The folder is larger than the 50 MB upload limit."
            case .failed(let detail): detail.isEmpty ? "Could not package the folder." : "Could not package the folder: \(detail)"
            }
        }
    }

    static func make(folder: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", "-", "-C", folder.path,
                             "--exclude", ".git", "--exclude", ".terraform", "--exclude", ".DS_Store",
                             "--exclude", "*.tfstate", "--exclude", "*.tfstate.backup",
                             "--exclude", "*.tfstate.*", "."]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Drain stderr concurrently so a chatty failure cannot fill the pipe and stall tar.
        let errBox = DataBox()
        let errThread = Thread { errBox.set(err.fileHandleForReading.readDataToEndOfFile()) }
        do { try process.run() } catch { throw ArchiveError.failed("tar could not start.") }
        errThread.start()
        var data = Data()
        let handle = out.fileHandleForReading
        var tooLarge = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > maxBytes {
                tooLarge = true
                process.terminate()
                break
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        if tooLarge { throw ArchiveError.tooLarge }
        guard process.terminationStatus == 0 else {
            let text = String(data: errBox.get(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ArchiveError.failed(String(text.prefix(300)))
        }
        guard !data.isEmpty else { throw ArchiveError.failed("The archive was empty.") }
        return data
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// An in-flight API-driven change: configuration uploaded, run started, waiting on plan or confirmation.
struct HCPProposal: Equatable, Sendable {
    let runID: String
    let workspaceID: String
    let message: String
    let createdAt: Date
    var status: String
    var planID: String?
    let folder: URL

    enum Step: Equatable, Sendable {
        case uploading
        case planning
        case needsConfirmation
        case applying
        case applied
        case errored(String)
        case discarded
    }

    var step: Step { Self.step(forStatus: status) }

    /// A plan-only or no-change run that finished without anything to apply.
    var isPlanOnlyComplete: Bool { status == "planned_and_finished" }

    static func step(forStatus status: String) -> Step {
        switch status {
        case "pending", "plan_queued", "planning", "fetching", "plan_queued_pending": .planning
        case "planned", "cost_estimating", "cost_estimated", "policy_checking", "policy_checked",
             "policy_override", "policy_soft_failed", "post_plan_running", "post_plan_completed": .needsConfirmation
        case "confirmed", "apply_queued", "applying": .applying
        case "applied", "planned_and_finished": .applied
        case "errored": .errored("The run failed. Open it in HCP Terraform for the log.")
        case "canceled", "force_canceled": .errored("The run was canceled.")
        case "discarded": .discarded
        default: .planning
        }
    }

    static func previewRequestBody(workspaceID: String, configurationVersionID: String,
                                   message: String, planOnly: Bool) -> [String: Any] {
        ["data": [
            "type": "runs",
            "attributes": ["message": message, "plan-only": planOnly],
            "relationships": [
                "workspace": ["data": ["type": "workspaces", "id": workspaceID]],
                "configuration-version": ["data": ["type": "configuration-versions", "id": configurationVersionID]]
            ]
        ] as [String: Any]]
    }
}
