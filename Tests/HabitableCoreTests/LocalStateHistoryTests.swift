import XCTest
@testable import HabitableCore

final class LocalStateHistoryTests: XCTestCase {
    func testRecordsDistinctStatesAndSkipsRepeats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LocalStateHistory(root: root)
        let folder = URL(fileURLWithPath: "/tmp/example-folder")
        XCTAssertNotNil(history.record(folder: folder, data: Data("{\"a\":1}".utf8), resourceCount: 1))
        XCTAssertNil(history.record(folder: folder, data: Data("{\"a\":1}".utf8), resourceCount: 1))
        XCTAssertNotNil(history.record(folder: folder, data: Data("{\"a\":2}".utf8), resourceCount: 2))
        let versions = history.versions(for: folder)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.map(\.resourceCount), [1, 2])
        XCTAssertEqual(history.load(versions[1]), Data("{\"a\":2}".utf8))
        XCTAssertTrue(history.versions(for: URL(fileURLWithPath: "/tmp/other")).isEmpty)
    }
}
