import Combine
import Foundation

// MARK: - VCS connection

/// A workspace's VCS connection as HCP Terraform reports it (`vcs-repo` attributes).
struct HCPVCSRepository: Equatable, Sendable, Codable {
    let identifier: String?
    let repositoryHTTPURL: URL?
    let branch: String?
    let workingDirectory: String?

    /// Decodes from the workspace row's attributes dictionary; nil when there is no vcs-repo.
    static func decode(attributes: [String: Any]) -> HCPVCSRepository? {
        guard let repo = attributes["vcs-repo"] as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? {
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
            return string
        }
        let identifier = text(repo["identifier"])
        let url = text(repo["repository-http-url"]).flatMap { URL(string: $0) }
        guard identifier != nil || url != nil else { return nil }
        return HCPVCSRepository(
            identifier: identifier,
            repositoryHTTPURL: url,
            branch: text(repo["branch"]),
            workingDirectory: text(attributes["working-directory"])
        )
    }

    /// https only, no embedded credentials; anything else is rejected.
    var cloneURL: URL? {
        guard let url = repositoryHTTPURL, GitCheckout.isCloneable(url, allowFileURLs: false) else { return nil }
        return url
    }

    var displayName: String {
        if let identifier, !identifier.isEmpty { return identifier }
        if let url = repositoryHTTPURL, let host = url.host {
            let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            return path.isEmpty ? host : "\(host)/\(path)"
        }
        return "repository"
    }
}

// MARK: - Remembered checkouts

/// Remembers which local folders were checked out from which cloud workspaces.
/// Stored in UserDefaults as JSON; paths are canonical; never stores credentials.
@MainActor
final class WorkspaceCheckoutStore: ObservableObject {
    struct Record: Codable, Equatable, Sendable {
        let path: String
        let hostname: String
        let organization: String
        let workspaceName: String
        let workspaceID: String
        let checkedOutAt: Date
    }

    static let defaultsKey = "workspaceCheckouts"
    /// Where checkouts go unless Settings says otherwise: ~/Documents/Habitable,
    /// the way GitHub Desktop keeps ~/Documents/GitHub. Created on first use.
    static let folderDefaultsKey = "checkout.folder"
    static var checkoutFolder: URL {
        if let path = UserDefaults.standard.string(forKey: folderDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Habitable", isDirectory: true)
    }
    static func ensureCheckoutFolder() -> URL {
        let folder = checkoutFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Published private(set) var records: [Record]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = Self.load(defaults: defaults)
    }

    private static func load(defaults: UserDefaults) -> [Record] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return decoded
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func record(path: URL, hostname: String, organization: String, workspaceName: String, workspaceID: String) {
        let canonical = Self.canonicalPath(path)
        var updated = records.filter { $0.path != canonical }
        updated.append(Record(path: canonical, hostname: hostname, organization: organization,
                              workspaceName: workspaceName, workspaceID: workspaceID, checkedOutAt: Date()))
        records = updated
        save()
    }

    func record(forPath url: URL) -> Record? {
        let canonical = Self.canonicalPath(url)
        return records.first { $0.path == canonical }
    }

    /// Folders for this workspace that still exist on disk, newest first.
    func records(hostname: String, organization: String, workspaceID: String) -> [Record] {
        records
            .filter {
                $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame
                    && $0.organization == organization
                    && $0.workspaceID == workspaceID
                    && FileManager.default.fileExists(atPath: $0.path)
            }
            .sorted { $0.checkedOutAt > $1.checkedOutAt }
    }

    /// Re-reads records written by another window of the app.
    func reload() {
        let latest = Self.load(defaults: defaults)
        if latest != records { records = latest }
    }

    func forget(path: URL) {
        let canonical = Self.canonicalPath(path)
        let updated = records.filter { $0.path != canonical }
        guard updated.count != records.count else { return }
        records = updated
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - git clone

enum GitCheckoutError: LocalizedError {
    case gitUnavailable
    case destinationExists
    case invalidRepository
    case failed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .gitUnavailable: "Git isn't installed. Install the Xcode command line tools, then try again."
        case .destinationExists: "A folder with that name already exists. Choose a different name or location."
        case .invalidRepository: "This workspace's repository can't be cloned over https."
        case .failed(let detail): detail.isEmpty ? "Git couldn't clone the repository." : "Git couldn't clone the repository. \(detail)"
        case .timedOut: "Cloning took longer than 10 minutes and was stopped. Try again, or clone from Terminal."
        case .cancelled: "Cloning was cancelled."
        }
    }
}

enum GitCheckout {
    static let timeout: TimeInterval = 600
    static let outputLimit = 64 * 1024
    private static let gitPaths = ["/usr/bin/git", "/opt/homebrew/bin/git"]

    static func gitExecutable() -> URL? {
        gitPaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func isCloneable(_ url: URL, allowFileURLs: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return allowFileURLs && url.isFileURL }
        guard scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    /// Pure helper: the default destination folder name for a workspace ("rookery" from identifier/URL).
    static func suggestedFolderName(identifier: String?, repositoryURL: URL?, workspaceName: String) -> String {
        var candidates: [String] = []
        if let identifier { candidates.append(identifier) }
        if let repositoryURL { candidates.append(repositoryURL.path) }
        candidates.append(workspaceName)
        for candidate in candidates {
            var name = candidate.split(separator: "/").last.map(String.init) ?? candidate
            if name.hasSuffix(".git") { name.removeLast(4) }
            name = sanitizedFolderName(name)
            if !name.isEmpty { return name }
        }
        return "workspace"
    }

    private static func sanitizedFolderName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars { scalars.append(allowed.contains(scalar) ? scalar : "-") }
        var name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        return name
    }

