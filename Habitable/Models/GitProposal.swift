import Foundation

// MARK: - Errors

enum GitProposalError: LocalizedError, Equatable {
    case gitUnavailable
    case ghUnavailable
    case ghNotAuthenticated
    case notARepository
    case nothingToCommit
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitUnavailable: "Git isn't installed. Install the Xcode command line tools, then try again."
        case .ghUnavailable: "GitHub CLI (gh) is not installed or not signed in. Install it and run `gh auth login`."
        case .ghNotAuthenticated: "GitHub CLI (gh) is not signed in. Run `gh auth login`, then try again."
        case .notARepository: "This folder isn't a git repository."
        case .nothingToCommit: "There are no changes to commit."
        case .commandFailed(let detail): detail.isEmpty ? "The command failed." : detail
        }
    }
}

// MARK: - Branch, commit, push and pull request

/// Habitable manages branches, commits and pull requests for VCS-driven workspaces.
/// Every helper runs a `Process` synchronously; call from `Task.detached`.
enum GitProposal {
    struct ChangedFile: Equatable, Sendable {
        enum Kind: String, Sendable { case added, modified, deleted, untracked, renamed }
        let path: String
        let kind: Kind
    }

    struct Status: Equatable, Sendable {
        let branch: String
        let defaultBranch: String
        let changedFiles: [ChangedFile]
        let isClean: Bool
        let remoteURL: URL?
        let githubRepository: String?
    }

    struct PullRequest: Equatable, Sendable {
        let number: Int
        let title: String
        let url: URL
        let headBranch: String
        let baseBranch: String
        let state: String
        let isDraft: Bool
        let mergeable: String?
        let reviewDecision: String?
        let additions: Int?
        let deletions: Int?
        /// GitHub's status checks for the head commit (CI, HCP Terraform runs, policy).
        var checks: [Check] = []
        /// Files the pull request changes, with their line counts.
        var files: [ChangedPath] = []
        /// Reviews and comments, newest last, for the conversation.
        var reviews: [Review] = []
        var comments: [Comment] = []
        var approvedBy: Review? { reviews.last { $0.state == "APPROVED" } }

        /// The HCP Terraform run a check links to, when the check is one of HCP's.
        static func runID(in check: Check) -> String? {
            guard let url = check.url, url.pathComponents.count >= 2,
                  let index = url.pathComponents.lastIndex(of: "runs"), index + 1 < url.pathComponents.count,
                  url.pathComponents[index + 1].hasPrefix("run-") else { return nil }
            return url.pathComponents[index + 1]
        }
    }

    struct Review: Equatable, Sendable {
        let author: String
        let state: String      // APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED
        let body: String
        let submittedAt: Date?
    }

    struct Comment: Equatable, Sendable {
        let author: String
        let body: String
        let createdAt: Date?
    }

    struct ChangedPath: Equatable, Sendable {
        let path: String
        let additions: Int
        let deletions: Int
    }

    struct Check: Equatable, Sendable {
        enum State: String, Sendable { case pending, success, failure, neutral }
        let name: String
        let state: State
        let url: URL?
    }

    static let branchPrefix = "habitable/"
    private static let commandTimeout: TimeInterval = 300
    private static let jsonFields = "number,title,url,headRefName,baseRefName,state,isDraft,mergeable,reviewDecision,additions,deletions,statusCheckRollup,files,reviews,comments"

    // MARK: Status

