import XCTest
@testable import HabitableCore

final class RunPresentationTests: XCTestCase {
    func testFollowingRunKeepsApplyVisibleAtCompletionAndShowsFailures() {
        XCTAssertEqual(RunDisplayPhase.current(status: .planning, hasApply: false, hasError: false), .plan)
        XCTAssertEqual(RunDisplayPhase.current(status: .confirmed, hasApply: false, hasError: false), .apply)
        XCTAssertEqual(RunDisplayPhase.current(status: .applying, hasApply: true, hasError: false), .apply)
        XCTAssertEqual(RunDisplayPhase.current(status: .applied, hasApply: true, hasError: false), .apply)
        XCTAssertEqual(RunDisplayPhase.current(status: .errored, hasApply: true, hasError: true), .errors)
        XCTAssertEqual(RunDisplayPhase.current(status: .interrupted, hasApply: true, hasError: true), .errors)
    }

    func testManualPlanInspectionSurvivesApplyEventsAndFailureUntilResuming() {
        var selection = RunPhaseSelection()
        selection.receive(.apply)
        XCTAssertEqual(selection.phase, .apply)
        selection.inspect(.plan)
        selection.receive(.apply)
        selection.receive(.errors)
        XCTAssertEqual(selection.phase, .plan)
        XCTAssertFalse(selection.followsLive)
        selection.resume(.errors)
        XCTAssertEqual(selection.phase, .errors)
        XCTAssertTrue(selection.followsLive)
    }

    func testIncomingSectionsRevealOnceAndRespectManualCollapse() {
        var state = LiveRunDisclosureState()
        state.receive([.version, .activity], isLive: true)
        XCTAssertEqual(state.expanded, [.version, .activity])
        state.setExpanded(.activity, false)
        // Further activity must not fight a user's manual collapse.
        state.receive([.version, .activity], isLive: true)
        XCTAssertFalse(state.expanded.contains(.activity))
        state.receive([.version, .activity, .summary, .outputs], isLive: true)
        XCTAssertEqual(state.expanded, [.version, .summary, .outputs])
        state.setExpanded(.outputs, false)
        state.receive([.version, .activity, .summary, .outputs], isLive: false)
        XCTAssertFalse(state.expanded.contains(.outputs))
    }

    func testHistoricalRunDoesNotExpandAllSectionsOnOpen() {
        var state = LiveRunDisclosureState()
        state.receive([.version, .activity, .summary, .outputs], isLive: false)
        XCTAssertTrue(state.expanded.isEmpty)
        state.setExpanded(.outputs, true)
        state.receive([.version, .activity, .summary, .outputs], isLive: false)
        XCTAssertEqual(state.expanded, [.outputs])
    }
}
