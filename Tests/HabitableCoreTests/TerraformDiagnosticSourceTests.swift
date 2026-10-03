import XCTest
@testable import HabitableCore

final class TerraformDiagnosticSourceTests: XCTestCase {
    func testResolvesExistingRootConfigurationByRelativeOrAbsolutePathAndChecksLineBounds() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("main.tf")
        try "resource \"terraform_data\" \"example\" {}\noutput \"name\" {}\n".write(to: source, atomically: true, encoding: .utf8)

        XCTAssertEqual(TerraformDiagnosticSource.currentWorkspaceFile(filename: "main.tf", workspaceDirectory: directory), "main.tf")
        XCTAssertEqual(TerraformDiagnosticSource.currentWorkspaceFile(filename: source.path, workspaceDirectory: directory), "main.tf")
        XCTAssertEqual(TerraformDiagnosticSource.boundedLine(2, in: "main.tf", workspaceDirectory: directory), 2)
        XCTAssertEqual(TerraformDiagnosticSource.boundedLine(3, in: "main.tf", workspaceDirectory: directory), 3)
        XCTAssertNil(TerraformDiagnosticSource.boundedLine(0, in: "main.tf", workspaceDirectory: directory))
    }

    func testResolvesLocalChildModuleByRelativePathAndRejectsDownloadedCaches() throws {
        let directory = try makeDirectory()
        let module = directory.appendingPathComponent("modules/network", isDirectory: true)
        let downloaded = directory.appendingPathComponent(".terraform/modules/downloaded", isDirectory: true)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        try "resource {}\noutput {}\n".write(to: module.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "resource {}".write(to: downloaded.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        XCTAssertEqual(TerraformDiagnosticSource.currentWorkspaceFile(filename: "modules/network/main.tf", workspaceDirectory: directory),
                       "modules/network/main.tf")
        XCTAssertEqual(TerraformDiagnosticSource.boundedLine(2, in: "modules/network/main.tf", workspaceDirectory: directory), 2)
        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: ".terraform/modules/downloaded/main.tf", workspaceDirectory: directory))
        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "modules/network/../../main.tf", workspaceDirectory: directory))
    }

    func testRejectsDeepAndSymlinkedChildSources() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory()
        try "resource {}".write(to: outside.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let linkedDir = directory.appendingPathComponent("modules/linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: outside)
        let tooDeep = "a/b/c/d/e/f/g/h/i/main.tf"

        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "modules/linked/main.tf", workspaceDirectory: directory))
        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: tooDeep, workspaceDirectory: directory))
    }

    func testRejectsURLTraversalAndNonConfigurationFilesButAllowsLocalChildSources() throws {
        let directory = try makeDirectory()
        let nested = directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "resource {}".write(to: nested.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "state".write(to: directory.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        try "resource {}".write(to: directory.appendingPathComponent("main.TF"), atomically: true, encoding: .utf8)

        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "https://example.test/main.tf", workspaceDirectory: directory))
        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "../outside.tf", workspaceDirectory: directory))
        XCTAssertEqual(TerraformDiagnosticSource.currentWorkspaceFile(filename: "child/main.tf", workspaceDirectory: directory), "child/main.tf")
        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "terraform.tfstate", workspaceDirectory: directory))
        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "main.TF", workspaceDirectory: directory))
    }

    func testBoundsCRLFLineNumbersAsTheEditorDoes() throws {
        let directory = try makeDirectory()
        try "first\r\nsecond\r\n".write(to: directory.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        XCTAssertEqual(TerraformDiagnosticSource.boundedLine(2, in: "main.tf", workspaceDirectory: directory), 2)
        XCTAssertEqual(TerraformDiagnosticSource.boundedLine(3, in: "main.tf", workspaceDirectory: directory), 3)
        XCTAssertEqual(TerraformDiagnosticSource.boundedLine(4, in: "main.tf", workspaceDirectory: directory), 3)
    }

    func testRejectsSymlinkEscapingWorkspace() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory()
        try "resource {}".write(to: outside.appendingPathComponent("outside.tf"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.tf"),
                                                  withDestinationURL: outside.appendingPathComponent("outside.tf"))

        XCTAssertNil(TerraformDiagnosticSource.currentWorkspaceFile(filename: "linked.tf", workspaceDirectory: directory))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
