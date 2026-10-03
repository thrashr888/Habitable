import Foundation
import XCTest
@testable import HabitableCore

final class TerraformConfigurationContextHelpTests: XCTestCase {
    func testDeclaredModulesAndNormalizedLockedProviderAreAvailableBeforeInit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "provider \"registry.terraform.io/hashicorp/aws\" {\n  version = \"5.42.0\"\n}\n".write(
            to: root.appendingPathComponent(".terraform.lock.hcl"), atomically: true, encoding: .utf8)
        let helper = try metadataHelper(in: root)

        let context = TerraformConfigurationContextHelpLoader.load(directory: root, helper: helper)
        let provider = try XCTUnwrap(context.providers.first)
        XCTAssertEqual(provider.source, "registry.terraform.io/hashicorp/aws")
        XCTAssertEqual(provider.lockedVersion, "5.42.0")
        XCTAssertNotNil(provider.documentationURL)
        let module = try XCTUnwrap(context.modules.first(where: { $0.key == "child" }))
        XCTAssertEqual(module.source, "acme/child/aws")
        XCTAssertEqual(module.declaredVersion, "~> 2.0")
        XCTAssertNil(module.installedVersion)
        XCTAssertNil(module.documentationURL)
        XCTAssertTrue(context.inputs.contains { $0.name == "region" && $0.defaultJSON == nil })
        XCTAssertTrue(context.outputs.contains { $0.name == "endpoint" })
    }

    func testInstalledModuleMetadataLoadsOnlyFromWorkspacePaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let moduleDirectory = root.appendingPathComponent(".terraform/modules/child", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
        try "output \"endpoint\" { value = \"private-value\" }".write(
            to: moduleDirectory.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-module-\(UUID().uuidString)")
        let manifestDirectory = root.appendingPathComponent(".terraform/modules", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["Modules": [
            ["Key": "child", "Source": "acme/child/aws", "Version": "2.1.0", "Dir": moduleDirectory.path],
            ["Key": "outside", "Source": "../outside", "Dir": outside.path]
        ]]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: manifestDirectory.appendingPathComponent("modules.json"))
        let helper = try metadataHelper(in: root)

        let context = TerraformConfigurationContextHelpLoader.load(directory: root, helper: helper)
        let installed = try XCTUnwrap(context.modules.first(where: { $0.key == "child" }))
        XCTAssertEqual(installed.installedVersion, "2.1.0")
        XCTAssertNotNil(installed.documentationURL)
        XCTAssertTrue(installed.metadata?.outputs.contains(where: { $0.name == "endpoint" }) == true)
        let unsafe = try XCTUnwrap(context.modules.first(where: { $0.key == "outside" }))
        XCTAssertNil(unsafe.metadata)
        XCTAssertNil(unsafe.documentationURL)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("habitable-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func metadataHelper(in directory: URL) throws -> URL {
        let helper = directory.appendingPathComponent("metadata-helper")
        let payload = #"{"variables":{"region":{"name":"region","type":"string","description":"Cloud region","required":true,"has_default":false}},"outputs":{"endpoint":{"name":"endpoint","description":"Service endpoint","type":"string"}},"required_providers":{"aws":{"name":"aws","source":"hashicorp/aws","version_constraints":["~> 5.0"],"aliases":[{"name":"west","alias":"west"}]}},"module_calls":{"child":{"name":"child","source":"acme/child/aws","version":"~> 2.0"}},"required_core":[">= 1.5.0"]}"#
        try "#!/bin/sh\nprintf '%s\\n' '\(payload)'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }
}
