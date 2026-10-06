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

        let model = LibraryModel(cacheURL: nil)
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
        let model = LibraryModel(cacheURL: nil)
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
        let model = LibraryModel(cacheURL: nil)
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertNil(model.summaries[entry.id])
        XCTAssertNil(model.failures[entry.id])
    }

    func testUnreadableStateReportsFailure() async throws {
        let dir = try folder("broken")
        try "not json".write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let model = LibraryModel(cacheURL: nil)
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertNil(model.summaries[entry.id])
        XCTAssertEqual(model.failures[entry.id], "State file couldn’t be read.")
    }

    func testNeedsCloudReload() {
        let map = ResourceMap(tiles: [], connections: [], dataSources: [])
        let cached = LibraryModel.summary(for: map, recordedAt: nil, serial: nil, versionID: "sv-1")
        XCTAssertFalse(LibraryModel.needsCloudReload(cached: cached, currentVersionID: "sv-1"))
        XCTAssertTrue(LibraryModel.needsCloudReload(cached: cached, currentVersionID: "sv-2"))
        XCTAssertTrue(LibraryModel.needsCloudReload(cached: nil, currentVersionID: "sv-1"))
        XCTAssertFalse(LibraryModel.needsCloudReload(cached: nil, currentVersionID: nil))
    }

    func testLocalRereadsWhenModificationDateChanges() async throws {
        let dir = try folder("changing")
        let file = dir.appendingPathComponent("terraform.tfstate")
        try state.write(to: file, atomically: true, encoding: .utf8)
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
        let model = LibraryModel(cacheURL: nil)
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertEqual(model.summaries[entry.id]?.serial, 7)

        // Same modification date: cached summary is kept even though content differs.
        try state.replacingOccurrences(of: "\"serial\":7", with: "\"serial\":8").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertEqual(model.summaries[entry.id]?.serial, 7)

        // Changed modification date: re-read.
        try FileManager.default.setAttributes([.modificationDate: original.addingTimeInterval(60)], ofItemAtPath: file.path)
        await model.loadSummary(for: entry, cloud: nil)
        XCTAssertEqual(model.summaries[entry.id]?.serial, 8)
    }

    func testRefreshAllLoadsLocalEntriesAndStamps() async throws {
        let dir = try folder("all")
        try state.write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let model = LibraryModel(cacheURL: nil)
        await model.refreshLocal(folders: [dir])
        XCTAssertNil(model.lastRefresh)
        await model.refreshAll(model.localEntries, cloud: nil)
        XCTAssertEqual(model.summaries.values.first?.resourceCount, 2)
        XCTAssertNotNil(model.lastRefresh)
        XCTAssertTrue(model.loading.isEmpty)
    }

    // MARK: Cache

    private func sampleSummary(versionID: String? = "sv-1") -> LibraryStateSummary {
        LibraryStateSummary(resourceCount: 5, groupCount: 3, dataSourceCount: 1,
                            kindCounts: [.data: 2, .network: 1], recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            serial: 9, versionID: versionID)
    }

    private func cacheURL() -> URL { root.appendingPathComponent("cache/library-summaries.json") }

    func testCacheRoundTripRestoresSummaries() async throws {
        let url = cacheURL()
        let dir = try folder("rt")
        try state.write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let model = LibraryModel(cacheURL: url)
        XCTAssertTrue(model.cacheRestored)
        XCTAssertTrue(model.summaries.isEmpty)
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        await model.flushCache()
        let expected = try XCTUnwrap(model.summaries[entry.id])

        let restored = LibraryModel(cacheURL: url)
        XCTAssertTrue(restored.cacheRestored)
        XCTAssertEqual(restored.summaries[entry.id], expected)
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertTrue(restored.loading.isEmpty)

        let cloud = LibraryModel(cacheURL: url)
        XCTAssertEqual(cloud.summaries.count, 1)
    }

    func testCacheRestoresKindCountsAndVersionID() throws {
        let url = cacheURL()
        let summary = sampleSummary()
        let file = LibraryCacheFile(entries: [LibraryCacheEntry(id: "cloud:h/o/ws-1", savedAt: Date(), summary: summary)])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url)
        let model = LibraryModel(cacheURL: url)
        let restored = try XCTUnwrap(model.summaries["cloud:h/o/ws-1"])
        XCTAssertEqual(restored.kindCounts, [.data: 2, .network: 1])
        XCTAssertEqual(restored.versionID, "sv-1")
        XCTAssertEqual(restored, summary)
        // Version skip still works against a restored cloud summary.
        XCTAssertFalse(LibraryModel.needsCloudReload(cached: restored, currentVersionID: "sv-1"))
        XCTAssertTrue(LibraryModel.needsCloudReload(cached: restored, currentVersionID: "sv-2"))
    }

    func testCacheDropsEntriesOlderThanThirtyDays() throws {
        let url = cacheURL()
        let file = LibraryCacheFile(entries: [
            LibraryCacheEntry(id: "old", savedAt: Date().addingTimeInterval(-31 * 86_400), summary: sampleSummary()),
            LibraryCacheEntry(id: "fresh", savedAt: Date().addingTimeInterval(-29 * 86_400), summary: sampleSummary()),
        ])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url)
        let model = LibraryModel(cacheURL: url)
        XCTAssertNil(model.summaries["old"])
        XCTAssertNotNil(model.summaries["fresh"])
    }

    func testUnreadableCacheIsIgnored() throws {
        let url = cacheURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let model = LibraryModel(cacheURL: url)
        XCTAssertTrue(model.cacheRestored)
        XCTAssertTrue(model.summaries.isEmpty)

        let oversized = root.appendingPathComponent("big.json")
        try Data(count: LibraryModel.maximumCacheBytes + 1).write(to: oversized)
        XCTAssertTrue(LibraryModel(cacheURL: oversized).summaries.isEmpty)
    }

    func testCacheContainsOnlySummaryFields() async throws {
        let url = cacheURL()
        let dir = try folder("secretname")
        try state.write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let model = LibraryModel(cacheURL: url)
        await model.refreshLocal(folders: [dir])
        let entry = try XCTUnwrap(model.localEntries.first)
        await model.loadSummary(for: entry, cloud: nil)
        await model.flushCache()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("aws_s3_bucket"))
        XCTAssertFalse(text.contains("failures"))
    }
}
