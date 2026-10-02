import XCTest
import Combine
import SwiftyJSON
@testable import HabitableCore

final class LiveStructuredLogTests: XCTestCase {
    @MainActor
    func testUnchangedHCPPlanCannotBeAppliedButOutputChangesCan() {
        let workspace = Workspace(restoreLastDirectory: false)
        workspace.backendIdentity = "cloud #123"
        let run = TerraformRun(workspace: workspace)
        run.status = .planned
        run.planDiff = TerraformPlan(resourceChanges: [], outputChanges: [])
        XCTAssertTrue(run.isUnchangedHCPPlan)
        XCTAssertFalse(run.canConfirm)
        run.planDiff = TerraformPlan(resourceChanges: [], outputChanges: [
            PlanOutputChange(name: "message", action: "update", attributes: [])
        ])
        XCTAssertFalse(run.isUnchangedHCPPlan)
        XCTAssertTrue(run.canConfirm)
        workspace.backendIdentity = "local"
        let local = TerraformRun(workspace: workspace)
        local.status = .planned
        local.planDiff = TerraformPlan(resourceChanges: [], outputChanges: [])
        XCTAssertTrue(local.canConfirm)
    }
    func testRemotePlainTextPreambleStripsTerminalFormatting() {
        let events = parseNDJsonOutput("\u{001B}[0m\u{001B}[33mRunning plan in HCP Terraform.\u{001B}[0m\n")
        XCTAssertEqual(events.first?["@message"].string, "Running plan in HCP Terraform.")
    }
    @MainActor
    func testDecoderFramesPartialAndMultipleEventsAndFlushesFinalLine() throws {
        let decoder = NDJSONStreamDecoder()
        XCTAssertTrue(decoder.append(#"{"type":"version","terraform":"1.16"}"#).isEmpty)
        let events = decoder.append("\n{\"type\":\"diagnostic\",\"@message\":\"bad\"}")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"].string, "version")
        XCTAssertEqual(decoder.finish().first?["type"].string, "diagnostic")
        XCTAssertTrue(decoder.finish().isEmpty)
    }

    @MainActor
    func testIncrementalEventsUpdateResourcesDiagnosticsSummaryAndUnknownFallback() throws {
        let log = StructuredLog()
        let planned = JSON(parseJSON: #"{"type":"planned_change","change":{"resource":{"addr":"terraform_data.example","resource_type":"terraform_data","resource_name":"example"},"action":"create"}}"#)
        consumeTerraformEvent(planned, into: log)
        XCTAssertEqual(log.resources.count, 1)
        XCTAssertEqual(log.resources[0].address, "terraform_data.example")

        var resourceUpdates = 0
        let observation = log.resources[0].objectWillChange.sink { resourceUpdates += 1 }
        defer { observation.cancel() }

        let started = JSON(parseJSON: #"{"type":"apply_start","hook":{"action":"create","resource":{"addr":"terraform_data.example","resource_type":"terraform_data","resource_name":"example"}}}"#)
        consumeTerraformEvent(started, into: log)
        XCTAssertEqual(log.resources[0].stages.last?.state, .Creating)
        XCTAssertGreaterThan(resourceUpdates, 0, "Live resource rows must receive hook updates")

        let summary = JSON(parseJSON: #"{"type":"change_summary","changes":{"add":1,"change":0,"remove":0}}"#)
        consumeTerraformEvent(summary, into: log)
        XCTAssertEqual(log.changeSummaries.last?.changes.add, 1)

        let diagnostic = JSON(parseJSON: #"{"type":"diagnostic","@message":"invalid config","diagnostic":{"severity":"error","summary":"Invalid configuration","detail":"Fix the setting."}}"#)
        consumeTerraformEvent(diagnostic, into: log)
        XCTAssertEqual(log.diagnostics.last?.diagnostic.summary, "Invalid configuration")

        consumeTerraformEvent(JSON(parseJSON: #"{"type":"future_event","value":true}"#), into: log)
        XCTAssertTrue(try XCTUnwrap(log.logs.last?.message).contains("future_event"))
    }

    @MainActor
    func testOversizedPartialRecordIsDiscardedWithReadableFallback() {
        let decoder = NDJSONStreamDecoder(maximumLineBytes: 8)
        XCTAssertTrue(decoder.append("123456789").isEmpty)
        let event = decoder.append("remaining\n").first
        XCTAssertTrue(event?["@message"].string?.contains("line exceeded") == true)
        XCTAssertTrue(decoder.finish().isEmpty)
    }

    @MainActor
    func testRollingRetentionKeepsLateCompletionAndDiagnosticAfterManyEvents() throws {
        let log = StructuredLog()
        for index in 0..<1_100 {
            consumeTerraformEvent(JSON(["type": "log", "@message": "event \(index)"]), into: log)
        }
        XCTAssertEqual(log.logs.count, 200)
        XCTAssertEqual(log.logs.last?.message, "event 1099")

        let address = "terraform_data.late"
        consumeTerraformEvent(JSON(parseJSON: #"{"type":"planned_change","change":{"resource":{"addr":"terraform_data.late","resource_type":"terraform_data","resource_name":"late"},"action":"create"}}"#), into: log)
        for _ in 0..<10 {
            consumeTerraformEvent(JSON(parseJSON: #"{"type":"apply_start","hook":{"action":"create","resource":{"addr":"terraform_data.late","resource_type":"terraform_data","resource_name":"late"}}}"#), into: log)
        }
        let complete = JSON(parseJSON: #"{"type":"apply_complete","hook":{"action":"create","resource":{"addr":"terraform_data.late","resource_type":"terraform_data","resource_name":"late"}}}"#)
        consumeTerraformEvent(complete, into: log)
        let diagnostic = JSON(parseJSON: #"{"type":"diagnostic","@message":"late failure","diagnostic":{"severity":"error","summary":"Apply failed","detail":"Provider rejected the request."}}"#)
        consumeTerraformEvent(diagnostic, into: log)

        let resource = try XCTUnwrap(log.resources.first(where: { $0.address == address }))
        XCTAssertEqual(resource.stages.count, 8)
        XCTAssertEqual(resource.stages.last?.state, .Created)
        XCTAssertEqual(log.diagnostics.last?.diagnostic.summary, "Apply failed")
    }
}
