import XCTest
@testable import HabitableCore

@MainActor
final class ExternalEditorStoreTests: XCTestCase {
    func testDiscoveryAndRememberedSelection() {
        let suite = "HabitableEditorTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolve: (String) -> URL? = { id in
            ["com.microsoft.VSCode", "com.sublimetext.4"].contains(id)
                ? URL(fileURLWithPath: "/Applications/\(id).app") : nil
        }
        let store = ExternalEditorStore(defaults: defaults, resolve: resolve)
        store.refresh()
        XCTAssertEqual(store.editors.count, 2)
        XCTAssertEqual(store.selected?.name, "Visual Studio Code")
        store.select(store.editors[1])
        let reopened = ExternalEditorStore(defaults: defaults, resolve: resolve)
        reopened.refresh()
        XCTAssertEqual(reopened.selected?.name, "Sublime Text")
        let removed = ExternalEditorStore(defaults: defaults, resolve: { _ in nil })
        removed.refresh()
        XCTAssertNil(removed.selected)
        XCTAssertEqual(removed.selectedID, "com.sublimetext.4")
    }
}
