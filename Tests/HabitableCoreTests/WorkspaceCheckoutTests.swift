import Foundation
import XCTest
@testable import HabitableCore

final class WorkspaceCheckoutTests: XCTestCase {
    private var attributes: [String: Any] {
        [
            "name": "rookery",
            "working-directory": "infra/prod",
            "vcs-repo": [
                "identifier": "thrashr888/rookery",
                "repository-http-url": "https://github.com/thrashr888/rookery",
                "branch": "",
                "display-identifier": "thrashr888/rookery"
            ] as [String: Any]
        ]
    }

    func testDecodeVCSRepository() throws {
        let repo = try XCTUnwrap(HCPVCSRepository.decode(attributes: attributes))
        XCTAssertEqual(repo.identifier, "thrashr888/rookery")
        XCTAssertEqual(repo.repositoryHTTPURL?.absoluteString, "https://github.com/thrashr888/rookery")
        XCTAssertNil(repo.branch)
        XCTAssertEqual(repo.workingDirectory, "infra/prod")
        XCTAssertEqual(repo.cloneURL?.host, "github.com")
        XCTAssertEqual(repo.displayName, "thrashr888/rookery")
    }

    func testDecodeNilWithoutVCS() {
        XCTAssertNil(HCPVCSRepository.decode(attributes: ["name": "x", "vcs-repo": NSNull()]))
        XCTAssertNil(HCPVCSRepository.decode(attributes: ["name": "x"]))
    }

    func testCloneURLRejectsNonHTTPSAndCredentials() {
        func repo(_ url: String) -> HCPVCSRepository {
            HCPVCSRepository(identifier: nil, repositoryHTTPURL: URL(string: url), branch: nil, workingDirectory: nil)
        }
        XCTAssertNil(repo("http://github.com/a/b").cloneURL)
        XCTAssertNil(repo("ssh://git@github.com/a/b").cloneURL)
        XCTAssertNil(repo("file:///tmp/x").cloneURL)
        XCTAssertNil(repo("https://user:pass@github.com/a/b").cloneURL)
        XCTAssertNotNil(repo("https://github.com/a/b").cloneURL)
        XCTAssertEqual(repo("https://gitlab.com/a/b").displayName, "gitlab.com/a/b")
    }

    @MainActor
    func testStoreRoundTripCanonicalPathsAndFiltering() throws {
        let suite = "WorkspaceCheckoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kept = root.appendingPathComponent("kept")
        let gone = root.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceCheckoutStore(defaults: defaults)
        store.record(path: kept, hostname: "app.terraform.io", organization: "o", workspaceName: "w", workspaceID: "ws-1")
        store.record(path: kept.appendingPathComponent("../kept"), hostname: "app.terraform.io", organization: "o", workspaceName: "w", workspaceID: "ws-1")
        store.record(path: gone, hostname: "app.terraform.io", organization: "o", workspaceName: "w", workspaceID: "ws-1")
        XCTAssertEqual(store.records.count, 2, "same canonical path is one record")
        XCTAssertEqual(store.record(forPath: kept)?.path, kept.resolvingSymlinksInPath().path)

        let reloaded = WorkspaceCheckoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.records, store.records)

        try FileManager.default.removeItem(at: gone)
        let found = reloaded.records(hostname: "APP.terraform.io", organization: "o", workspaceID: "ws-1")
        XCTAssertEqual(found.map(\.path), [kept.resolvingSymlinksInPath().path])
        XCTAssertTrue(reloaded.records(hostname: "app.terraform.io", organization: "o", workspaceID: "ws-2").isEmpty)

