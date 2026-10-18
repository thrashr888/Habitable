import XCTest
@testable import HabitableCore

final class WorkspaceReadmeTests: XCTestCase {
    func testRepositoryReadmeWinsWhenTerraformIsInSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let terraform = root.appendingPathComponent("terraform")
        try FileManager.default.createDirectory(at: terraform, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".git")) // Worktree marker can be a file.
        try "# Repository\n\n```hcl\nterraform {}\n```".write(to: root.appendingPathComponent("ReadMe.MD"), atomically: true, encoding: .utf8)
        try "Subfolder".write(to: terraform.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let document = try XCTUnwrap(WorkspaceReadme.load(directory: terraform))
        XCTAssertEqual(document.file.lastPathComponent, "ReadMe.MD")
        XCTAssertTrue(document.isMarkdown)
        XCTAssertTrue(document.content.hasPrefix("# Repository"))
        XCTAssertEqual(WorkspaceReadme.linkDestination(document.file, relativeTo: root), .editor(document.file))
        XCTAssertNil(WorkspaceReadme.linkDestination(root.appendingPathComponent("../outside.txt"), relativeTo: root))
        XCTAssertNil(WorkspaceReadme.linkDestination(URL(string: "javascript:alert(1)")!, relativeTo: root))
    }

    func testLocalLinksAlwaysUseEditorIncludingExecutableAndEncodedTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["guide.md", "run.command", "upper.COMMAND", "extensionless", "link.webloc"] {
            let file = root.appendingPathComponent(name)
            try "Fixture content; never execute".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            XCTAssertEqual(WorkspaceReadme.linkDestination(file, relativeTo: root), .editor(file))
        }
        let command = root.appendingPathComponent("run.command")
        let encoded = try XCTUnwrap(URL(string: root.absoluteString + "/run%2ecommand"))
        XCTAssertEqual(WorkspaceReadme.linkDestination(encoded, relativeTo: root), .editor(command))
        let alias = root.appendingPathComponent("guide.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: command)
        XCTAssertEqual(WorkspaceReadme.linkDestination(alias, relativeTo: root), .editor(command))

        let app = root.appendingPathComponent("Payload.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        XCTAssertNil(WorkspaceReadme.linkDestination(app, relativeTo: root))
        XCTAssertNil(WorkspaceReadme.linkDestination(root, relativeTo: root))
        XCTAssertNil(WorkspaceReadme.linkDestination(root.appendingPathComponent("missing.md"), relativeTo: root))
        XCTAssertNil(WorkspaceReadme.linkDestination(URL(string: "file://untrusted.example/guide.md")!, relativeTo: root))
    }

    func testWebAndMailLinksKeepTheirExternalDestination() throws {
        let root = URL(fileURLWithPath: "/workspace")
        for value in ["https://example.invalid/docs", "http://example.invalid/docs", "mailto:help@example.invalid"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(WorkspaceReadme.linkDestination(url, relativeTo: root), .external(url))
        }
    }

    func testMissingPlaintextAndOversizedReadme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(try WorkspaceReadme.load(directory: root))
        let file = root.appendingPathComponent("README")
        try "Plain documentation".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(try XCTUnwrap(WorkspaceReadme.load(directory: root)).isMarkdown)
        try Data(repeating: 65, count: WorkspaceReadme.maximumBytes + 1).write(to: file)
        XCTAssertThrowsError(try WorkspaceReadme.load(directory: root))
    }

    func testReadmeSymlinkCannotReadOutsideRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let privateFile = root.appendingPathComponent("private.md")
        try "private".write(to: privateFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("README.md"), withDestinationURL: privateFile)
        XCTAssertNil(try WorkspaceReadme.load(directory: workspace))
        XCTAssertNil(WorkspaceReadme.linkDestination(workspace.appendingPathComponent("README.md"), relativeTo: workspace))
    }
}
