import Foundation
import XCTest
@testable import HabitableCore

final class TerraformConfigurationInspectorTests: XCTestCase {
    private func helper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["HABITABLE_CONFIG_INSPECT_PATH"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set HABITABLE_CONFIG_INSPECT_PATH to the pinned helper built by scripts/build-config-inspector.sh.")
        }
        return URL(fileURLWithPath: path)
    }

    func testDeclarationsAndInputSourcesUseTerraformParsersAndPrecedence() throws {
        let helper = try helper()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable inspector \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let declarations = #"""
        variable "regions" {
          description = "Regions for\nall deployments."
          type = object({
            primary = string
            replicas = list(number)
          })
          sensitive = true
          ephemeral = true
        }
        variable "no_default" { type = string }
        variable "null_default" {
          type = string
          default = null
        }
        variable "unknown_value" { type = string }
        """#
        try declarations.write(to: directory.appendingPathComponent("variables.tf"), atomically: true, encoding: .utf8)
        try #"{"variable":{"json_input":{"type":"string","description":"From JSON","default":null}}}"#
            .write(to: directory.appendingPathComponent("variables.tf.json"), atomically: true, encoding: .utf8)
        try #"""
        regions = { primary = "conventional", replicas = [1, 2] }
        unknown_value = "conventional"
        """#
            .write(to: directory.appendingPathComponent("terraform.tfvars"), atomically: true, encoding: .utf8)
        try #"{"regions":{"primary":"json","replicas":[3]},"json_only":"json-file"}"#
            .write(to: directory.appendingPathComponent("terraform.tfvars.json"), atomically: true, encoding: .utf8)
        try #"regions = { primary = "first", replicas = [4] }"#
            .write(to: directory.appendingPathComponent("a.auto.tfvars"), atomically: true, encoding: .utf8)
        try #"regions = { primary = "last", replicas = [5] }"#
            .write(to: directory.appendingPathComponent("z.auto.tfvars"), atomically: true, encoding: .utf8)
        try #"unknown_value = local.value"#
            .write(to: directory.appendingPathComponent("unresolved.auto.tfvars"), atomically: true, encoding: .utf8)

        let result = TerraformConfigurationInspector.inspect(directory: directory,
            environment: ["TF_VAR_regions": #"{"primary":"environment","replicas":[]}"#,
                          "TF_VAR_from_environment": #"["one", "two"]"#,
                          "TF_VAR_json_only": "environment",
                          "TF_VAR_app_environment": "from-app"], helper: helper,
            appEnvironmentKeys: ["TF_VAR_app_environment"])

        let declarationsByName = Dictionary(uniqueKeysWithValues: result.declarations.map { ($0.name, $0) })
        let objectType = declarationsByName["regions"]?.type ?? ""
        XCTAssertTrue(objectType.contains("object("))
        XCTAssertTrue(objectType.contains("primary = string"))
        XCTAssertTrue(objectType.contains("replicas = list(number)"))
        XCTAssertEqual(declarationsByName["regions"]?.description, "Regions for\nall deployments.")
        XCTAssertTrue(declarationsByName["regions"]?.sensitive == true)
        XCTAssertTrue(declarationsByName["regions"]?.ephemeral == true)
        XCTAssertTrue(declarationsByName["regions"]?.sourceLocation.hasPrefix("variables.tf:") == true)
        XCTAssertTrue(declarationsByName["no_default"]?.required == true)
        XCTAssertFalse(declarationsByName["no_default"]?.hasDefault ?? true)
        XCTAssertFalse(declarationsByName["null_default"]?.required ?? true)
        XCTAssertTrue(declarationsByName["null_default"]?.hasDefault == true)
        XCTAssertEqual(declarationsByName["null_default"]?.defaultJSON, Data("null".utf8))
        XCTAssertTrue(declarationsByName["json_input"]?.hasDefault == true)
        XCTAssertEqual(result.valueSources["regions"], "z.auto.tfvars")
        let regions = try JSONSerialization.jsonObject(with: XCTUnwrap(result.values["regions"])) as? NSDictionary
        XCTAssertEqual(regions, ["primary": "last", "replicas": [5]] as NSDictionary)
        XCTAssertEqual(result.valueSources["json_only"], "terraform.tfvars.json")
        XCTAssertEqual(result.values["json_only"], Data(#""json-file""#.utf8))
        XCTAssertEqual(result.valueSources["from_environment"], "TF_VAR_ environment")
        XCTAssertEqual(result.values["from_environment"], Data(#"["one","two"]"#.utf8))
        XCTAssertEqual(result.valueSources["app_environment"], "Habitable environment override")
        XCTAssertEqual(result.values["app_environment"], Data(#""from-app""#.utf8))
        XCTAssertNil(result.values["unknown_value"])
        XCTAssertTrue(result.unresolvedValues.contains("unknown_value"))
        XCTAssertEqual(result.unresolvedValueSources["unknown_value"], "unresolved.auto.tfvars")
        XCTAssertTrue(result.diagnostics.contains { $0.contains("unknown_value") })
    }

    func testDeletingDeclarationRemovesItOnRefresh() throws {
        let helper = try helper()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable inspector \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("variables.tf")
        try #"variable "temporary" { type = string }"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(TerraformConfigurationInspector.inspect(directory: directory, environment: [:], helper: helper)
            .declarations.contains { $0.name == "temporary" })
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(TerraformConfigurationInspector.inspect(directory: directory, environment: [:], helper: helper)
            .declarations.contains { $0.name == "temporary" })
    }
}
