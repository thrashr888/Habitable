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

    func testParseTerraformPlanRejectsMalformedOrIncompleteShowOutput() throws {
        XCTAssertNil(parseTerraformPlan("not json"))
        XCTAssertNil(parseTerraformPlan(#"{"format_version":"1.0"}"#))
        XCTAssertNil(parseTerraformPlan(#"{"format_version":"1.0","planned_values":[]}"#))
        XCTAssertNil(parseTerraformPlan(#"{"format_version":"1.0","planned_values":{},"resource_changes":"invalid"}"#))
        XCTAssertNotNil(parseTerraformPlan(#"{"format_version":"1.0","resource_changes":[]}"#))
        let outputOnly = #"{"format_version":"1.0","terraform_version":"1.16.4","planned_values":{"outputs":{"message":{"sensitive":false,"type":"string","value":"hello"}},"root_module":{"resources":[]}},"output_changes":{"message":{"actions":["create"],"before":null,"after":"hello","after_unknown":false,"before_sensitive":false,"after_sensitive":false}}}"#
        XCTAssertEqual(parseTerraformPlan(outputOnly)?.resourceChanges, [])
        let parsedOutputOnly = try XCTUnwrap(parseTerraformPlan(outputOnly))
        XCTAssertEqual(parsedOutputOnly.outputChanges.count, 1)
        XCTAssertEqual(parsedOutputOnly.outputChanges[0].name, "message")
        XCTAssertEqual(parsedOutputOnly.outputChanges[0].attributes.first,
                       PlanAttributeChange(path: "$", before: .absent, after: .value("hello")))
    }

    func testPlanOutputChangesMaskNestedSensitiveAndUnknownValuesAndIgnoreNoOps() throws {
        let fixture = #"""
        {
          "format_version":"1.0",
          "planned_values":{"outputs":{},"root_module":{"resources":[]}},
          "resource_changes":[],
          "output_changes":{
            "config":{"actions":["update"],"before":{"public":"old","token":"old-secret","nested":{"key":"before"}},"after":{"public":"new","token":"new-secret","nested":{"key":null}},"before_sensitive":{"token":true},"after_sensitive":{"token":true},"after_unknown":{"nested":{"key":true}}},
            "same":{"actions":["no-op"],"before":"unchanged","after":"unchanged"},
            "empty":{"actions":["create"],"before":null,"after":{}},
            "transition":{"actions":["update"],"before":"legacy","after":{"public":"new","token":"transition-secret"},"after_sensitive":{"token":true}},
            "null_added":{"actions":["update"],"before":{},"after":{"added":null}},
            "null_removed":{"actions":["update"],"before":{"removed":null},"after":{}}
          }
        }
        """#

        let plan = try XCTUnwrap(parseTerraformPlan(fixture))
        XCTAssertEqual(plan.outputChanges.map(\.name), ["config", "empty", "null_added", "null_removed", "same", "transition"])
        let config = try XCTUnwrap(plan.outputChanges.first)
        XCTAssertEqual(config.attributes.first(where: { $0.path == "$[\"token\"]" })?.before, .sensitive)
        XCTAssertEqual(config.attributes.first(where: { $0.path == "$[\"token\"]" })?.after, .sensitive)
        XCTAssertEqual(config.attributes.first(where: { $0.path == "$[\"nested\"][\"key\"]" })?.after, .unknown)
        XCTAssertEqual(config.attributes.first(where: { $0.path == "$[\"public\"]" }),
                       PlanAttributeChange(path: "$[\"public\"]", before: .value("old"), after: .value("new")))
        XCTAssertFalse(String(describing: plan).contains("old-secret"))
        XCTAssertFalse(String(describing: plan).contains("new-secret"))
        XCTAssertEqual(plan.outputChanges.first(where: { $0.name == "same" })?.action, "no-op")
        let empty = try XCTUnwrap(plan.outputChanges.first(where: { $0.name == "empty" })?.attributes.first)
        XCTAssertEqual(empty.before, .absent)
        XCTAssertEqual(empty.after, .value("{}"))
        let transition = try XCTUnwrap(plan.outputChanges.first(where: { $0.name == "transition" })?.attributes.first)
        XCTAssertEqual(transition.before, .value("\"legacy\""))
        XCTAssertTrue(transition.after.displayValue.contains("(sensitive value)"))
        XCTAssertFalse(String(describing: transition).contains("transition-secret"))
        let addedNull = try XCTUnwrap(plan.outputChanges.first(where: { $0.name == "null_added" })?.attributes.first)
        XCTAssertEqual(addedNull.before, .absent)
        XCTAssertEqual(addedNull.after, .value("null"))
        let removedNull = try XCTUnwrap(plan.outputChanges.first(where: { $0.name == "null_removed" })?.attributes.first)
        XCTAssertEqual(removedNull.before, .value("null"))
        XCTAssertEqual(removedNull.after, .absent)
    }

    func testPlanAttributePathsDistinguishLiteralPunctuationFromNestedKeysAndArrayIndices() throws {
        let fixture = #"""
        {
          "format_version":"1.0",
          "planned_values":{"outputs":{},"root_module":{"resources":[]}},
          "resource_changes":[{"address":"example.test","change":{
            "actions":["update"],
            "before":{"a.b":"old literal","a":{"b":"old nested"},"items[0]":"old bracket","items":["old array"]},
            "after":{"a.b":"new literal","a":{"b":"new nested"},"items[0]":"new bracket","items":["new array"]}
          }}]
        }
        """#

        let plan = try XCTUnwrap(parseTerraformPlan(fixture))
        let attributes = try XCTUnwrap(plan.resourceChanges.first?.attributes)
        let byPath = Dictionary(uniqueKeysWithValues: attributes.map { ($0.path, $0) })
        XCTAssertEqual(byPath["$[\"a.b\"]"]?.before, .value("old literal"))
        XCTAssertEqual(byPath["$[\"a\"][\"b\"]"]?.before, .value("old nested"))
        XCTAssertEqual(byPath["$[\"items[0]\"]"]?.before, .value("old bracket"))
        XCTAssertEqual(byPath["$[\"items\"][0]"]?.before, .value("old array"))
        XCTAssertEqual(Set(attributes.map(\.id)).count, attributes.count)
    }

    func testPlanReviewIncludesAttributesPresentOnlyInUnknownAndSensitiveMasks() throws {
        let fixture = #"""
        {
          "format_version":"1.0",
          "planned_values":{"outputs":{},"root_module":{"resources":[]}},
          "resource_changes":[{"address":"example.test","change":{
            "actions":["create"],
            "before":null,
            "after":{"input":{"store":{},"triggers":[]}},
            "after_unknown":{"id":true,"input":{"store":true,"triggers":[true]}},
            "after_sensitive":{"secret":true}
          }}],
          "output_changes":{"generated":{"actions":["create"],"before":null,"after":null,"after_unknown":true}}
        }
        """#

        let plan = try XCTUnwrap(parseTerraformPlan(fixture))
        let resourceAttributes = try XCTUnwrap(plan.resourceChanges.first?.attributes)
        XCTAssertEqual(resourceAttributes.first(where: { $0.path == "$[\"id\"]" })?.after, .unknown)
        XCTAssertEqual(resourceAttributes.first(where: { $0.path == "$[\"input\"][\"store\"]" })?.after, .unknown)
        XCTAssertEqual(resourceAttributes.first(where: { $0.path == "$[\"input\"][\"triggers\"][0]" })?.after, .unknown)
        XCTAssertEqual(resourceAttributes.first(where: { $0.path == "$[\"secret\"]" })?.after, .sensitive)
        XCTAssertEqual(plan.outputChanges.first?.attributes.first?.after, .unknown)
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
        XCTAssertEqual(subnet.replacementPaths, ["$[\"id\"]", "$[\"tags\"][\"Name\"]"])
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "$[\"tags\"][\"Name\"]" }),
                       PlanAttributeChange(path: "$[\"tags\"][\"Name\"]", before: .value("old"), after: .value("new")))
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "$[\"secret\"]" })?.before, .sensitive)
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "$[\"secret\"]" })?.after, .sensitive)
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "$[\"computed\"]" })?.after, .unknown)
        XCTAssertEqual(subnet.attributes.first(where: { $0.path == "$[\"gone\"]" })?.after, .absent)
        XCTAssertEqual(plan.resourceChanges[1].attributes.first?.path, "$[\"cidr_block\"]")
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
