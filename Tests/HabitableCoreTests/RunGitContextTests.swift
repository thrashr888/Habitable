import XCTest
@testable import HabitableCore

final class RunGitContextTests: XCTestCase {
    func testHeadMonitorBaselinesAndDeduplicatesChanges() {
        var monitor = GitHeadMonitor()
        XCTAssertEqual(monitor.observe(head: "a", isDirty: false, isBusy: false, isReady: true), .baseline("a"))
        XCTAssertEqual(monitor.observe(head: "a", isDirty: false, isBusy: false, isReady: true), .unchanged)
        XCTAssertEqual(monitor.observe(head: "b", isDirty: false, isBusy: false, isReady: true), .plan("b"))
        XCTAssertEqual(monitor.observe(head: "b", isDirty: false, isBusy: false, isReady: true), .unchanged)
        monitor.reset()
        XCTAssertEqual(monitor.observe(head: "b", isDirty: false, isBusy: false, isReady: true), .baseline("b"))
    }

    func testHeadMonitorReportsBlockedChangesWithoutReplayingThem() {
        var monitor = GitHeadMonitor()
        _ = monitor.observe(head: "a", isDirty: false, isBusy: false, isReady: true)
        XCTAssertEqual(monitor.observe(head: "b", isDirty: true, isBusy: false, isReady: true), .skipped("b", .dirty))
        XCTAssertEqual(monitor.observe(head: "b", isDirty: false, isBusy: false, isReady: true), .unchanged)
        XCTAssertEqual(monitor.observe(head: "c", isDirty: false, isBusy: true, isReady: true), .skipped("c", .busy))
        XCTAssertEqual(monitor.observe(head: "d", isDirty: false, isBusy: false, isReady: false), .skipped("d", .notReady))
        XCTAssertEqual(monitor.observe(head: nil, isDirty: false, isBusy: false, isReady: true), .skipped("", .unavailable))
    }

    func testNonRepositoryTerminatesAtFilesystemRoot() throws {
        XCTAssertNil(RunGitContext.capture(directory: URL(fileURLWithPath: "/")))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(RunGitContext.capture(directory: directory))
    }

    func testNestedWorkingDirectoryAndPackedRefsSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        let nested = root.appendingPathComponent("terraform")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let commit = String(repeating: "a", count: 40)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "# packed\n\(commit) refs/heads/main\n".write(to: git.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(RunGitContext.capture(directory: nested))
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.commit, commit)
        try String(repeating: "b", count: 40).write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(snapshot.commit, commit, "Captured context must not follow later checkout changes")
        XCTAssertNil(RunGitContext.capture(directory: nested)?.branch)
    }

    func testWorktreeCommonDirectoryAndMalformedHead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree")
        let metadata = root.appendingPathComponent("common/worktrees/demo")
        let common = root.appendingPathComponent("common")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: common.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try "gitdir: ../common/worktrees/demo".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..".write(to: metadata.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/topic".write(to: metadata.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let commit = String(repeating: "c", count: 40)
        try commit.write(to: common.appendingPathComponent("refs/heads/topic"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RunGitContext.capture(directory: worktree), RunGitContext(branch: "topic", commit: commit))
        try "ref: refs/heads/../../secret".write(to: metadata.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertNil(RunGitContext.capture(directory: worktree))
    }

    func testLiveSnapshotIncludesTruthfulProvenanceAndStripsRemoteCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-b", "main"], at: root)
        try git(["config", "user.name", "Habitable Tests"], at: root)
        try git(["config", "user.email", "habitable@example.invalid"], at: root)
        try "terraform {}\n".write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try git(["add", "main.tf"], at: root)
        try git(["commit", "-m", "initial fixture"], at: root)
        try git(["remote", "add", "origin", "https://user:secret@github.com/example/repo.git?token=secret"], at: root)

        let clean = try XCTUnwrap(RunGitContext.capture(directory: root))
        XCTAssertEqual(clean.branch, "main")
        XCTAssertEqual(clean.subject, "initial fixture")
        XCTAssertEqual(clean.dirty, false)
        XCTAssertEqual(clean.remoteURL, "https://github.com/example/repo")
        XCTAssertFalse(clean.remoteURL?.contains("secret") == true)
        XCTAssertEqual(RunGitContext.captureHeadState(directory: root), .init(commit: clean.commit, isDirty: false))

        try git(["remote", "set-url", "origin", "git@github.com:example/repo.git"], at: root)
        XCTAssertEqual(RunGitContext.capture(directory: root)?.remoteURL, "https://github.com/example/repo")

        try "resource \"x\" {}\n".write(to: root.appendingPathComponent("new.tf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RunGitContext.capture(directory: root)?.dirty, true)
        XCTAssertEqual(RunGitContext.captureHeadState(directory: root), .init(commit: clean.commit, isDirty: true))
        try git(["checkout", "--detach"], at: root)
        XCTAssertEqual(RunGitContext.capture(directory: root)?.isDetached, true)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