    /// A safe relative subfolder, or nil when empty or when it could escape the clone.
    static func safeWorkingDirectory(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.contains("\\") || path.contains("\0") { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// Clones `repository` into `destination` (must not exist; parent must exist).
    /// Never prompts for credentials: private repositories must already work with the user's git credential helper.
    /// Returns the folder to open: `destination` joined with `workingDirectory` when that subfolder exists,
    /// otherwise the clone root.
    static func clone(repository: URL, branch: String?, workingDirectory: String?, destination: URL,
                      allowFileURLs: Bool = false,
                      progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard isCloneable(repository, allowFileURLs: allowFileURLs) else { throw GitCheckoutError.invalidRepository }
        guard let git = gitExecutable() else { throw GitCheckoutError.gitUnavailable }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { throw GitCheckoutError.destinationExists }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitCheckoutError.failed("The parent folder doesn't exist.")
        }

        var arguments = ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"]
        if allowFileURLs { arguments += ["-c", "protocol.file.allow=always"] }
        arguments += ["clone", "--progress"]
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            guard !branch.hasPrefix("-"), !branch.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
                throw GitCheckoutError.invalidRepository
            }
            arguments += ["--branch", branch]
        }
        arguments += ["--", repository.absoluteString, destination.path]

        let runner = GitProcessRunner(executable: git, arguments: arguments, progress: progress)
        do {
            try await runner.run()
        } catch {
            if (error as? GitCheckoutError).map({ if case .failed = $0 { return false } else { return true } }) == true {
                try? fm.removeItem(at: destination)   // we created it; leave nothing half-cloned
            }
            throw error
        }

        if let sub = safeWorkingDirectory(workingDirectory) {
            let candidate = destination.appendingPathComponent(sub, isDirectory: true)
            var isDir: ObjCBool = false
            let root = destination.resolvingSymlinksInPath().path
            let resolved = candidate.resolvingSymlinksInPath().path
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue,
               resolved == root || resolved.hasPrefix(root + "/") {
                return candidate
            }
        }
        return destination
    }

    /// Removes credentials and token-shaped strings, and bounds the length, before text reaches the UI.
    static func redact(_ text: String, limit: Int = 600) -> String {
        var result = text
        let patterns = [
            #"(?i)\b([a-z][a-z0-9+.\-]*://)[^/\s@]+@"#,                  // scheme://user:pass@
            #"\bgh[pousr]_[A-Za-z0-9]{16,}"#,                            // GitHub tokens
            #"\bgithub_pat_[A-Za-z0-9_]{16,}"#,
            #"\bglpat-[A-Za-z0-9_\-]{10,}"#,                             // GitLab
            #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}"#,
            #"\b[A-Za-z0-9_\-]{40,}\b"#                                  // any long opaque string
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = index == 0 ? "$1" : "[redacted]"
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > limit { result = String(result.prefix(limit)) + "…" }
        return result
    }
}

/// Runs git off the main actor with bounded output, a timeout and cancellation.
private final class GitProcessRunner: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let progress: @Sendable (String) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var captured = Data()
    private var pending = ""
    private var timedOut = false
    private var cancelled = false

    init(executable: URL, arguments: [String], progress: @escaping @Sendable (String) -> Void) {
        self.executable = executable
        self.arguments = arguments
        self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(with: Result { try execute() })
                }
            }
        } onCancel: {
            self.stop(cancel: true)
        }
    }

    private func stop(cancel: Bool) {
        lock.lock()
        if cancel { cancelled = true } else { timedOut = true }
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    private func execute() throws {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        environment["LC_ALL"] = "C"
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardError = pipe

        lock.lock()
        if cancelled { lock.unlock(); throw GitCheckoutError.cancelled }
        process = task
        lock.unlock()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.consume(data) }
        }
        do { try task.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw GitCheckoutError.gitUnavailable
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + GitCheckout.timeout)
        timer.setEventHandler { [weak self] in self?.stop(cancel: false) }
        timer.resume()
        task.waitUntilExit()
        timer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { consume(rest) }
        flushPending()

        lock.lock()
        let wasTimedOut = timedOut, wasCancelled = cancelled
        let output = String(decoding: captured, as: UTF8.self)
        lock.unlock()
        if wasCancelled { throw GitCheckoutError.cancelled }
        if wasTimedOut { throw GitCheckoutError.timedOut }
        guard task.terminationStatus == 0 else {
            throw GitCheckoutError.failed(Self.summary(of: output))
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        if captured.count < GitCheckout.outputLimit {
            captured.append(data.prefix(GitCheckout.outputLimit - captured.count))
        }
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(pending[..<index]))
            pending.removeSubrange(...index)
        }
        if pending.count > 4096 { pending = "" }
        lock.unlock()
        emit(lines)
    }

    private func flushPending() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        emit([rest])
    }

    private func emit(_ lines: [String]) {
        for line in lines {
            let clean = GitCheckout.redact(line, limit: 200)
            if !clean.isEmpty { progress(clean) }
        }
    }

    /// The last meaningful lines (git puts the reason at the end), redacted and bounded.
    private static func summary(of output: String) -> String {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Cloning into") && !$0.contains("Receiving objects") && !$0.contains("Resolving deltas") && !$0.contains("Counting objects") && !$0.contains("Compressing objects") && !$0.contains("Enumerating objects") }
        return GitCheckout.redact(lines.suffix(3).joined(separator: " "))
    }
}
