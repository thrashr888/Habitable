import XCTest
import SwiftyJSON
@testable import HabitableCore

final class ResourceInspectorTests: XCTestCase {
    func testNestedSensitiveValuesAreMaskedAndNeverAppearInSearchableText() {
        let values: [String: JSON] = [
            "plain": JSON("visible"),
            "settings": JSON(["token": "never-copy-this", "region": "west"]),
            "items": JSON(["first-secret", "ordinary"])
        ]
        let masks = JSON(["settings": ["token": true], "items": [true, false]])

        let attributes = resourceAttributes(values: values, sensitiveValues: masks)
        let byPath = Dictionary(uniqueKeysWithValues: attributes.map { ($0.path, $0.value) })
        XCTAssertEqual(byPath["\"plain\""], "visible")
        XCTAssertEqual(byPath["\"settings\"[\"region\"]"], "west")
        XCTAssertEqual(byPath["\"settings\"[\"token\"]"], "(sensitive value)")
        XCTAssertEqual(byPath["\"items\"[0]"], "(sensitive value)")
        XCTAssertEqual(byPath["\"items\"[1]"], "ordinary")
        XCTAssertFalse(attributes.map(\.searchableText).joined().contains("never-copy-this"))
        XCTAssertFalse(attributes.map(\.value).joined().contains("first-secret"))
    }

    func testEscapedKeysAndNestedArraysHaveStablePaths() {
        let values: [String: JSON] = ["odd\"key\n": JSON([[["value": 7]]])]
        let attributes = resourceAttributes(values: values, sensitiveValues: JSON([String: Bool]()))
        XCTAssertEqual(attributes.map(\.path), ["\"odd\\\"key\\n\"[0][0][\"value\"]"])
        XCTAssertEqual(attributes.first?.value, "7")
    }

    func testMaskStructureMismatchHidesWholeResourceValues() {
        let values: [String: JSON] = ["credentials": JSON(["password": "secret", "user": "alice"])]
        let malformedMask = JSON(["credentials": ["password": true, "missing": true]])
        let attributes = resourceAttributes(values: values, sensitiveValues: malformedMask)
        XCTAssertEqual(attributes, [ResourceAttribute(path: "$", value: "(sensitive value)")])
        XCTAssertFalse(attributes.map(\.searchableText).joined().contains("secret"))
    }

    func testFalseContainerMaskPreservesPublicDescendantsAndEmptyCollections() {
        let values: [String: JSON] = ["public": JSON(["value": "visible"]), "empty": JSON([])]
        let attributes = resourceAttributes(values: values, sensitiveValues: JSON(["public": false]))
        XCTAssertEqual(attributes.first { $0.path == "\"public\"[\"value\"]" }?.value, "visible")
        XCTAssertEqual(attributes.first { $0.path == "\"empty\"" }?.value, "[]")
    }

    func testProviderDocumentationUsesExactLockedVersionAndResourceSlug() throws {
        let lock = try lockFile("provider \"registry.terraform.io/hashicorp/aws\" {\n  version = \"5.42.0\"\n}")
        let docs = try XCTUnwrap(TerraformProviderDocumentation.resolve(
            providerIdentity: "registry.terraform.io/hashicorp/aws",
            resourceType: "aws_vpc",
            lockFile: lock
        ))
        XCTAssertEqual(docs.lockedVersion, "5.42.0")
        XCTAssertEqual(docs.providerURL?.absoluteString, "https://registry.terraform.io/providers/hashicorp/aws/5.42.0")
        XCTAssertEqual(docs.resourceURL?.absoluteString, "https://registry.terraform.io/providers/hashicorp/aws/5.42.0/docs/resources/vpc")

        let dataSource = try XCTUnwrap(TerraformProviderDocumentation.resolve(
            providerIdentity: "registry.terraform.io/hashicorp/aws",
            resourceType: "aws_vpc",
            resourceMode: "data",
            lockFile: lock
        ))
        XCTAssertEqual(dataSource.resourceURL?.absoluteString,
                       "https://registry.terraform.io/providers/hashicorp/aws/5.42.0/docs/data-sources/vpc")
    }

