import Foundation
import XCTest
import Darwin
@testable import HabitableCore

@MainActor
final class ConfigurationModelTests: XCTestCase {
    func testSourceLineRangesUseUTF16OffsetsAcrossUnicodeAndEmptyFinalLine() {
        let source = "emoji = \"🧪🙂\"\nname = \"café\"\n"
        let nsSource = source as NSString

        XCTAssertEqual(ConfigurationModel.sourceRange(forLine: 1, in: source), nsSource.range(of: "emoji = \"🧪🙂\""))
        XCTAssertEqual(ConfigurationModel.sourceRange(forLine: 2, in: source), nsSource.range(of: "name = \"café\""))
        XCTAssertEqual(ConfigurationModel.sourceRange(forLine: 3, in: source), NSRange(location: nsSource.length, length: 0))
        XCTAssertNil(ConfigurationModel.sourceRange(forLine: 0, in: source))
        XCTAssertNil(ConfigurationModel.sourceRange(forLine: 4, in: source))
    }

    func testResourceDeclarationResolutionIsLimitedToKnownRootDeclarations() {
        var metadata = TerraformConfigurationMetadata()
        metadata.resources = [
            TerraformResourceDeclaration(address: "aws_instance.web", sourceFile: "main.tf", sourceLine: 12),
            TerraformResourceDeclaration(address: "data.aws_ami.base", sourceFile: "data.tf", sourceLine: 4),
            TerraformResourceDeclaration(address: "aws_instance.unknown", sourceFile: "main.tf", sourceLine: nil)
        ]

        XCTAssertEqual(TerraformConfigurationInspector.declaration(for: "aws_instance.web[0]", in: metadata)?.sourceLocation,
                       "main.tf:12")
        XCTAssertEqual(TerraformConfigurationInspector.declaration(for: "data.aws_ami.base", in: metadata)?.sourceLocation,
                       "data.tf:4")
        XCTAssertNil(TerraformConfigurationInspector.declaration(for: "module.child.aws_instance.web", in: metadata))
        XCTAssertNil(TerraformConfigurationInspector.declaration(for: "aws_instance.unknown", in: metadata))
        XCTAssertNil(TerraformConfigurationInspector.declaration(for: "aws_instance.missing", in: metadata))
    }

    func testExternalEditPreventsSavingDraftOverChangedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("main.tf")
        try "resource \"terraform_data\" \"old\" {}\n".write(to: file, atomically: true, encoding: .utf8)

        let workspace = Workspace(restoreLastDirectory: false)
        workspace.workingDirectory = root
        let model = ConfigurationModel()
        model.attach(to: workspace)
        model.draft = "resource \"terraform_data\" \"draft\" {}\n"
        try "resource \"terraform_data\" \"external\" {}\n".write(to: file, atomically: true, encoding: .utf8)

