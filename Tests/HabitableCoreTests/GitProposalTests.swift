import XCTest
@testable import HabitableCore

final class GitProposalTests: XCTestCase {
    func testBranchNameSlugs() {
        XCTAssertEqual(GitProposal.branchName(for: "Resize the  web fleet!"), "habitable/resize-the-web-fleet")
        XCTAssertEqual(GitProposal.branchName(for: "  --Fix: S3 bucket (prod)--  "), "habitable/fix-s3-bucket-prod")
        let long = GitProposal.branchName(for: String(repeating: "abcd efgh ", count: 20))
        XCTAssertTrue(long.hasPrefix("habitable/"))
        XCTAssertLessThanOrEqual(long.count, "habitable/".count + 40)
        XCTAssertFalse(long.hasSuffix("-"))
        let empty = GitProposal.branchName(for: "  !!! ")
        XCTAssertTrue(empty.hasPrefix("habitable/change-"), empty)
    }

    func testParseStatus() {
        let porcelain = " M a.tf\n?? new.tf\nD  gone.tf\nR  a -> b\nA  added.tf\n"
        let status = GitProposal.parseStatus(porcelain: porcelain, branch: "main", defaultBranch: "main",
                                             remote: "git@github.com:acme/infra.git")
        XCTAssertEqual(status.changedFiles, [
            .init(path: "a.tf", kind: .modified), .init(path: "new.tf", kind: .untracked),
            .init(path: "gone.tf", kind: .deleted), .init(path: "b", kind: .renamed),
            .init(path: "added.tf", kind: .added)
        ])
        XCTAssertFalse(status.isClean)
        XCTAssertEqual(status.remoteURL?.absoluteString, "https://github.com/acme/infra")
        XCTAssertEqual(status.githubRepository, "acme/infra")
        let clean = GitProposal.parseStatus(porcelain: "", branch: "main", defaultBranch: "", remote: "https://gitlab.com/a/b.git")
        XCTAssertTrue(clean.isClean)
        XCTAssertEqual(clean.defaultBranch, "main")
        XCTAssertNil(clean.githubRepository)
    }

    func testParsePullRequest() throws {
        let json = """
        {"number":42,"title":"Resize fleet","url":"https://github.com/acme/infra/pull/42","headRefName":"habitable/resize-fleet",
         "baseRefName":"main","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","additions":12,"deletions":3}
        """
        let pr = try GitProposal.parsePullRequest(json: Data(json.utf8))
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.headBranch, "habitable/resize-fleet")
        XCTAssertEqual(pr.baseBranch, "main")
        XCTAssertEqual(pr.mergeable, "MERGEABLE")
        XCTAssertNil(pr.reviewDecision)
        XCTAssertEqual(pr.additions, 12)
        XCTAssertThrowsError(try GitProposal.parsePullRequest(json: Data("{}".utf8)))
    }

    func testCommitAndPushToLocalBareRemote() throws {
        guard GitCheckout.gitExecutable() != nil else { throw XCTSkip("git unavailable") }
        for (key, value) in [("GIT_AUTHOR_NAME", "Habitable Tests"), ("GIT_AUTHOR_EMAIL", "habitable@example.invalid"),
                             ("GIT_COMMITTER_NAME", "Habitable Tests"), ("GIT_COMMITTER_EMAIL", "habitable@example.invalid")] {
            setenv(key, value, 1)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = root.appendingPathComponent("work"), bare = root.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "--bare", "-b", "main"], at: bare)
        try git(["init", "-b", "main"], at: work)
        try "terraform {}\n".write(to: work.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try git(["add", "."], at: work)
        try git(["commit", "-m", "initial"], at: work)
        try git(["remote", "add", "origin", bare.path], at: work)
        try git(["push", "-u", "origin", "main"], at: work)

        XCTAssertThrowsError(try GitProposal.commitAndPush(in: work, message: "Nothing")) {
            XCTAssertEqual($0 as? GitProposalError, .nothingToCommit)
        }
        try "terraform { required_version = \">= 1.5\" }\n".write(to: work.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "variable \"x\" {}\n".write(to: work.appendingPathComponent("vars.tf"), atomically: true, encoding: .utf8)
        let dirty = try GitProposal.status(in: work)
        XCTAssertEqual(dirty.branch, "main")
        XCTAssertEqual(dirty.changedFiles.count, 2)

        let branch = try GitProposal.commitAndPush(in: work, message: "Require Terraform 1.5")
        XCTAssertTrue(branch.hasPrefix("habitable/"))
        let heads = try gitOutput(["branch", "--list", branch], at: bare)
        XCTAssertTrue(heads.contains(branch), heads)
        let after = try GitProposal.status(in: work)
        XCTAssertTrue(after.isClean)
        XCTAssertEqual(after.branch, branch)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        _ = try gitOutput(arguments, at: directory)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = try XCTUnwrap(GitCheckout.gitExecutable())
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self)
    }
}

extension GitProposalTests {
    func testParsePullRequestReadsChecksAndRunID() throws {
        let json = """
        {"number": 2, "title": "Format", "url": "https://github.com/o/r/pull/2", "headRefName": "habitable/x", "baseRefName": "master",
         "state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "reviewDecision": "", "additions": 2, "deletions": 1,
         "statusCheckRollup": [
           {"__typename": "StatusContext", "context": "Terraform Cloud/org/ws", "state": "PENDING", "targetUrl": "https://app.terraform.io/app/org/ws/runs/run-abc123"},
           {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/o/r/actions/runs/1"},
           {"__typename": "StatusContext", "context": "sentinel/org/ws", "state": "FAILURE", "targetUrl": "http://insecure.example/x"}
         ]}
        """
        let pr = try GitProposal.parsePullRequest(json: Data(json.utf8))
        XCTAssertEqual(pr.checks.map(\.state), [.pending, .success, .failure])
        XCTAssertEqual(GitProposal.PullRequest.runID(in: pr.checks[0]), "run-abc123")
        XCTAssertNil(GitProposal.PullRequest.runID(in: pr.checks[1]))
        XCTAssertNil(pr.checks[2].url, "non-https check links are dropped")
    }
}
