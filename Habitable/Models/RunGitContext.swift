import Foundation
import Darwin

/// Stateful decision core for a live HEAD watcher. The caller owns polling and lifecycle;
/// this value records a baseline once and never treats the initial/restart HEAD as a change.
struct GitHeadMonitor: Sendable {
    enum Block: String, Equatable, Sendable {
        case dirty = "Skipped: working tree has uncommitted changes."
        case busy = "Skipped: another Terraform command is active."
        case notReady = "Skipped: initialize and resolve required inputs before planning."
        case unavailable = "Skipped: Git HEAD could not be read."
    }
    enum Decision: Equatable, Sendable {
        case baseline(String)
        case unchanged
        case plan(String)
        case skipped(String, Block)
    }

    private(set) var baseline: String?

    mutating func observe(head: String?, isDirty: Bool, isBusy: Bool, isReady: Bool) -> Decision {
        guard let head, !head.isEmpty else { return .skipped("", .unavailable) }
        guard let baseline else {
            self.baseline = head
            return .baseline(head)
        }
        guard head != baseline else { return .unchanged }
        // Advance even when blocked so this exact HEAD is not replayed on every poll.
        self.baseline = head
        if isDirty { return .skipped(head, .dirty) }
        if isBusy { return .skipped(head, .busy) }
        if !isReady { return .skipped(head, .notReady) }
        return .plan(head)
    }

    mutating func reset() { baseline = nil }
}

/// A bounded, best-effort repository snapshot. Git is invoked without a shell and with
/// prompts/network access disabled; missing or slow metadata never blocks Terraform runs.
struct RunGitContext: Equatable, Sendable {
    struct HeadState: Equatable, Sendable {
        let commit: String
        let isDirty: Bool
    }
    let branch: String?
    let commit: String
    var subject: String? = nil
    var dirty: Bool? = nil
    var remoteURL: String? = nil

    var shortCommit: String { String(commit.prefix(12)) }
    var isDetached: Bool { branch == nil && !commit.isEmpty }

