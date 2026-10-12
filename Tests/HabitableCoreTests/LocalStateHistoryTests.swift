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

    func testRecordingDropsSensitiveValues() throws {
        let show = """
        {"values":{"outputs":{"secret":{"sensitive":true,"value":"hunter2"},"plain":{"sensitive":false,"value":"ok"}},
         "root_module":{"resources":[{"address":"aws_db_instance.main","type":"aws_db_instance","name":"main",
           "values":{"password":"hunter2","engine":"postgres","tags":{"token":"abc","team":"x"}},
           "sensitive_values":{"password":true,"tags":{"token":true}}}],
          "child_modules":[{"resources":[{"address":"module.x.aws_secret.s","values":{"string":"s3cr3t"},"sensitive_values":{"string":true}}]}]}}}
        """
        let scrubbed = String(decoding: LocalStateHistory.redacted(Data(show.utf8)), as: UTF8.self)
        XCTAssertFalse(scrubbed.contains("hunter2"))
        XCTAssertFalse(scrubbed.contains("s3cr3t"))
        XCTAssertFalse(scrubbed.contains("\"abc\""))
        XCTAssertTrue(scrubbed.contains("postgres"))
        XCTAssertTrue(scrubbed.contains("\"team\":\"x\""))
        XCTAssertTrue(scrubbed.contains("\"plain\""))
    }
}
