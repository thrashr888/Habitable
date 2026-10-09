import XCTest
@testable import HabitableCore

final class ResourceListQueryTests: XCTestCase {
    private func row(_ address: String, type: String = "aws_security_group", module: String = "root", name: String = "x",
                     status: String = "unchanged", provider: String = "aws", kind: String = "") -> ResourceListRow {
        ResourceListRow(id: address, address: address, name: name, type: type, provider: provider, module: module,
                        kind: kind, tileID: nil, status: status, isDataSource: false)
    }

    func testParsesTokensAndFreeText() {
        let query = ResourceListQuery(text: #"type:aws_* module:edge "status:drifted" ssh"#)
        XCTAssertEqual(query.tokens, [
            ResourceListToken(field: .type, value: "aws_*"),
            ResourceListToken(field: .module, value: "edge"),
            ResourceListToken(field: .status, value: "drifted"),
        ])
        XCTAssertEqual(query.freeText, "ssh")
    }

    func testQuotedValueAndUnknownPrefixAndEmptyValue() {
        let query = ResourceListQuery(text: #"name:"web server" foo:bar type: ssh"#)
        XCTAssertEqual(query.tokens, [ResourceListToken(field: .name, value: "web server")])
        XCTAssertEqual(query.freeText, "foo:bar ssh")
    }

    func testRemovingTakesFirstDuplicateOnly() {
        let token = ResourceListToken(field: .type, value: "a")
        let query = ResourceListQuery(text: "type:a ssh type:a")
        XCTAssertEqual(query.removing(token).text, "ssh type:a")
        XCTAssertEqual(ResourceListQuery(text: "module:x ssh").removing(ResourceListToken(field: .type, value: "a")).text, "module:x ssh")
    }

    func testAddingAndReplacing() {
        let query = ResourceListQuery(text: "type:a ssh module:m")
        XCTAssertEqual(query.adding(ResourceListToken(field: .type, value: "b"), replace: true).text, "type:b ssh module:m")
        XCTAssertEqual(query.adding(ResourceListToken(field: .type, value: "b"), replace: false).text, "type:a ssh module:m type:b")
        XCTAssertEqual(ResourceListQuery().adding(ResourceListToken(field: .name, value: "a b"), replace: true).text, #"name:"a b""#)
        XCTAssertTrue(ResourceListQuery().isEmpty)
    }

    func testGlobs() {
        let rows = [row("a", type: "aws_security_group"), row("b", type: "aws_instance"), row("c", type: "google_instance")]
        func types(_ text: String) -> [String] { ResourceListFilter.apply(ResourceListQuery(text: text), to: rows).map(\.address) }
        XCTAssertEqual(types("type:aws_*"), ["a", "b"])
        XCTAssertEqual(types("type:*_instance"), ["b", "c"])
        XCTAssertEqual(types("type:aws_*_group"), ["a"])
        XCTAssertEqual(types("type:AWS_INSTANCE"), ["b"])
        XCTAssertEqual(types("type:aws_inst"), [])
    }

    func testStatusChangedAndDriftedAndTag() {
        let rows = [row("a", status: "new"), row("b", status: "drifted"), row("c", status: "unchanged"), row("d", status: "remove")]
        func hits(_ text: String) -> [String] { ResourceListFilter.apply(ResourceListQuery(text: text), to: rows).map(\.address) }
        XCTAssertEqual(hits("status:changed"), ["a", "d"])
        XCTAssertEqual(hits("status:drifted"), ["b"])
        XCTAssertEqual(hits("tag:prod"), [])
    }

    func testFreeWordsAndAcrossFields() {
        let rows = [
            row("module.edge.aws_security_group.ssh", module: "edge", name: "ssh"),
            row("aws_security_group.web", name: "web"),
        ]
        func hits(_ text: String) -> Int { ResourceListFilter.apply(ResourceListQuery(text: text), to: rows).count }
        XCTAssertEqual(hits("SSH edge"), 1)
        XCTAssertEqual(hits("security zzz"), 0)
        XCTAssertEqual(hits("security"), 2)
        XCTAssertEqual(hits("module:edge ssh"), 1)
        XCTAssertEqual(hits("module:root"), 1)
    }

    func testSuggestionsSortedUnique() {
        let rows = [row("a", type: "b_x"), row("b", type: "a_x"), row("c", type: "b_x"), row("d", type: "c_x", kind: "")]
        XCTAssertEqual(ResourceListFilter.suggestions(for: .type, in: rows), ["a_x", "b_x", "c_x"])
        XCTAssertEqual(ResourceListFilter.suggestions(for: .kind, in: rows), [])
    }

    func testAddressesText() {
        XCTAssertEqual(ResourceListFilter.addressesText([row("a.b"), row("c.d")]), "a.b\nc.d")
    }

    func testBuilder() {
        let resources = [
            MapDisplayResource(address: "module.edge.module.rules.aws_security_group.ssh", type: "aws_security_group",
                               displayAttributes: [], providerName: "registry.terraform.io/hashicorp/aws"),
            MapDisplayResource(address: #"module.edge["a.b"].data.google_x.y[0]"#, type: "google_x",
                               displayAttributes: [], providerName: #"provider["registry.terraform.io/hashicorp/google"]"#),
            MapDisplayResource(address: "random_id.z", type: "random_id", displayAttributes: []),
        ]
        let tile = MapTile(id: "module.edge.module.rules.aws_security_group.ssh", title: "Edge firewall", kind: .network,
                           anchors: [], resources: ["module.edge.module.rules.aws_security_group.ssh"])
        let rows = ResourceListBuilder.rows(resources: resources, tiles: [tile],
                                            actions: ["random_id.z": "create", resources[0].address: "delete"],
                                            drifted: [resources[1].address, "random_id.z"])
        XCTAssertEqual(rows[0].module, "edge.rules")
        XCTAssertEqual(rows[0].provider, "aws")
        XCTAssertEqual(rows[0].name, "Edge firewall")
        XCTAssertEqual(rows[0].kind, "Network")
        XCTAssertEqual(rows[0].tileID, tile.id)
        XCTAssertEqual(rows[0].status, "remove")
        XCTAssertEqual(rows[1].module, "edge")
        XCTAssertEqual(rows[1].provider, "google")
        XCTAssertEqual(rows[1].name, "y[0]")
        XCTAssertTrue(rows[1].isDataSource)
        XCTAssertEqual(rows[1].status, "drifted")
        XCTAssertEqual(rows[2].module, "root")
        XCTAssertEqual(rows[2].provider, "random")
        XCTAssertEqual(rows[2].name, "z")
        XCTAssertEqual(rows[2].status, "new")
        XCTAssertNil(rows[2].tileID)
        XCTAssertEqual(rows[2].kind, "")
    }
}


extension ResourceListQueryTests {
    func testMemberNamesCarryTheirRoleWithinATile() {
        XCTAssertEqual(ResourceListBuilder.role(of: "aws_s3_bucket_acl", relativeTo: "aws_s3_bucket"), "acl")
        XCTAssertEqual(ResourceListBuilder.role(of: "aws_s3_bucket_public_access_block", relativeTo: "aws_s3_bucket"), "public access block")
        XCTAssertEqual(ResourceListBuilder.role(of: "aws_route53_record", relativeTo: "aws_acm_certificate"), "route53 record")
        let tile = MapTile(id: "aws_s3_bucket.site", title: "Static Site", kind: .frontDoor,
                           anchors: ["aws_s3_bucket.site"], resources: ["aws_s3_bucket.site", "aws_s3_bucket_acl.site"])
        let rows = ResourceListBuilder.rows(
            resources: [MapDisplayResource(address: "aws_s3_bucket.site", type: "aws_s3_bucket", displayAttributes: []),
                        MapDisplayResource(address: "aws_s3_bucket_acl.site", type: "aws_s3_bucket_acl", displayAttributes: [])],
            tiles: [tile], actions: [:], drifted: [])
        XCTAssertEqual(rows.map(\.name), ["Static Site", "Static Site · acl"])
    }
}