    static func capture(directory: URL) -> Self? {
        let commit = runGit(["rev-parse", "HEAD"], at: directory, timeout: 0.8)?.first
        guard let commit = commit.flatMap({ isCommit($0) ? $0.lowercased() : nil })
                ?? readGitMetadata(directory: directory)?.commit else { return nil }
        let branchText = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], at: directory, timeout: 0.4)?.first
        let branch = branchText.flatMap { $0.isEmpty ? nil : $0 } ?? readGitMetadata(directory: directory)?.branch
        let subject = runGit(["show", "-s", "--format=%s", "HEAD"], at: directory, timeout: 0.5)?.first
            .flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        let status = runGit(["status", "--porcelain=v1", "--untracked-files=normal"], at: directory, timeout: 0.8)
        let dirty = status.map { !$0.isEmpty }
        let remote = runGit(["remote", "get-url", "origin"], at: directory, timeout: 0.4)?.first
            .flatMap(safeRemoteURL)
        return Self(branch: branch, commit: commit.lowercased(), subject: subject,
                    dirty: dirty, remoteURL: remote)
    }

    /// Lightweight watcher snapshot: no `git show`, remote lookup, or branch metadata.
    static func captureHeadState(directory: URL) -> HeadState? {
        guard let rawCommit = runGit(["rev-parse", "--verify", "HEAD"], at: directory, timeout: 0.6)?.first,
              isCommit(rawCommit),
              let status = runGit(["status", "--porcelain=v1", "--untracked-files=normal"], at: directory, timeout: 0.8) else {
            return nil
        }
        guard let verifiedCommit = runGit(["rev-parse", "--verify", "HEAD"], at: directory, timeout: 0.6)?.first,
              verifiedCommit.caseInsensitiveCompare(rawCommit) == .orderedSame else { return nil }
        return HeadState(commit: rawCommit.lowercased(), isDirty: !status.isEmpty)
    }

    private static func readGitMetadata(directory: URL) -> Self? {
        var root = directory.standardizedFileURL
        for _ in 0..<128 {
            let marker = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let git: URL
                if isDirectory.boolValue { git = marker }
                else if let pointer = read(marker), pointer.hasPrefix("gitdir: ") {
                    git = URL(fileURLWithPath: String(pointer.dropFirst(8)), relativeTo: root).standardizedFileURL
                } else { return nil }
                guard let head = read(git.appendingPathComponent("HEAD")) else { return nil }
                if isCommit(head) { return Self(branch: nil, commit: head.lowercased()) }
                guard head.hasPrefix("ref: refs/heads/") else { return nil }
                let reference = String(head.dropFirst(5))
                guard !reference.contains(".."), !reference.contains("\\") else { return nil }
                let common = read(git.appendingPathComponent("commondir"))
                    .map { URL(fileURLWithPath: $0, relativeTo: git).standardizedFileURL } ?? git
                let branch = String(reference.dropFirst("refs/heads/".count))
                if let ref = read(common.appendingPathComponent(reference)), isCommit(ref) {
                    return Self(branch: branch, commit: ref.lowercased())
                }
                if let packed = read(common.appendingPathComponent("packed-refs"), limit: 2 * 1024 * 1024) {
                    for line in packed.split(separator: "\n") {
                        let parts = line.split(separator: " ", maxSplits: 1)
                        if parts.count == 2, parts[1] == reference, isCommit(String(parts[0])) {
                            return Self(branch: branch, commit: String(parts[0]).lowercased())
                        }
                    }
                }
                return nil
            }
            guard root.path != "/", !root.path.isEmpty else { return nil }
            let parent = root.deletingLastPathComponent().standardizedFileURL
            guard parent.path != root.path else { return nil }
            root = parent
        }
        return nil
    }

    private static func read(_ url: URL, limit: Int = 8192) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCommit(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit }
    }

    private static func safeRemoteURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2048 else { return nil }
        // Convert conventional SSH remotes to browser-safe HTTPS links after removing
        // their SSH username. Accept only a hostname and a plain repository path.
        if !value.contains("://") {
            guard let colon = value.firstIndex(of: ":") else { return nil }
            let rawHost = String(value[..<colon]).split(separator: "@").last.map(String.init) ?? ""
            let path = String(value[value.index(after: colon)...])
            guard safeHost(rawHost), safeRepositoryPath(path) else { return nil }
            return "https://\(rawHost)\(normalizedRepositoryPath(path))"
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http", "ssh"].contains(scheme),
              let host = components.host, safeHost(host), safeRepositoryPath(components.path) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if scheme == "ssh" {
            guard components.port == nil else { return nil }
            components.scheme = "https"
        }
        components.path = normalizedRepositoryPath(components.path)
        return components.string
    }

    private static func safeHost(_ host: String) -> Bool {
        guard host.count <= 253, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        return host.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func safeRepositoryPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains(".."), !trimmed.contains("\\") else { return false }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/-._".contains($0)) }
    }

    private static func normalizedRepositoryPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix(".git") { normalized.removeLast(4) }
        return "/" + normalized
    }

    private static func runGit(_ arguments: [String], at directory: URL, timeout: TimeInterval) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "protocol.allow"
        environment["GIT_CONFIG_VALUE_0"] = "never"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let readFinished = DispatchSemaphore(value: 0)
        let captured = OutputCapture()
        DispatchQueue.global(qos: .utility).async {
            defer { readFinished.signal() }
            while true {
                do {
                    guard let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty else { break }
                    captured.append(chunk)
                } catch { break }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < terminateDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = readFinished.wait(timeout: .now() + 0.2)
            return nil
        }
        guard readFinished.wait(timeout: .now() + 0.2) == .success else { return nil }
        let data = captured.data
        guard data.count <= 8192, process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if storage.count < 8192 { storage.append(data.prefix(8192 - storage.count)) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
