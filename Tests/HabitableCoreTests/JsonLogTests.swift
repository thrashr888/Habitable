import XCTest
import SwiftyJSON
@testable import HabitableCore

final class JsonLogTests: XCTestCase {
    @MainActor
    func testDeepOutputValuesRemainVisibleAndPreserveEscapedKeys() throws {
        var nested: Any = ["quote\"and\nnewline": "leaf"]
        for _ in 0..<20 { nested = ["value": nested] }
        let output = JSON(["sensitive": false, "type": ["object", ["value": "string"]], "value": nested])
        let state = transformShow(JSON(["values": ["outputs": ["deep": output.object]]]))
        let displayed = try XCTUnwrap(state.outputs.first?.value)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(displayed.utf8)))
        XCTAssertTrue(displayed.contains("leaf"))
        XCTAssertEqual(state.outputs.first?.type, "object")
        let events = transformOutputs(JSON(["outputs": ["deep": output.object]]))
        XCTAssertEqual(events.outputs.first?.value, displayed)
    }

    func testOutputValuesPreserveScalarAndEmptyValues() {
        XCTAssertEqual(terraformOutputValue(JSON("")), "")
        XCTAssertEqual(terraformOutputValue(JSON(false)), "false")
        XCTAssertEqual(terraformOutputValue(JSON(0)), "0")
        XCTAssertEqual(terraformOutputValue(JSON(NSNull())), "null")
        XCTAssertEqual(terraformOutputValue(JSON([String: String]())), "{}")
        XCTAssertEqual(terraformOutputValue(JSON([String]())), "[]")
    }

    func testParseTerraformPlanRejectsMalformedOrIncompleteShowOutput() {
        XCTAssertNil(parseTerraformPlan("not json"))
        XCTAssertNil(parseTerraformPlan(#"{"format_version":"1.0"}"#))
        XCTAssertNil(parseTerraformPlan(#"{"format_version":"1.0","planned_values":[]}"#))
        XCTAssertNil(parseTerraformPlan(#"{"format_version":"1.0","planned_values":{},"resource_changes":"invalid"}"#))
        XCTAssertNotNil(parseTerraformPlan(#"{"format_version":"1.0","resource_changes":[]}"#))
        let outputOnly = #"{"format_version":"1.0","terraform_version":"1.16.4","planned_values":{"outputs":{"message":{"sensitive":false,"type":"string","value":"hello"}},"root_module":{"resources":[]}},"output_changes":{"message":{"actions":["create"],"before":null,"after":"hello","after_unknown":false,"before_sensitive":false,"after_sensitive":false}}}"#
        XCTAssertEqual(parseTerraformPlan(outputOnly)?.resourceChanges, [])
    }

    func testTransformPlanFlattensNestedValuesAndKeepsUnknownSensitiveAndReplacementReasons() {
        let fixture = #"""
        {
          "resource_changes": [
            {
              "address": "module.network[0].aws_subnet.public[\"a\"]",
              "change": {
                "actions": ["delete", "create"],
                "before": {"id":"subnet-old","tags":{"Name":"old","Owner":"platform"},"secret":"old-secret","gone":"removed"},
                "after": {"id":"subnet-new","tags":{"Name":"new","Owner":"platform"},"secret":"new-secret","computed":"later"},
                "before_sensitive": {"secret":true},
                "after_sensitive": {"secret":true},
                "after_unknown": {"computed":true},
                "replace_paths": [["id"], ["tags", "Name"]]
              }
            },
            {
              "address": "aws_vpc.main",
              "change": {"actions": ["create"], "before": null, "after": {"cidr_block":"10.0.0.0/16"}, "after_unknown": {}}
            },
            {
              "address": "aws_vpc.existing",
              "change": {"actions": ["update"], "before": {"tags":{"Name":"before"}}, "after": {"tags":{"Name":"after"}}, "after_unknown": {}}
            },
            {
              "address": "aws_vpc.retired",
              "change": {"actions": ["delete"], "before": {"id":"vpc-old"}, "after": null, "after_unknown": {}}
            }
          ]
        }
        """#

        let plan = transformPlan(JSON(parseJSON: fixture))
        XCTAssertEqual(plan.resourceChanges.map(\.address), [
            "module.network[0].aws_subnet.public[\"a\"]", "aws_vpc.main", "aws_vpc.existing", "aws_vpc.retired"
        ])
        let subnet = plan.resourceChanges[0]
        XCTAssertTrue(subnet.isReplacement)
        XCTAssertEqual(subnet.replacementPaths, ["id", "tags.Name"])
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "tags.Name" }),
                       PlanAttributeChange(path: "tags.Name", before: .value("old"), after: .value("new")))
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "secret" })?.before, .sensitive)
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "secret" })?.after, .sensitive)
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "computed" })?.after, .unknown)
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "gone" })?.after, .absent)
        XCTAssertEqual(plan.resourceChanges[1].attributes.first?.path, "cidr_block")
        XCTAssertEqual(plan.resourceChanges[1].action, "create")
        XCTAssertEqual(plan.resourceChanges[2].action, "update")
        XCTAssertEqual(plan.resourceChanges[3].action, "delete")
    }

    @MainActor
    func testTransformShowCollectsResourcesFromNestedModules() throws {
        let fixture = #"""
        {
          "format_version": "1.0",
          "terraform_version": "1.9.0",
          "values": {
            "root_module": {
              "resources": [
                {"address":"aws_vpc.root","mode":"managed","type":"aws_vpc","name":"root","provider_name":"registry.terraform.io/hashicorp/aws","schema_version":0,"values":{"id":"vpc-root"}}
              ],
              "child_modules": [
                {
                  "address":"module.network[0]",
                  "resources": [
                    {"address":"module.network[0].aws_subnet.public[\"a\"]","mode":"managed","type":"aws_subnet","name":"public","provider_name":"registry.terraform.io/hashicorp/aws","schema_version":0,"values":{"id":"subnet-a"}},
                    {"address":"module.network[0].aws_subnet.public[\"b\"]","mode":"managed","type":"aws_subnet","name":"public","provider_name":"registry.terraform.io/hashicorp/aws","schema_version":0,"values":{"id":"subnet-b"}}
                  ],
                  "child_modules": [
                    {
                      "address":"module.network[0].module.dns[\"blue\"]",
                      "resources": [
                        {"address":"module.network[0].module.dns[\"blue\"].aws_route53_zone.zone","mode":"managed","type":"aws_route53_zone","name":"zone","provider_name":"registry.terraform.io/hashicorp/aws","schema_version":0,"values":{"id":"zone-blue"}}
                      ]
                    }
                  ]
                },
                {
                  "address":"module.network[1]",
                  "resources": [
                    {"address":"module.network[1].aws_subnet.public[\"a\"]","mode":"managed","type":"aws_subnet","name":"public","provider_name":"registry.terraform.io/hashicorp/aws","schema_version":0,"values":{"id":"subnet-c"}}
                  ]
                }
              ]
            }
          }
        }
        """#

        let parsed = transformShow(JSON(parseJSON: fixture))
        let addresses = try XCTUnwrap(parsed.resources.map(\.address))

        XCTAssertEqual(addresses, [
            "aws_vpc.root",
            "module.network[0].aws_subnet.public[\"a\"]",
            "module.network[0].aws_subnet.public[\"b\"]",
            "module.network[0].module.dns[\"blue\"].aws_route53_zone.zone",
            "module.network[1].aws_subnet.public[\"a\"]"
        ])
        XCTAssertEqual(parsed.root_module.resources.map(\.address), parsed.resources.map(\.address))
    }
}
