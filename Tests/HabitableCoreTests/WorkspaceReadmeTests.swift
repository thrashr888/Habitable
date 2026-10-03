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
        XCTAssertTrue(WorkspaceReadme.canOpen(root.appendingPathComponent("docs/start.md"), relativeTo: root))
        XCTAssertFalse(WorkspaceReadme.canOpen(root.appendingPathComponent("../outside.txt"), relativeTo: root))
        XCTAssertFalse(WorkspaceReadme.canOpen(URL(string: "javascript:alert(1)")!, relativeTo: root))
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
    }
}
