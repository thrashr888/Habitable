import XCTest
@testable import HabitableCore

final class RunGitContextTests: XCTestCase {
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
}
