import XCTest
@testable import HabitableCore

@MainActor
final class LibraryModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let state = """
    {"version":4,"terraform_version":"1.9.0","serial":7,"lineage":"x","outputs":{},"resources":[
    {"mode":"managed","type":"aws_s3_bucket","name":"a","provider":"provider[\\"registry.terraform.io/hashicorp/aws\\"]","instances":[{"attributes":{"bucket":"a"}}]},
    {"mode":"managed","type":"aws_vpc","name":"b","provider":"provider[\\"registry.terraform.io/hashicorp/aws\\"]","instances":[{"attributes":{"id":"vpc-1"}}]}]}
    """

    func testSummaryCountsKinds() {
        let map = ResourceMap(tiles: [
            MapTile(id: "a", title: "A", kind: .data, anchors: ["x"], resources: ["x", "y"]),
            MapTile(id: "b", title: "B", kind: .network, anchors: ["z"], resources: ["z"]),
            MapTile(id: "c", title: "C", kind: .data, anchors: ["w"], resources: ["w"]),
        ], connections: [], dataSources: ["d"])
        let date = Date(timeIntervalSince1970: 100)
        let summary = LibraryModel.summary(for: map, recordedAt: date, serial: 3, versionID: "sv-1")
        XCTAssertEqual(summary.resourceCount, 4)
        XCTAssertEqual(summary.groupCount, 3)
        XCTAssertEqual(summary.dataSourceCount, 1)
        XCTAssertEqual(summary.kindCounts, [.data: 2, .network: 1])
        XCTAssertEqual(summary.recordedAt, date)
        XCTAssertEqual(summary.serial, 3)
        XCTAssertEqual(summary.versionID, "sv-1")
    }

    func testCloudEntries() {
        let ws = HCPWorkspace(id: "ws-1", name: "prod", terraformVersion: nil, executionMode: nil, locked: false, htmlURL: nil)
        let entries = LibraryModel.cloudEntries(workspaces: [ws], organization: "acme", hostname: "app.terraform.io")
        XCTAssertEqual(entries.map(\.id), ["cloud:app.terraform.io/acme/ws-1"])
        XCTAssertEqual(entries[0].title, "prod")
        XCTAssertEqual(entries[0].location, "acme · HCP Terraform")
        XCTAssertTrue(entries[0].isCloud)
        XCTAssertFalse(entries[0].isLocal)
    }

    func testRefreshLocalResolvesRemoteAndSkipsMissing() async throws {
        let linked = try folder("linked")
        try FileManager.default.createDirectory(at: linked.appendingPathComponent(".terraform"), withIntermediateDirectories: true)
        let metadata = #"{"backend":{"type":"cloud","config":{"organization":"acme","hostname":"app.terraform.io","workspaces":{"name":"prod"}}}}"#
        try metadata.write(to: linked.appendingPathComponent(".terraform/terraform.tfstate"), atomically: true, encoding: .utf8)
        let plain = try folder("plain")
        let missing = root.appendingPathComponent("missing")

        let model = LibraryModel()
        await model.refreshLocal(folders: [linked, plain, missing, plain])
        XCTAssertEqual(model.localEntries.map(\.title), ["linked", "plain"])
        XCTAssertEqual(model.localEntries[0].id, "local:" + LibraryModel.canonicalPath(linked))
        guard case .localFolder(_, let remote) = model.localEntries[0].kind else { return XCTFail("kind") }
        XCTAssertEqual(remote?.workspaceName, "prod")
        guard case .localFolder(_, let none) = model.localEntries[1].kind else { return XCTFail("kind") }
        XCTAssertNil(none)
    }

    func testHomeAbbreviation() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(LibraryModel.abbreviatedPath(home + "/Workspace/x"), "~/Workspace/x")
        XCTAssertEqual(LibraryModel.abbreviatedPath("/opt/x"), "/opt/x")
    }

    func testLoadSummaryReadsLocalState() async throws {
        let dir = try folder("withstate")
        try state.write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let model = LibraryModel()
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        let summary = try XCTUnwrap(model.summaries[entry.id])
        XCTAssertEqual(summary.resourceCount, 2)
        XCTAssertEqual(summary.serial, 7)
        XCTAssertNotNil(summary.recordedAt)
        XCTAssertNil(summary.versionID)
        XCTAssertNil(model.failures[entry.id])
        XCTAssertTrue(model.loading.isEmpty)
    }

    func testLoadSummaryWithoutStateIsNotAFailure() async throws {
        let dir = try folder("empty")
        let model = LibraryModel()
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertNil(model.summaries[entry.id])
        XCTAssertNil(model.failures[entry.id])
    }

    func testUnreadableStateReportsFailure() async throws {
        let dir = try folder("broken")
        try "not json".write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let model = LibraryModel()
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertNil(model.summaries[entry.id])
        XCTAssertEqual(model.failures[entry.id], "State file couldn’t be read.")
    }
}