    static func status(in folder: URL) throws -> Status {
        let git = try requireGit()
        let inside = try run(git, ["rev-parse", "--is-inside-work-tree"], in: folder)
        guard inside.status == 0, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitProposalError.notARepository
        }
        var branch = try run(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder).stdout.trimmed
        if branch.isEmpty {   // detached HEAD
            branch = try run(git, ["rev-parse", "--short", "HEAD"], in: folder).stdout.trimmed
        }
        var defaultBranch = try run(git, ["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], in: folder).stdout.trimmed
        if defaultBranch.hasPrefix("origin/") { defaultBranch.removeFirst("origin/".count) }
        if defaultBranch.isEmpty { defaultBranch = "main" }
        let remote = try run(git, ["remote", "get-url", "origin"], in: folder)
        let porcelain = try run(git, ["status", "--porcelain=v1", "-uall"], in: folder)
        guard porcelain.status == 0 else { throw failure(porcelain) }
        return parseStatus(porcelain: porcelain.stdout, branch: branch, defaultBranch: defaultBranch,
                           remote: remote.status == 0 ? remote.stdout.trimmed : nil)
    }

    /// Pure: builds a Status from `git status --porcelain=v1` output. Renames report the new path.
    static func parseStatus(porcelain: String, branch: String, defaultBranch: String, remote: String?) -> Status {
        var files: [ChangedFile] = []
        for line in porcelain.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.count > 3 else { continue }
            let code = text.prefix(2)
            var path = String(text.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            let kind: ChangedFile.Kind
            if code == "??" { kind = .untracked }
            else if code.contains("R") { kind = .renamed }
            else if code.contains("D") { kind = .deleted }
            else if code.contains("A") { kind = .added }
            else { kind = .modified }
            files.append(ChangedFile(path: path, kind: kind))
        }
        let url = remote.flatMap(httpsURL(fromRemote:))
        return Status(branch: branch, defaultBranch: defaultBranch.isEmpty ? "main" : defaultBranch,
                      changedFiles: files, isClean: files.isEmpty, remoteURL: url,
                      githubRepository: url.flatMap(githubRepository(for:)))
    }

    /// git@github.com:o/r.git, ssh://git@host/o/r.git and https URLs become https://host/o/r (no credentials, no .git).
    static func httpsURL(fromRemote remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var host: String?
        var path: String?
        if let range = text.range(of: "://") {
            let scheme = text[..<range.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme) else { return nil }
            var rest = String(text[range.upperBound...])
            if let query = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<query]) }
            if let at = rest.firstIndex(of: "@"), rest[..<at].firstIndex(of: "/") == nil { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var hostPart = String(rest[..<slash])
            if scheme == "ssh" || scheme == "git", let colon = hostPart.firstIndex(of: ":") { hostPart = String(hostPart[..<colon]) }
            host = hostPart
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {   // scp-like
            var hostPart = String(text[..<colon])
            if let at = hostPart.firstIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
            host = hostPart
            path = String(text[text.index(after: colon)...])
        }
        guard let host, !host.isEmpty, var path else { return nil }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty else { return nil }
        text = "https://\(host)/\(path)"
        return URL(string: text)
    }

    static func githubRepository(for url: URL) -> String? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: Branch names

