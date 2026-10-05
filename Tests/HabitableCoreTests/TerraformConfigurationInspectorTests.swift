import Foundation
import XCTest
@testable import HabitableCore

final class TerraformConfigurationInspectorTests: XCTestCase {
    func testRemoteWorkspaceLinkUsesExactTerraformSelectorAndDefaultHostname() throws {
        // Mirrors Terraform's initialized backend serialization: omitted optional
        // cloud attributes are retained as JSON null.
        let metadata = Data(#"{"backend":{"type":"cloud","config":{"hostname":null,"organization":"example-org","token":null,"workspaces":{"name":"prod","project":null,"tags":null}}}}"#.utf8)
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(backendMetadata: metadata))
        XCTAssertEqual(link.hostname, "app.terraform.io")
        XCTAssertEqual(link.organization, "example-org")
        XCTAssertEqual(link.workspaceName, "prod")
        XCTAssertEqual(link.url.absoluteString, "https://app.terraform.io/app/example-org/workspaces/prod")
        XCTAssertTrue(link.isExact)
        XCTAssertTrue(link.isInitialized)
        XCTAssertEqual(link.selectorDescription, "workspace prod")
    }

    func testRemoteWorkspaceLinkRejectsAmbiguousOrMalformedSelectors() {
        let base = #"{"backend":{"type":"remote","config":{"organization":"example-org","workspaces":{"name":"prod","tags":null,"prefix":null}}}}"#
        XCTAssertNotNil(TerraformRemoteWorkspaceLink.resolve(backendMetadata: Data(base.utf8)))
        for invalid in [
            #"{"backend":{"type":"remote","config":{"organization":"example-org","workspaces":{"name":"prod","tags":{"env":"prod"}}}}}"#,
            #"{"backend":{"type":"remote","config":{"organization":"example-org","workspaces":{"name":"prod","prefix":"prod-"}}}}"#,
            #"{"backend":{"type":"remote","config":{"hostname":17,"organization":"example-org","workspaces":{"name":"prod"}}}}"#
        ] {
            XCTAssertNil(TerraformRemoteWorkspaceLink.resolve(backendMetadata: Data(invalid.utf8)))
        }
    }