    func testProviderDocumentationDoesNotGuessLatestOrLinkPrivateSources() throws {
        let lock = try lockFile("provider \"registry.terraform.io/hashicorp/aws\" {\n  version = \"5.42.0\"\n}")
        let missingVersion = try XCTUnwrap(TerraformProviderDocumentation.resolve(
            providerIdentity: "registry.terraform.io/hashicorp/random",
            resourceType: "random_id",
            lockFile: lock
        ))
        XCTAssertNil(missingVersion.lockedVersion)
        XCTAssertNil(missingVersion.resourceURL)
        XCTAssertNil(TerraformProviderDocumentation.resolve(
            providerIdentity: "terraform.example.com/team/custom",
            resourceType: "custom_widget",
            lockFile: lock
        ))
        XCTAssertNil(TerraformProviderDocumentation.resolve(
            providerIdentity: "terraform.io/builtin/terraform",
            resourceType: "terraform_data",
            lockFile: lock
        ))
    }

    func testProviderAliasUsesCanonicalStateSourceFromLockFile() throws {
        let lock = try lockFile("provider \"registry.terraform.io/hashicorp/aws\" {\n  version = \"5.42.0\"\n}")
        let docs = try XCTUnwrap(TerraformProviderDocumentation.resolve(
            providerIdentity: "registry.terraform.io/hashicorp/aws",
            resourceType: "aws_instance",
            lockFile: lock
        ))
        XCTAssertEqual(docs.resourceURL?.host, "registry.terraform.io")
        XCTAssertTrue(docs.resourceURL?.path.contains("/5.42.0/") == true)
    }

    func testInstalledPublicModuleContextUsesExactVersionAndModuleAddress() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifestURL = workspace.appendingPathComponent(".terraform/modules/modules.json")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = #"{"Modules":[{"Key":"network","Source":"terraform-aws-modules/vpc/aws//modules/subnets","Version":"5.8.1","Dir":".terraform/modules/network"},{"Key":"network.dns","Source":"./modules/dns","Dir":"modules/dns"}]}"#
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }

        let docs = try XCTUnwrap(TerraformModuleDocumentation.resolve(
            resourceAddress: #"module.network["east.west"].aws_subnet.public"#,
            workspaceDirectory: workspace
        ))
        XCTAssertEqual(docs.key, "network")
        XCTAssertEqual(docs.version, "5.8.1")
        XCTAssertEqual(docs.registryURL?.absoluteString,
                       "https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/5.8.1")

        let local = try XCTUnwrap(TerraformModuleDocumentation.resolve(
            resourceAddress: "module.network.module.dns.null_resource.example",
            workspaceDirectory: workspace
        ))
        XCTAssertNil(local.registryURL)
        XCTAssertEqual(local.source, "./modules/dns")
    }

    private func lockFile(_ contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".terraform.lock.hcl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    func testRootSensitivityAndMissingRootMaskFailClosed() {
        let values: [String: JSON] = ["private": JSON("secret")]
        let fullySensitive = resourceAttributes(values: values, sensitiveValues: JSON(true))
        let absentMask = resourceAttributes(values: values, sensitiveValues: .null)
        let explicitlyPublic = resourceAttributes(values: values, sensitiveValues: JSON(false))
        XCTAssertEqual(fullySensitive, [ResourceAttribute(path: "$", value: "(sensitive value)")])
        XCTAssertEqual(absentMask, [ResourceAttribute(path: "$", value: "(sensitive value)")])
        XCTAssertEqual(explicitlyPublic.first?.value, "secret")
    }

    func testKnownSensitiveStringIsRedactedFromUnmarkedDuplicateValues() {
        let secret = "sensitive-input-token-93f7"
        let values: [String: JSON] = [
            "input": JSON(secret),
            "echoed_output": JSON("result included \(secret) in its text"),
            "public_output": JSON("independent public result")
        ]
        let attributes = resourceAttributes(values: values, sensitiveValues: JSON(["input": true]))
        let byPath = Dictionary(uniqueKeysWithValues: attributes.map { ($0.path, $0.value) })

        XCTAssertEqual(byPath["\"input\""], "(sensitive value)")
        XCTAssertEqual(byPath["\"echoed_output\""], "result included (sensitive value) in its text")
        XCTAssertEqual(byPath["\"public_output\""], "independent public result")
        XCTAssertFalse(attributes.map(\.searchableText).joined().contains(secret))
    }
}