    /// "habitable/" + slug of the message; falls back to a timestamped name when the slug is empty.
    static func branchName(for message: String) -> String {
        var slug = ""
        var lastDash = true
        for scalar in message.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                slug.append("-")
                lastDash = true
            }
        }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmm"
            slug = "change-" + formatter.string(from: Date())
        }
        return branchPrefix + slug
    }

    // MARK: Commit and push

    /// Creates the branch from the current HEAD unless already on a habitable/ branch, stages everything,
    /// commits with `message`, and pushes with `-u origin`. Returns the branch name.
    static func commitAndPush(in folder: URL, message: String) throws -> String {
        let git = try requireGit()
        let current = try run(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder).stdout.trimmed
        let porcelain = try run(git, ["status", "--porcelain=v1"], in: folder)
        guard porcelain.status == 0 else { throw failure(porcelain) }
        guard !porcelain.stdout.trimmed.isEmpty else { throw GitProposalError.nothingToCommit }

        var branch = current
        if !current.hasPrefix(branchPrefix) {
            branch = branchName(for: message)
            let exists = try run(git, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: folder).status == 0
            if exists {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HHmmss"
                branch += "-" + formatter.string(from: Date())
            }
            try check(run(git, ["checkout", "-b", branch], in: folder))
        }
        try check(run(git, ["add", "-A"], in: folder))
        let commitMessage = message.trimmed.isEmpty ? "Update Terraform configuration" : message.trimmed
        try check(run(git, ["commit", "-m", commitMessage], in: folder))
        try check(run(git, ["push", "-u", "origin", branch], in: folder))
        return branch
    }

    // MARK: GitHub CLI

    static func ghExecutable() -> URL? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            candidates.append("\(directory)/gh")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func openPullRequest(in folder: URL, title: String, body: String, base: String) throws -> PullRequest {
        let gh = try requireGH()
        let git = try requireGit()
        let branch = try run(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder).stdout.trimmed
        guard !branch.isEmpty else { throw GitProposalError.commandFailed("There's no branch to open a pull request from.") }
        try checkGH(run(gh, ["pr", "create", "--title", title, "--body", body, "--base", base, "--head", branch], in: folder))
        let view = try run(gh, ["pr", "view", branch, "--json", jsonFields], in: folder)
        try checkGH(view)
        return try parsePullRequest(json: Data(view.stdout.utf8))
    }

    static func pullRequest(in folder: URL, forBranch branch: String) throws -> PullRequest? {
        let gh = try requireGH()
        let result = try run(gh, ["pr", "view", branch, "--json", jsonFields], in: folder)
        if result.status != 0 {
            if result.stderr.lowercased().contains("no pull requests found") { return nil }
            try checkGH(result)
        }
        return try parsePullRequest(json: Data(result.stdout.utf8))
    }

    static func openPullRequests(in folder: URL) throws -> [PullRequest] {
        let gh = try requireGH()
        let result = try run(gh, ["pr", "list", "--json", jsonFields, "--state", "open", "--limit", "20"], in: folder)
        try checkGH(result)
        guard let array = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] else {
            throw GitProposalError.commandFailed("GitHub returned an unexpected response.")
        }
        return array.compactMap { try? pullRequest(from: $0) }
    }

    static func merge(pullRequest number: Int, in folder: URL) throws {
        let gh = try requireGH()
        try checkGH(run(gh, ["pr", "merge", String(number), "--squash", "--delete-branch"], in: folder))
    }

    /// After a merge, the checkout goes back to the base branch at its new tip
    /// and the merged `habitable/` branch is dropped locally.
    static func returnToBase(in folder: URL, base: String) throws {
        let git = try requireGit()
        let current = try run(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder).stdout.trimmed
        try check(run(git, ["checkout", base], in: folder))
        try check(run(git, ["pull", "--ff-only"], in: folder))
        if current.hasPrefix(branchPrefix), current != base {
            _ = try? run(git, ["branch", "-D", current], in: folder)
        }
    }

    static func closePullRequest(_ number: Int, in folder: URL) throws {
        let gh = try requireGH()
        try checkGH(run(gh, ["pr", "close", String(number), "--delete-branch"], in: folder))
    }

    /// Pure: parses `gh pr view --json ...` output.
    static func parsePullRequest(json: Data) throws -> PullRequest {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw GitProposalError.commandFailed("GitHub returned an unexpected response.")
        }
        return try pullRequest(from: object)
    }

    private static func pullRequest(from object: [String: Any]) throws -> PullRequest {
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        guard let number = (object["number"] as? NSNumber)?.intValue,
              let title = object["title"] as? String,
              let url = text("url").flatMap({ URL(string: $0) }) else {
            throw GitProposalError.commandFailed("GitHub returned an unexpected response.")
        }
        return PullRequest(
            number: number, title: title, url: url,
            headBranch: text("headRefName") ?? "", baseBranch: text("baseRefName") ?? "",
            state: text("state") ?? "OPEN",
            isDraft: (object["isDraft"] as? Bool) ?? false,
            mergeable: text("mergeable"), reviewDecision: text("reviewDecision"),
            additions: (object["additions"] as? NSNumber)?.intValue,
            deletions: (object["deletions"] as? NSNumber)?.intValue,
            checks: parseChecks(object["statusCheckRollup"]),
            files: parseFiles(object["files"]),
            reviews: parseReviews(object["reviews"]),
            comments: parseComments(object["comments"])
        )
    }

    /// A formatter per call: ISO8601DateFormatter is not Sendable, and these parse a handful of dates.
    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text) ?? { formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: text) }()
    }

    static func parseReviews(_ value: Any?) -> [Review] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let state = row["state"] as? String else { return nil }
            let author = ((row["author"] as? [String: Any])?["login"] as? String) ?? "someone"
            let body = String(((row["body"] as? String) ?? "").prefix(600))
            let when = (row["submittedAt"] as? String).flatMap(isoDate)
            return Review(author: author, state: state, body: body, submittedAt: when)
        }
    }

    static func parseComments(_ value: Any?) -> [Comment] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let body = row["body"] as? String, !body.isEmpty else { return nil }
            let author = ((row["author"] as? [String: Any])?["login"] as? String) ?? "someone"
            let when = (row["createdAt"] as? String).flatMap(isoDate)
            return Comment(author: author, body: String(body.prefix(600)), createdAt: when)
        }
    }

    /// Pure: `files` rows carry `path`, `additions`, `deletions`.
    static func parseFiles(_ value: Any?) -> [ChangedPath] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"] as? String, !path.isEmpty else { return nil }
            return ChangedPath(path: path, additions: (row["additions"] as? NSNumber)?.intValue ?? 0,
                               deletions: (row["deletions"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Pure: `statusCheckRollup` holds StatusContext rows (`context`, `state`,
    /// `targetUrl`) and CheckRun rows (`name`, `status`, `conclusion`, `detailsUrl`).
    static func parseChecks(_ value: Any?) -> [Check] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let name = (row["context"] as? String) ?? (row["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let raw = ((row["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                       ?? (row["state"] as? String) ?? (row["status"] as? String) ?? "").uppercased()
            let state: Check.State
            switch raw {
            case "SUCCESS": state = .success
            case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": state = .failure
            case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": state = .pending
            default: state = .neutral
            }
            let url = ((row["targetUrl"] as? String) ?? (row["detailsUrl"] as? String)).flatMap { URL(string: $0) }
            return Check(name: name, state: state, url: url?.scheme == "https" ? url : nil)
        }
    }

    // MARK: Process plumbing

    private struct Output { let status: Int32; let stdout: String; let stderr: String }

    private static func requireGit() throws -> URL {
        guard let git = GitCheckout.gitExecutable() else { throw GitProposalError.gitUnavailable }
        return git
    }

    private static func requireGH() throws -> URL {
        guard let gh = ghExecutable() else { throw GitProposalError.ghUnavailable }
        return gh
    }

    private static func failure(_ output: Output) -> GitProposalError {
        let detail = output.stderr.trimmed.isEmpty ? output.stdout : output.stderr
        return .commandFailed(GitCheckout.redact(detail))
    }

    private static func check(_ output: Output) throws {
        guard output.status == 0 else { throw failure(output) }
    }

    private static func checkGH(_ output: Output) throws {
        guard output.status != 0 else { return }
        let lower = (output.stderr + output.stdout).lowercased()
        if lower.contains("not logged") || lower.contains("gh auth login") || lower.contains("authentication") && lower.contains("token") {
            throw GitProposalError.ghNotAuthenticated
        }
        throw failure(output)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private static func run(_ executable: URL, _ arguments: [String], in folder: URL) throws -> Output {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["LC_ALL"] = "C"
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let outBox = Collector(), errBox = Collector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { outBox.append(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errBox.append(chunk) }
        }
        do { try task.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw executable.lastPathComponent == "gh" ? GitProposalError.ghUnavailable : GitProposalError.gitUnavailable
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + commandTimeout)
        timer.setEventHandler { if task.isRunning { task.terminate() } }
        timer.resume()
        task.waitUntilExit()
        timer.cancel()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.readToEnd() { outBox.append(rest) }
        if let rest = try? err.fileHandleForReading.readToEnd() { errBox.append(rest) }
        return Output(status: task.terminationStatus, stdout: outBox.text, stderr: errBox.text)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