        reloaded.forget(path: kept)
        XCTAssertNil(reloaded.record(forPath: kept))
        XCTAssertEqual(WorkspaceCheckoutStore(defaults: defaults).records.count, 1)
    }

    func testSuggestedFolderName() {
        XCTAssertEqual(GitCheckout.suggestedFolderName(identifier: "thrashr888/rookery", repositoryURL: nil, workspaceName: "w"), "rookery")
        XCTAssertEqual(GitCheckout.suggestedFolderName(identifier: nil, repositoryURL: URL(string: "https://github.com/a/infra.git"), workspaceName: "w"), "infra")
        XCTAssertEqual(GitCheckout.suggestedFolderName(identifier: nil, repositoryURL: nil, workspaceName: "prod-app"), "prod-app")
        XCTAssertEqual(GitCheckout.suggestedFolderName(identifier: "a/..", repositoryURL: nil, workspaceName: "../x"), "x")
        XCTAssertEqual(GitCheckout.suggestedFolderName(identifier: nil, repositoryURL: nil, workspaceName: ""), "workspace")
    }

    func testRedactionAndWorkingDirectorySafety() {
        let text = "fatal: unable to access 'https://bob:hunter2@github.com/a/b/': token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let out = GitCheckout.redact(text)
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("bob"))
        XCTAssertFalse(out.contains("ghp_"))
        XCTAssertNil(GitCheckout.safeWorkingDirectory("../etc"))
        XCTAssertNil(GitCheckout.safeWorkingDirectory("a/../../b"))
        XCTAssertNil(GitCheckout.safeWorkingDirectory("/abs"))
        XCTAssertNil(GitCheckout.safeWorkingDirectory("  "))
        XCTAssertEqual(GitCheckout.safeWorkingDirectory("./infra//prod/"), "infra/prod")
    }

    func testCloneRejectsFileURLByDefault() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await GitCheckout.clone(repository: URL(fileURLWithPath: "/tmp/x"), branch: nil, workingDirectory: nil, destination: dest) { _ in }
            XCTFail("expected invalidRepository")
        } catch GitCheckoutError.invalidRepository {}
    }

    func testCloneLocalRepositoryHonorsWorkingDirectory() async throws {
        guard let git = GitCheckout.gitExecutable() else { throw XCTSkip("git is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("origin.git")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("infra/prod"), withIntermediateDirectories: true)
        try "resource \"null_resource\" \"a\" {}\n".write(to: work.appendingPathComponent("infra/prod/main.tf"), atomically: true, encoding: .utf8)

        @discardableResult func run(_ args: [String], in dir: URL) throws -> Int32 {
            let p = Process()
            p.executableURL = git
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(try run(["init", "--bare", "-b", "main", bare.path], in: root), 0)
        XCTAssertEqual(try run(["init", "-b", "main"], in: work), 0)
        XCTAssertEqual(try run(["add", "."], in: work), 0)
        XCTAssertEqual(try run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "init"], in: work), 0)
        XCTAssertEqual(try run(["push", bare.path, "main"], in: work), 0)

        let dest = root.appendingPathComponent("clone")
        let opened = try await GitCheckout.clone(repository: bare, branch: "main", workingDirectory: "infra/prod", destination: dest, allowFileURLs: true) { _ in }
        XCTAssertEqual(opened.standardizedFileURL.path, dest.appendingPathComponent("infra/prod").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.appendingPathComponent("main.tf").path))

        do {
            _ = try await GitCheckout.clone(repository: bare, branch: nil, workingDirectory: nil, destination: dest, allowFileURLs: true) { _ in }
            XCTFail("expected destinationExists")
        } catch GitCheckoutError.destinationExists {}

        let missingSub = root.appendingPathComponent("clone2")
        let rootOpened = try await GitCheckout.clone(repository: bare, branch: nil, workingDirectory: "nope", destination: missingSub, allowFileURLs: true) { _ in }
        XCTAssertEqual(rootOpened, missingSub)
        let escaped = root.appendingPathComponent("clone3")
        let escapedOpened = try await GitCheckout.clone(repository: bare, branch: nil, workingDirectory: "../work", destination: escaped, allowFileURLs: true) { _ in }
        XCTAssertEqual(escapedOpened, escaped)

        let badBranch = root.appendingPathComponent("clone4")
        do {
            _ = try await GitCheckout.clone(repository: bare, branch: "does-not-exist", workingDirectory: nil, destination: badBranch, allowFileURLs: true) { _ in }
            XCTFail("expected failure")
        } catch GitCheckoutError.failed {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: badBranch.path))
    }
}
