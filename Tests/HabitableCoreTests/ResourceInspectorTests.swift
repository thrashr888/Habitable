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

    func testProviderLinksUseOnlyOfficialTerraformRegistryAddresses() throws {
        let url = try XCTUnwrap(terraformProviderRegistryURL("registry.terraform.io/hashicorp/aws"))
        XCTAssertEqual(url.absoluteString, "https://registry.terraform.io/providers/hashicorp/aws/latest")
        XCTAssertNil(terraformProviderRegistryURL("https://attacker.example/hashicorp/aws"))
        XCTAssertNil(terraformProviderRegistryURL("terraform.io/builtin/terraform"))
        XCTAssertNil(terraformProviderRegistryURL("hashicorp/aws"))
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