    private func backendJSON(type: String = "cloud", org: String = "example-org", workspaces: String) -> Data {
        Data(#"{"backend":{"type":"\#(type)","config":{"organization":"\#(org)","workspaces":\#(workspaces)}}}"#.utf8)
    }

    func testTagsWithoutSelectionResolveToTagLink() throws {
        let data = backendJSON(workspaces: #"{"name":null,"tags":["prod","app","app"]}"#)
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(backendMetadata: data))
        XCTAssertEqual(link.selector, .tags(["app", "prod"]))
        XCTAssertFalse(link.isExact)
        XCTAssertNil(link.workspaceName)
        XCTAssertEqual(link.selectorDescription, "workspaces tagged app, prod")
        XCTAssertTrue(link.url.absoluteString.hasSuffix("/workspaces"))
    }

    func testTagsWithSelectedWorkspaceResolveToName() throws {
        let data = backendJSON(workspaces: #"{"tags":["app"]}"#)
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(backendMetadata: data, selectedWorkspace: "prod-app"))
        XCTAssertEqual(link.selector, .name("prod-app"))
        XCTAssertTrue(link.url.absoluteString.hasSuffix("/workspaces/prod-app"))
    }

    func testPrefixResolution() throws {
        let data = backendJSON(type: "remote", workspaces: #"{"name":null,"prefix":"app-"}"#)
        XCTAssertEqual(TerraformRemoteWorkspaceLink.resolve(backendMetadata: data, selectedWorkspace: "blue")?.selector,
                       .name("app-blue"))
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(backendMetadata: data))
        XCTAssertEqual(link.selector, .prefix("app-"))
        XCTAssertEqual(link.selectorDescription, "workspaces prefixed app-")
    }

    func testDictionaryTagsAreUnsupported() {
        let data = backendJSON(workspaces: #"{"tags":{"env":"prod"}}"#)
        XCTAssertNil(TerraformRemoteWorkspaceLink.resolve(backendMetadata: data))
        XCTAssertNil(TerraformRemoteWorkspaceLink.resolve(backendMetadata: data, selectedWorkspace: "prod"))
    }

    func testConfigurationDeclarationResolution() throws {
        var declaration = TerraformBackendDeclaration(type: "cloud", hostname: nil, organization: "org",
            workspaceName: "prod", sourceFile: "main.tf", sourceLine: 3)
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(configuration: declaration))
        XCTAssertEqual(link.selector, .name("prod"))
        XCTAssertEqual(link.source, .configuration(sourceFile: "main.tf"))
        XCTAssertFalse(link.isInitialized)
        XCTAssertEqual(link.hostname, "app.terraform.io")

        declaration.unresolved = ["organization"]
        XCTAssertNil(TerraformRemoteWorkspaceLink.resolve(configuration: declaration))

        let remote = TerraformBackendDeclaration(type: "remote", hostname: "tfe.example.com", organization: "org",
            workspacePrefix: "app-", sourceFile: "main.tf", sourceLine: nil)
        XCTAssertEqual(TerraformRemoteWorkspaceLink.resolve(configuration: remote)?.selector, .prefix("app-"))
        XCTAssertNil(TerraformRemoteWorkspaceLink.resolve(configuration: TerraformBackendDeclaration(
            type: "s3", organization: "org", workspaceName: "x", sourceFile: "main.tf")))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable link \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".terraform"), withIntermediateDirectories: true)
        return folder
    }

    func testWorkingDirectoryResolvesInitializedTagsWithSelectedWorkspace() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try backendJSON(workspaces: #"{"tags":["app"]}"#).write(to: folder.appendingPathComponent(".terraform/terraform.tfstate"))
        try "prod\n".write(to: folder.appendingPathComponent(".terraform/environment"), atomically: true, encoding: .utf8)
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(workingDirectory: folder))
        XCTAssertEqual(link.selector, .name("prod"))
        XCTAssertTrue(link.isInitialized)
    }

    func testInitializedNonCloudBackendDoesNotFallBackToConfiguration() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"backend":{"type":"s3","config":{"bucket":"b"}}}"#.utf8)
            .write(to: folder.appendingPathComponent(".terraform/terraform.tfstate"))
        try #"terraform { cloud { organization = "org"\n workspaces { name = "prod" } } }"#
            .write(to: folder.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        XCTAssertNil(TerraformRemoteWorkspaceLink.resolve(workingDirectory: folder, helper: try? helper()))
    }

    func testWorkingDirectoryFallsBackToConfigurationWithoutMetadata() throws {
        let helper = try helper()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        terraform {
          cloud {
            organization = "org"
            workspaces {
              name = "prod"
            }
          }
        }
        """.write(to: folder.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let link = try XCTUnwrap(TerraformRemoteWorkspaceLink.resolve(workingDirectory: folder, helper: helper))
        XCTAssertEqual(link.selector, .name("prod"))
        XCTAssertEqual(link.source, .configuration(sourceFile: "main.tf"))
    }

    @MainActor
    func testLocalWorkspaceLinkIndexMatchesExactWorkspaceOnly() async throws {
        let first = try makeFolder(), second = try makeFolder()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try backendJSON(workspaces: #"{"name":"prod"}"#).write(to: first.appendingPathComponent(".terraform/terraform.tfstate"))
        try backendJSON(workspaces: #"{"name":"staging"}"#).write(to: second.appendingPathComponent(".terraform/terraform.tfstate"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable missing \(UUID())")
        let index = LocalWorkspaceLinkIndex()
        await index.refresh(folders: [first, second, missing])
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.folders(hostname: "APP.TERRAFORM.IO", organization: "example-org", workspaceName: "prod"), [first])
        XCTAssertTrue(index.folders(hostname: "app.terraform.io", organization: "Example-Org", workspaceName: "prod").isEmpty)
        XCTAssertFalse(index.isRefreshing)
    }

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

    func testDeclarationResolutionTraversesLocalNestedModulesAndInstanceKeys() throws {
        let helper = try helper()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Playground", isDirectory: true)
        let addresses = [
            "terraform_data.worker[0]",
            "module.region[\"east.zone\"].terraform_data.zone[\"東京\"]",
            "module.region[\"東京.研究\"].module.metrics.terraform_data.collector"
        ]

        let declarations = TerraformConfigurationInspector.declarations(
            for: addresses, directory: fixture, helper: helper)

        XCTAssertEqual(declarations[addresses[0]]?.sourceFile, "main.tf")
        XCTAssertEqual(declarations[addresses[1]]?.sourceFile, "modules/region/main.tf")
        XCTAssertEqual(declarations[addresses[2]]?.sourceFile, "modules/metrics/main.tf")
        XCTAssertNotNil(declarations[addresses[0]]?.sourceLine)
        XCTAssertNotNil(declarations[addresses[1]]?.sourceLine)
        XCTAssertNotNil(declarations[addresses[2]]?.sourceLine)
    }

    func testModuleDeclarationResolutionRejectsExternalAndHiddenSources() throws {
        let helper = try helper()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable modules \(UUID())", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"module "child" { source = "./child" }"#.write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try #"resource "terraform_data" "inside" {}"#.write(to: child.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try #"resource "terraform_data" "inside" {}"#.write(to: hidden.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let inside = TerraformConfigurationInspector.declarations(
            for: ["module.child.terraform_data.inside"], directory: root, helper: helper)
        XCTAssertNotNil(inside["module.child.terraform_data.inside"])

        try #"module "child" { source = "../outside" }"#.write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        XCTAssertNil(TerraformConfigurationInspector.declarations(
            for: ["module.child.terraform_data.inside"], directory: root, helper: helper)["module.child.terraform_data.inside"])

        try #"module "child" { source = "./.hidden" }"#.write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        XCTAssertNil(TerraformConfigurationInspector.declarations(
            for: ["module.child.terraform_data.inside"], directory: root, helper: helper)["module.child.terraform_data.inside"])
    }
}
