import Foundation
import XCTest
@testable import HabitableCore

final class TerraformProviderSchemaTests: XCTestCase {
    func testDecodesMetadataByFullProviderSourceAndPreservesNestedFlags() throws {
        let index = try TerraformProviderSchemaLoader.decode(Data(#"{"format_version":"1.0","provider_schemas":{"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_instance":{"block":{"attributes":{"ami":{"type":"string","required":true,"description":"Image identifier"},"secret":{"type":"string","optional":true,"sensitive":true},"id":{"type":"string","computed":true}},"block_types":{"network":{"block":{"attributes":{"subnet_id":{"type":"string","optional":true}}}}}}}}}}}"#.utf8))

        let attributes = try XCTUnwrap(index.attributes(
            providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_instance", mode: "managed"))
        let byPath = Dictionary(uniqueKeysWithValues: attributes.map { ($0.path, $0) })
        XCTAssertEqual(byPath["ami"]?.type, "string")
        XCTAssertEqual(byPath["ami"]?.description, "Image identifier")
        XCTAssertTrue(byPath["ami"]?.required == true)
        XCTAssertTrue(byPath["secret"]?.optional == true)
        XCTAssertTrue(byPath["secret"]?.sensitive == true)
        XCTAssertTrue(byPath["id"]?.computed == true)
        XCTAssertTrue(byPath["network.subnet_id"]?.optional == true)
        XCTAssertNil(index.attributes(providerIdentity: "private.example/hashicorp/aws", resourceType: "aws_instance", mode: "managed"))
    }

    func testPrivateProviderIdentityIsMatchedExactly() throws {
        let data = Data(#"{"format_version":"1.0","provider_schemas":{"private.example/acme/aws":{"resource_schemas":{"aws_instance":{"block":{"attributes":{"private_only":{"type":"bool","optional":true}}}}}},"registry.terraform.io/hashicorp/aws":{"resource_schemas":{"aws_instance":{"block":{"attributes":{"public_only":{"type":"bool","optional":true}}}}}}}}"#.utf8)
        let index = try TerraformProviderSchemaLoader.decode(data)
        XCTAssertEqual(index.attributes(providerIdentity: "private.example/acme/aws", resourceType: "aws_instance", mode: "managed")?.map(\.path), ["private_only"])
        XCTAssertEqual(index.attributes(providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_instance", mode: "managed")?.map(\.path), ["public_only"])
    }

    func testBuiltInTerraformSchemaCanBeLookedUpWithoutProviderInstallationMetadata() throws {
        let data = Data(#"{"format_version":"1.0","provider_schemas":{"terraform.io/builtin/terraform":{"resource_schemas":{"terraform_data":{"block":{"attributes":{"input":{"type":["dynamic"],"optional":true}}}}}}}}"#.utf8)
        let index = try TerraformProviderSchemaLoader.decode(data)
        XCTAssertEqual(index.attributes(providerIdentity: "terraform.io/builtin/terraform", resourceType: "terraform_data", mode: "managed")?.map(\.path), ["input"])
        XCTAssertNil(index.attributes(providerIdentity: "terraform.io/builtin/terraform", resourceType: "terraform_data", mode: "data"))
    }

    func testInstalledTerraformDataSchemaLoadsFromLocalBuiltInProviderWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["HABITABLE_TEST_TERRAFORM"] else {
            throw XCTSkip("Set HABITABLE_TEST_TERRAFORM to run the local built-in schema integration test.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("habitable-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "resource \"terraform_data\" \"example\" { input = \"local\" }\n".write(
            to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["init", "-backend=false", "-input=false"]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Local terraform_data workspace initialization should succeed without a provider download.")

        let (_, index) = try TerraformProviderSchemaLoader.load(executable: URL(fileURLWithPath: path), directory: root)
        let attributes = try XCTUnwrap(index.attributes(
            providerIdentity: "terraform.io/builtin/terraform", resourceType: "terraform_data", mode: "managed"))
        XCTAssertTrue(attributes.contains { $0.path == "input" && $0.optional })
        XCTAssertTrue(attributes.contains { $0.path == "id" && $0.computed })
    }

    func testRejectsMalformedAndUnsupportedSchemaDocuments() {
        XCTAssertThrowsError(try TerraformProviderSchemaLoader.decode(Data("not json".utf8))) { error in
            guard case TerraformProviderSchemaLoader.SchemaError.malformed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try TerraformProviderSchemaLoader.decode(Data(#"{"format_version":"2.0","provider_schemas":{}}"#.utf8))) { error in
            guard case TerraformProviderSchemaLoader.SchemaError.unsupportedFormat = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