        model.save()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "resource \"terraform_data\" \"external\" {}\n")
        XCTAssertTrue(model.hasConflict)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testWorkspaceSwitchPreservesUnsavedDraftUntilExplicitDiscard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for folder in [first, second] {
            try "terraform {}\n".write(to: folder.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        }

        let workspace = Workspace(restoreLastDirectory: false)
        workspace.workingDirectory = first
        let model = ConfigurationModel()
        model.attach(to: workspace)
        model.draft = "terraform { # unsaved\n}\n"

        workspace.workingDirectory = second
        model.attach(to: workspace)

        XCTAssertTrue(model.isWorkspaceSwitchPending)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.selectedFile?.url.deletingLastPathComponent().resolvingSymlinksInPath(), first.resolvingSymlinksInPath())
        XCTAssertFalse(model.canSaveInCurrentWorkspace)

        model.discardAndSwitchWorkspace()

        XCTAssertFalse(model.isWorkspaceSwitchPending)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.selectedFile?.url.deletingLastPathComponent().resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
    }

    func testChildModuleDiscoveryKeepsUnsavedRootDraftAndDistinguishesDuplicateNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("modules/network", isDirectory: true)
        let cache = root.appendingPathComponent(".terraform/modules/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "terraform {}\n".write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "resource {}\n".write(to: child.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "resource {}\n".write(to: cache.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let workspace = Workspace(restoreLastDirectory: false)
        workspace.workingDirectory = root
        let model = ConfigurationModel()
        model.attach(to: workspace)
        model.draft = "terraform { # unsaved\n}\n"
        model.refreshFiles()
        for _ in 0..<100 where !model.files.contains(where: { $0.relativePath == "modules/network/main.tf" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.draft, "terraform { # unsaved\n}\n")
        XCTAssertTrue(model.files.contains(where: { $0.displayPath == "main.tf" }))
        XCTAssertTrue(model.files.contains(where: { $0.displayPath == "modules/network/main.tf" }))
        XCTAssertFalse(model.files.contains(where: { $0.relativePath.contains(".terraform") }))
        XCTAssertEqual(model.file(matching: "main.tf")?.relativePath, "main.tf", "A Terraform root-relative diagnostic path resolves to the root file.")
        XCTAssertEqual(model.file(matching: "modules/network/main.tf")?.relativePath, "modules/network/main.tf")
    }

    func testQualifiedChildModuleDeclarationResolvesBeforeBackgroundDiscoveryFinishes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("modules/network", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "terraform {}\n".write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "resource {}\n".write(to: child.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let workspace = Workspace(restoreLastDirectory: false)
        workspace.workingDirectory = root
        let model = ConfigurationModel()
        model.attach(to: workspace)
        XCTAssertFalse(model.files.contains(where: { $0.relativePath == "modules/network/main.tf" }))

        let declaration = model.file(matching: "modules/network/main.tf")
        XCTAssertEqual(declaration?.relativePath, "modules/network/main.tf")
        XCTAssertTrue(model.files.contains(where: { $0.relativePath == "modules/network/main.tf" }))
    }

    func testOversizedConfigurationIsExcludedFromTheBrowsableFileList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 32, count: 1_048_577).write(to: root.appendingPathComponent("large.tf"))
        let workspace = Workspace(restoreLastDirectory: false)
        workspace.workingDirectory = root
        let model = ConfigurationModel()
        model.attach(to: workspace)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.selectedFile)
    }

    func testOfficialTerraformFormattingReturnsCompleteOutput() throws {
        guard let path = ProcessInfo.processInfo.environment["HABITABLE_TEST_TERRAFORM"] else {
            throw XCTSkip("Set HABITABLE_TEST_TERRAFORM to exercise the installed formatter.")
        }
        let source = "terraform { required_version=\">= 1.0\" }\n"
        let result = try TerraformFormatOperation(executable: URL(fileURLWithPath: path), source: source).run()
        XCTAssertEqual(result.0, 0)
        XCTAssertTrue(result.1.contains("required_version ="))
        XCTAssertTrue(result.1.hasSuffix("\n"))
        XCTAssertFalse(result.2)
        XCTAssertFalse(result.3)
        XCTAssertFalse(result.4)
    }

    func testFormatOperationKillsChildThatIgnoresInputAndTermination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("slow-terraform")
        let childPIDFile = root.appendingPathComponent("child.pid")
        try "#!/bin/sh\nsleep 10 </dev/null &\necho $! > \(childPIDFile.path)\ntrap '' TERM\nwhile :; do :; done\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer {
            if let pid = try? String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let value = Int32(pid) { _ = kill(value, SIGKILL) }
        }

        let operation = TerraformFormatOperation(executable: executable,
            source: String(repeating: "resource \"terraform_data\" \"x\" {}\n", count: 100_000),
            timeout: 0.15, terminationGrace: 0.1)
        let start = Date()
        let result = try operation.run()

        XCTAssertTrue(result.2)
        // Foundation may also terminate inherited children; either pipe outcome
        // must return promptly without a SIGPIPE in the caller.
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testFormatAndSaveWritesOnlyFormatterStdoutWhenCliWarnsOnStderr() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("main.tf")
        try "terraform { required_version=\">= 1.0\" }\n".write(to: file, atomically: true, encoding: .utf8)
        let script = try makeTerraformScript(in: root, body: #"""
printf 'terraform {\n  required_version = \">= 1.0\"\n}\n'
printf 'Warning: harmless formatter notice\n' >&2
"""#)

        let workspace = Workspace(restoreLastDirectory: false)
        workspace.runner = Runner(executableURL: script)
        workspace.workingDirectory = root
        let model = ConfigurationModel()
        model.attach(to: workspace)
        model.formatAndSave()
        try await waitForFormattingToFinish(model)

        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(saved, "terraform {\n  required_version = \">= 1.0\"\n}\n")
        XCTAssertFalse(saved.contains("Warning:"))
        XCTAssertTrue(model.message?.contains("harmless formatter notice") == true)
    }

    func testAutoValidationDebouncesAndRunsOnlyWhileVisibleIncludingExternalSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("main.tf")
        try "terraform {}\n".write(to: file, atomically: true, encoding: .utf8)
        let validationLog = root.appendingPathComponent("validations.log")
        let script = try makeTerraformScript(in: root, body: #"""
case "$1" in
validate) printf 'validate\n' >> '\#(validationLog.path)' ; printf 'Success! The configuration is valid.\n' ;;
show) printf '{"values":{"root_module":{"resources":[],"outputs":{}}}}' ;;
version) printf '{"terraform_version":"1.9.0"}' ;;
fmt) cat ;;
esac
"""#)
        let workspace = Workspace(restoreLastDirectory: false)
        workspace.runner = Runner(executableURL: script)
        workspace.workingDirectory = root
        let model = ConfigurationModel()
        model.attach(to: workspace)
        model.setVisible(true)

        model.draft = "terraform { # first edit\n}\n"
        model.save()
        try await Task.sleep(nanoseconds: 80_000_000)
        model.draft = "terraform { # second edit\n}\n"
        model.save()
        try await waitForValidationCount(1, at: validationLog)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(try validationCount(at: validationLog), 1)
        XCTAssertTrue(workspace.isValid)
        XCTAssertEqual(model.validationActivity, .idle)

        model.draft = "terraform { # canceled validation\n}\n"
        model.save()
        model.setVisible(false)
        XCTAssertEqual(model.validationActivity, .idle)
        XCTAssertFalse(model.message?.contains("no longer visible") == true)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(try validationCount(at: validationLog), 1)

        model.setVisible(false)
        model.draft = "terraform { # hidden edit\n}\n"
        model.save()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(try validationCount(at: validationLog), 1)

        model.setVisible(true)
        let unsavedDraft = "terraform { # keep this draft\n}\n"
        model.draft = unsavedDraft
        try "terraform { # external saved edit\n}\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitForValidationCount(2, at: validationLog)
        XCTAssertEqual(model.draft, unsavedDraft)
        XCTAssertTrue(model.hasConflict)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNotEqual(model.savedText, unsavedDraft)
    }

    private func makeTerraformScript(in directory: URL, body: String) throws -> URL {
        let script = directory.appendingPathComponent("terraform-test-double")
        try "#!/bin/sh\n\(body)".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func waitForFormattingToFinish(_ model: ConfigurationModel) async throws {
        for _ in 0..<100 {
            if !model.isFormatting { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Formatter did not finish within five seconds.")
    }

    private func waitForValidationCount(_ count: Int, at url: URL) async throws {
        for _ in 0..<100 {
            if (try? validationCount(at: url)) == count { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Validation did not reach the expected count.")
    }

    private func validationCount(at url: URL) throws -> Int {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return contents.components(separatedBy: "validate\n").count - 1
    }
}
