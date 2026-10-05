import XCTest
import SwiftyJSON
@testable import HabitableCore

final class RunPresentationTests: XCTestCase {
    func testApplyConsequencesSeparateReplacementAndIncludeOutputOnlyPlans() {
        let plan = transformPlan(JSON(parseJSON: #"{"resource_changes":[{"address":"terraform_data.a","change":{"actions":["delete","create"]}},{"address":"terraform_data.b","change":{"actions":["delete"]}},{"address":"terraform_data.c","change":{"actions":["no-op"],"importing":{"id":"fixture"}}}],"output_changes":{"result":{"actions":["update"],"before":"a","after":"b","before_sensitive":false,"after_sensitive":false}}}"#))
        let counts = plan.consequences
        XCTAssertEqual(counts.replace, 1)
        XCTAssertEqual(counts.destroy, 1)
        XCTAssertEqual(counts.create, 0)
        XCTAssertEqual(counts.imports, 1)
        XCTAssertEqual(counts.outputs, 1)
        XCTAssertTrue(counts.summary.contains("1 to replace"))
        let outputOnly = TerraformPlan(resourceChanges: [], outputChanges: plan.outputChanges).consequences
        XCTAssertEqual(outputOnly.summary, "No resource changes · 1 output to change")
    }

    func testResourceChangeReviewExplainsOutputOnlyAndFilteredEmptyPlans() {
        XCTAssertEqual(planResourceChangesEmptyMessage(hasVisibleChanges: false,
                                                       hasAddressFilter: false,
                                                       hasOperationFilter: false),
                       "No resource changes in this plan.")
        XCTAssertEqual(planResourceChangesEmptyMessage(hasVisibleChanges: false,
                                                       hasAddressFilter: true,
                                                       hasOperationFilter: false),
                       "No resources match this filter.")
        XCTAssertNil(planResourceChangesEmptyMessage(hasVisibleChanges: true,
                                                     hasAddressFilter: true,
                                                     hasOperationFilter: true))
    }

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

final class MapTimelinePresentationTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func clip(_ id: String, _ date: Date?, applied: Bool = true,
                      added: Int? = nil, changed: Int? = nil, destroyed: Int? = nil) -> MapChangeClip {
        MapChangeClip(id: id, title: id, date: date, status: applied ? "Applied" : "Planned",
                      isApplied: applied, added: added, changed: changed, destroyed: destroyed, author: nil)
    }

    func testCountsSummaryFormatting() {
        XCTAssertEqual(clip("a", nil, added: 14, changed: 2, destroyed: 1).countsSummary, "+14 ~2 \u{2212}1")
        XCTAssertEqual(clip("a", nil, added: 3, changed: 0, destroyed: nil).countsSummary, "+3")
        XCTAssertEqual(clip("a", nil, added: 0, changed: 0, destroyed: 0).countsSummary, "No changes")
        XCTAssertEqual(clip("a", nil).countsSummary, "")
        XCTAssertFalse(clip("a", nil).hasRecordedCounts)
    }

    func testSummaryWithAndWithoutAppliedClips() {
        let clips = [clip("p", date(9, 1), applied: false), clip("a", date(9, 2)), clip("b", date(9, 9))]
        XCTAssertEqual(MapTimelinePresentation.summary(for: clips, calendar: calendar), "2 applied since Sep 2")
        XCTAssertEqual(MapTimelinePresentation.summary(for: [clips[0]], calendar: calendar), "No applied changes yet")
        XCTAssertEqual(MapTimelinePresentation.summary(for: [], calendar: calendar), "No applied changes yet")
    }

    func testDateGroupsMergeSameDayAndKeepOrder() {
        let clips = [clip("a", date(9, 2, hour: 9)), clip("b", date(9, 2, hour: 17)),
                     clip("c", date(9, 9)), clip("d", nil)]
        let groups = MapTimelinePresentation.dateGroups(for: clips, calendar: calendar)
        XCTAssertEqual(groups.map(\.label), ["Sep 2", "Sep 9", "Undated"])
        XCTAssertEqual(groups.map { $0.clips.map(\.id) }, [["a", "b"], ["c"], ["d"]])
    }
}

