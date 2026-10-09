import XCTest
@testable import HabitableCore

final class RegistryModulesTests: XCTestCase {
    private let detailJSON = """
    {"id":"acme/vpc/aws/1.2.3","namespace":"acme","name":"vpc","provider":"aws","version":"1.2.3",
     "description":"A VPC","source":"https://github.com/acme/terraform-aws-vpc","downloads":42,"verified":true,
     "root":{"inputs":[
        {"name":"cidr","type":"string","description":"The CIDR","required":true},
        {"name":"azs","type":"list(string)","description":"Zones","required":true},
        {"name":"tags","type":"map(string)","description":"","default":"{}","required":false}],
      "outputs":[{"name":"vpc_id","description":"The id"}],
      "resources":[{"name":"this","type":"aws_vpc"},{"name":"public","type":"aws_subnet"}]}}
    """

    func testSearchURLUsesVerifiedListWithoutQuery() {
        let url = RegistryModules.searchURL(query: "  ", provider: nil)
        XCTAssertEqual(url.path, "/v1/modules")
        XCTAssertTrue(url.query?.contains("verified=true") == true)
        let search = RegistryModules.searchURL(query: "vpc", provider: "aws")
        XCTAssertEqual(search.path, "/v1/modules/search")
        XCTAssertTrue(search.query?.contains("q=vpc") == true)
        XCTAssertTrue(search.query?.contains("provider=aws") == true)
    }

    func testParseSearchSortsByDownloads() throws {
        let json = """
        {"modules":[{"id":"a/x/aws/1.0.0","namespace":"a","name":"x","provider":"aws","version":"1.0.0","description":"","source":"","downloads":5,"verified":false},
                    {"id":"b/y/aws/1.0.0","namespace":"b","name":"y","provider":"aws","version":"1.0.0","description":"","source":"","downloads":50,"verified":true}]}
        """
        let modules = try RegistryModules.parseSearch(Data(json.utf8))
        XCTAssertEqual(modules.map(\.name), ["y", "x"])
        XCTAssertEqual(modules[0].registryURL.absoluteString, "https://registry.terraform.io/modules/b/y/aws/1.0.0")
    }

    func testParseDetailOrdersRequiredFirst() throws {
        let detail = try RegistryModules.parseDetail(Data(detailJSON.utf8))
        XCTAssertEqual(detail.inputs.map(\.name), ["azs", "cidr", "tags"])
        XCTAssertEqual(detail.requiredInputs.count, 2)
        XCTAssertEqual(detail.resources.count, 2)
        XCTAssertEqual(detail.summary.sourceURL?.host, "github.com")
    }

    func testOnlyHTTPSSourcesBecomeLinks() {
        XCTAssertNil(RegistryModules.httpsURL("git::ssh://git@example.com/x.git"))
        XCTAssertNil(RegistryModules.httpsURL("http://example.com/x"))
        XCTAssertNotNil(RegistryModules.httpsURL("https://example.com/x"))
    }

    func testTemplateCallsModuleAndLinksBack() throws {
        let detail = try RegistryModules.parseDetail(Data(detailJSON.utf8))
        let template = RegistryModules.template(for: detail)
        XCTAssertEqual(template.category, .registry)
        XCTAssertEqual(template.inputs.map(\.name), ["azs", "cidr"])
        XCTAssertEqual(template.links.map(\.title), ["View in Registry", "Source"])
        let main = try XCTUnwrap(template.files["main.tf"])
        XCTAssertTrue(main.contains("source  = \"acme/vpc/aws\""))
        XCTAssertTrue(main.contains("version = \"1.2.3\""))
        XCTAssertTrue(main.contains("cidr = var.cidr"))
        XCTAssertTrue(main.contains("registry.terraform.io/modules/acme/vpc/aws/1.2.3"))
        let variables = try XCTUnwrap(template.files["variables.tf"])
        XCTAssertTrue(variables.contains("type        = list(string)"))
        XCTAssertTrue(variables.contains("default     = ${azs}"))
        XCTAssertTrue(variables.contains("default     = \"${cidr}\""))
        let readme = try XCTUnwrap(template.files["README.md"])
        XCTAssertTrue(readme.contains("https://github.com/acme/terraform-aws-vpc"))
        XCTAssertTrue(readme.contains("`vpc_id`"))
    }

    func testWritingRegistryTemplateFillsBlankListWithEmptyList() throws {
        let detail = try RegistryModules.parseDetail(Data(detailJSON.utf8))
        let template = RegistryModules.template(for: detail)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try InfrastructureTemplates.write(template, to: folder, inputs: ["cidr": "10.0.0.0/16"])
        let variables = try String(contentsOf: folder.appendingPathComponent("variables.tf"), encoding: .utf8)
        XCTAssertTrue(variables.contains("default     = []"))
        XCTAssertTrue(variables.contains("default     = \"10.0.0.0/16\""))
    }
}
