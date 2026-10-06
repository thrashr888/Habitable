import XCTest
@testable import HabitableCore

final class MapChangePreviewTests: XCTestCase {
    private func state(_ type: String, _ name: String) -> MapResource {
        MapResource(address: "\(type).\(name)", type: type, name: name)
    }

    private func change(_ address: String, _ action: String, order: [String] = []) -> PlanResourceChange {
        PlanResourceChange(address: address, action: action, attributes: [], replacementPaths: [], actionOrder: order)
    }

    private func plan(_ changes: [PlanResourceChange]) -> TerraformPlan {
        TerraformPlan(resourceChanges: changes, outputChanges: [])
    }

    func testParse() {
        let nested = MapChangePreview.parse(address: #"module.a.module.b.aws_x.y["k.z"]"#)
        XCTAssertEqual(nested?.type, "aws_x")
        XCTAssertEqual(nested?.name, "y")
        XCTAssertEqual(nested?.module, "module.a.module.b")
        XCTAssertEqual(nested?.isData, false)
        let data = MapChangePreview.parse(address: "data.aws_x.y")
        XCTAssertEqual(data?.type, "aws_x")
        XCTAssertEqual(data?.isData, true)
        let plain = MapChangePreview.parse(address: "aws_x.y[0]")
        XCTAssertEqual(plain?.name, "y")
        XCTAssertEqual(plain?.module, "")
        XCTAssertNil(MapChangePreview.parse(address: "output_name"))
    }

    func testActionOrdering() {
        XCTAssertLessThan(MapChangeAction.none, .read)
        XCTAssertLessThan(MapChangeAction.create, .update)
        XCTAssertLessThan(MapChangeAction.update, .replace)
        XCTAssertLessThan(MapChangeAction.replace, .delete)
    }

    func testCreateAppearsInMapAndIsNewOrJoined() throws {
        let site = state("aws_s3_bucket", "site")
        let preview = try MapChangePreview.build(
            plan: plan([change("aws_s3_bucket.uploads", "create")]), stateResources: [site])
        let tile = try XCTUnwrap(preview.map.tiles.first { $0.resources.contains("aws_s3_bucket.uploads") })
        XCTAssertEqual(preview.tileActions[tile.id], .create)
        XCTAssertEqual(preview.newTileIDs.contains(tile.id), !tile.resources.contains(site.address))
        XCTAssertEqual(preview.resourceActions["aws_s3_bucket.uploads"], .create)
        XCTAssertEqual(preview.consequences.create, 1)
    }

    func testUpdateReplaceAndDeleteStayOnTheirTiles() throws {
        let a = state("aws_s3_bucket", "alpha")
        let b = state("aws_sqs_queue", "beta")
        let c = state("aws_lambda_function", "gamma")
        let d = state("aws_db_instance", "delta")
        let preview = try MapChangePreview.build(
            plan: plan([change(a.address, "update"),
                        change(b.address, "replace", order: ["delete", "create"]),
                        change(c.address, "delete"),
                        change("aws_s3_bucket.untouched", "no-op")]),
            stateResources: [a, b, c, d])
        func action(_ r: MapResource) -> MapChangeAction? {
            preview.map.tiles.first { $0.resources.contains(r.address) }.flatMap { preview.tileActions[$0.id] }
        }
        XCTAssertEqual(action(a), .update)
        XCTAssertEqual(action(b), .replace)
        XCTAssertEqual(action(c), .delete)
        XCTAssertEqual(action(d), MapChangeAction.none)
        XCTAssertTrue(preview.newTileIDs.isEmpty)
        XCTAssertEqual(preview.consequences, plan([change(a.address, "update"),
            change(b.address, "replace", order: ["delete", "create"]), change(c.address, "delete"),
            change("aws_s3_bucket.untouched", "no-op")]).consequences)
        XCTAssertEqual(preview.changedTileCount, 3)
        XCTAssertEqual(preview.unchangedTileCount, 1)
    }

    func testReplaceOutranksUpdateInSameTile() throws {
        let bucket = state("aws_s3_bucket", "site")
        let versioning = MapResource(address: "aws_s3_bucket_versioning.site", type: "aws_s3_bucket_versioning",
                                     name: "site", dependencies: [bucket.address])
        let preview = try MapChangePreview.build(
            plan: plan([change(bucket.address, "update"),
                        change(versioning.address, "replace", order: ["create", "delete"])]),
            stateResources: [bucket, versioning])
        XCTAssertEqual(preview.map.tiles.count, 1)
        XCTAssertEqual(preview.tileActions[preview.map.tiles[0].id], .replace)
    }

    func testCurrentMapKeepsTilesAndAppendsNewOnes() throws {
        let tileA = MapTile(id: "aws_s3_bucket.alpha", title: "Alpha", kind: .data,
                            anchors: ["aws_s3_bucket.alpha"], resources: ["aws_s3_bucket.alpha"])
        let tileB = MapTile(id: "aws_lambda_function.beta", title: "Beta", kind: .appsAndAI,
                            anchors: ["aws_lambda_function.beta"],
                            resources: ["aws_iam_role.beta", "aws_lambda_function.beta"])
        let current = ResourceMap(tiles: [tileA, tileB], connections: [], dataSources: [])
        let preview = try MapChangePreview.build(
            plan: plan([change("aws_s3_bucket.alpha", "update"),
                        change("aws_iam_role.beta", "replace", order: ["delete", "create"]),
                        change("aws_sqs_queue.jobs", "create")]),
            currentMap: current)
        XCTAssertEqual(Array(preview.map.tiles.prefix(2)), [tileA, tileB])
        XCTAssertEqual(preview.map.tiles.count, 3)
        XCTAssertEqual(preview.tileActions[tileA.id], .update)
        XCTAssertEqual(preview.tileActions[tileB.id], .replace)
        XCTAssertEqual(preview.newTileIDs, ["aws_sqs_queue.jobs"])
        XCTAssertEqual(preview.tileActions["aws_sqs_queue.jobs"], .create)
        XCTAssertEqual(preview.changedTileCount, 3)
        XCTAssertEqual(preview.unchangedTileCount, 0)
    }
}
