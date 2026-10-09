import XCTest
@testable import HabitableCore

final class RecentWorkspaceTests: XCTestCase {
    @MainActor
    func testRecentFoldersAreCanonicalDeduplicatedBoundedAndClearable() throws {
        let suite = "RecentWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentWorkspaceStore(defaults: defaults)

        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let first = base.appendingPathComponent("one", isDirectory: true)
        let second = base.appendingPathComponent("two", isDirectory: true)
        store.recordSuccessfulOpen(first)
        store.recordSuccessfulOpen(second)
        store.recordSuccessfulOpen(base.appendingPathComponent("folder/../one", isDirectory: true))

        XCTAssertEqual(store.paths.first, RecentWorkspaceStore.canonicalPath(first))
        XCTAssertEqual(store.paths.count, 2)
        XCTAssertEqual(defaults.stringArray(forKey: RecentWorkspaceStore.defaultsKey), store.paths)

        for index in 0..<(RecentWorkspaceStore.maximumCount + 3) {
            store.recordSuccessfulOpen(base.appendingPathComponent("folder-\(index)", isDirectory: true))
        }
        XCTAssertEqual(store.paths.count, RecentWorkspaceStore.maximumCount)
        XCTAssertEqual(store.folders.first?.lastPathComponent, "folder-\(RecentWorkspaceStore.maximumCount + 2)")

        store.clear()
        XCTAssertTrue(store.paths.isEmpty)
        XCTAssertNil(defaults.object(forKey: RecentWorkspaceStore.defaultsKey))
    }

    @MainActor
    func testInitializationNormalizesDuplicatePersistedPaths() throws {
        let suite = "RecentWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = root.appendingPathComponent("existing", isDirectory: true)
        defaults.set([folder.path, root.appendingPathComponent("x/../existing").path],
                     forKey: RecentWorkspaceStore.defaultsKey)

        let store = RecentWorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.paths, [RecentWorkspaceStore.canonicalPath(folder)])
    }

    @MainActor
    func testStaleWindowStoreMergesLatestPersistedRecentsBeforeRecording() throws {
        let suite = "RecentWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstWindow = RecentWorkspaceStore(defaults: defaults)
        let secondWindow = RecentWorkspaceStore(defaults: defaults)
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let first = root.appendingPathComponent("window-one", isDirectory: true)
        let second = root.appendingPathComponent("window-two", isDirectory: true)

        firstWindow.recordSuccessfulOpen(first)
        secondWindow.recordSuccessfulOpen(second)

        XCTAssertEqual(secondWindow.paths, [RecentWorkspaceStore.canonicalPath(second),
                                            RecentWorkspaceStore.canonicalPath(first)])
        XCTAssertEqual(defaults.stringArray(forKey: RecentWorkspaceStore.defaultsKey), secondWindow.paths)
    }
    @MainActor
    func testRecordingAfterAnotherWindowClearsDoesNotReviveOldPaths() throws {
        let suite = "RecentWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RecentWorkspaceStore(defaults: defaults)
        first.recordSuccessfulOpen(URL(fileURLWithPath: "/tmp/old"))
        let second = RecentWorkspaceStore(defaults: defaults)
        second.clear()
        first.recordSuccessfulOpen(URL(fileURLWithPath: "/tmp/new"))
        XCTAssertEqual(first.paths, [RecentWorkspaceStore.canonicalPath(URL(fileURLWithPath: "/tmp/new"))])
    }

}

extension RecentWorkspaceTests {
    @MainActor
    func testForgetRemovesOneFolderAndLeavesTheRest() throws {
        let suite = "RecentWorkspaceTests.forget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentWorkspaceStore(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/habitable-a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/habitable-b", isDirectory: true)
        store.recordSuccessfulOpen(a)
        store.recordSuccessfulOpen(b)
        store.forget(a)
        XCTAssertEqual(store.folders.map(\.lastPathComponent), ["habitable-b"])
        XCTAssertEqual(defaults.stringArray(forKey: RecentWorkspaceStore.defaultsKey)?.count, 1)
    }
}
