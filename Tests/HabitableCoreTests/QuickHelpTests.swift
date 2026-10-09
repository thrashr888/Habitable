import Foundation
import XCTest
@testable import HabitableCore

@MainActor
final class QuickHelpTests: XCTestCase {
    private let ids = [
        "output", "variable", "state", "plan", "apply", "replace", "remove", "data-source",
        "module", "provider", "workspace", "tile", "band", "drift", "run", "speculative-plan",
        "auto-apply", "lock", "configuration-version", "pull-request", "sensitive", "backend",
        "checkout",
    ]

    func testGlossaryCoversEveryIdWithSentences() {
        for id in ids {
            guard let entry = QuickHelpGlossary.entry(id) else { return XCTFail("missing \(id)") }
            XCTAssertFalse(entry.title.isEmpty, id)
            XCTAssertFalse(entry.text.isEmpty, id)
            XCTAssertTrue(entry.text.hasSuffix("."), id)
            XCTAssertFalse(entry.text.contains("!"), id)
        }
        XCTAssertNil(QuickHelpGlossary.entry("nope"))
    }

    func testLearnMoreURLsAreHTTPSOnHashiCorpDocs() {
        for (id, entry) in QuickHelpGlossary.all {
            guard let url = entry.learnMoreURL else { continue }
            XCTAssertEqual(url.scheme, "https", id)
            XCTAssertEqual(url.host, "developer.hashicorp.com", id)
        }
    }

    func testClearOnlyClearsMatchingEntry() {
        let model = QuickHelpModel(defaults: UserDefaults(suiteName: "qh-\(UUID())")!)
        let a = QuickHelpEntry(title: "A", text: "a.")
        let b = QuickHelpEntry(title: "B", text: "b.")
        model.show(a)
        model.show(b)
        model.clear(a)
        XCTAssertEqual(model.current, b)
        model.clear(b)
        XCTAssertNil(model.current)
    }

    func testIsEnabledPersists() {
        let name = "qh-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(QuickHelpModel(defaults: defaults).isEnabled)
        QuickHelpModel(defaults: defaults).isEnabled = true
        XCTAssertTrue(defaults.bool(forKey: QuickHelpModel.enabledKey))
        XCTAssertTrue(QuickHelpModel(defaults: defaults).isEnabled)
    }
}
