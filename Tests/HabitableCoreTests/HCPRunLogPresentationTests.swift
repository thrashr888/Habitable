import XCTest
@testable import HabitableCore

final class HCPRunLogPresentationTests: XCTestCase {
    private func planned(_ addr: String, _ action: String) -> String {
        #"{"@level":"info","@message":"\#(addr): Plan to \#(action)","type":"planned_change","change":{"resource":{"addr":"\#(addr)"},"action":"\#(action)"}}"#
    }

    func testMixedLog() {
        let log = [
            "Terraform v1.9.5",
            "Initializing plugins and modules...",
            #"{"@message":"Terraform 1.9.5","type":"version","terraform":"1.9.5","ui":"1.2"}"#,
            planned("aws_s3_bucket.a", "create"),
            planned("aws_instance.b", "replace"),
            planned("aws_iam_role.c", "update"),
            planned("aws_vpc.d", "noop"),
            #"{"@message":"Plan: 2 to add, 1 to change, 1 to destroy.","type":"change_summary","changes":{"add":2,"change":1,"remove":1,"import":0,"operation":"plan"}}"#,
            #"{"@message":"Warning: Deprecated","type":"diagnostic","diagnostic":{"severity":"warning","summary":"Deprecated","detail":"Use x","address":"aws_instance.b"}}"#,
            #"{"@message":"aws_s3_bucket.a: Creating...","type":"apply_start","hook":{"resource":{"addr":"aws_s3_bucket.a"},"action":"create"}}"#,
            #"{"@message":"done","type":"apply_complete","hook":{"resource":{"addr":"aws_s3_bucket.a"},"action":"create","elapsed_seconds":3}}"#,
            #"{"@message":"Outputs: 1","type":"outputs","outputs":{}}"#,
        ].joined(separator: "\n")
        let p = HCPRunLogPresentation.parse(log)
        XCTAssertEqual(p.terraformVersion, "1.9.5")
        XCTAssertEqual(p.unparsedLines, [])
        XCTAssertEqual(p.messages.first, "Initializing plugins and modules...")
        XCTAssertEqual(p.plannedChanges.map(\.address), ["aws_s3_bucket.a", "aws_instance.b", "aws_iam_role.c"])
        XCTAssertEqual(p.replaceCount, 1)
        XCTAssertEqual(p.summary, .init(add: 2, change: 1, remove: 1, import: 0))
        XCTAssertEqual(p.summaryOperation, "plan")
        XCTAssertEqual(p.diagnostics.count, 1)
        XCTAssertEqual(p.diagnostics[0].severity, "warning")
        XCTAssertEqual(p.diagnostics[0].address, "aws_instance.b")
        XCTAssertEqual(p.applyEvents.map(\.outcome), ["started", "complete"])
        XCTAssertEqual(p.applyEvents[1].elapsedSeconds, 3)
        XCTAssertEqual(p.messages, ["Initializing plugins and modules...", "Outputs: 1"])
        XCTAssertEqual(p.rawText, log)
    }

    func testMalformedJsonFallsIntoUnparsed() {
        let p = HCPRunLogPresentation.parse("{\"type\":\"planned_change\", oops}\n{broken\n\n  plain  ")
        XCTAssertEqual(p.unparsedLines, ["{\"type\":\"planned_change\", oops}", "{broken", "plain"])
        XCTAssertTrue(p.plannedChanges.isEmpty)
    }

    func testFramingPrefix() {
        let p = HCPRunLogPresentation.parse("\u{1B}[0m> " + planned("a.b", "delete"))
        XCTAssertEqual(p.plannedChanges, [.init(address: "a.b", action: .Delete)])
        XCTAssertTrue(p.unparsedLines.isEmpty)
    }

    func testRedactedPassthrough() {
        let log = #"{"@message":"token = [redacted]","type":"log"}"# + "\n"
            + #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"Bad [redacted]","detail":"password: [redacted]"}}"#
        let p = HCPRunLogPresentation.parse(log)
        XCTAssertEqual(p.messages, ["token = [redacted]"])
        XCTAssertEqual(p.diagnostics.first?.summary, "Bad [redacted]")
        XCTAssertEqual(p.diagnostics.first?.detail, "password: [redacted]")
        XCTAssertNil(p.summary)
        XCTAssertNil(p.terraformVersion)
        XCTAssertTrue(p.plannedChanges.isEmpty)
    }

    func testAnsiTextFormatLog() {
        let esc = "\u{1B}"
        let log = [
            "Terraform v1.14.9",
            "Initializing provider plugins...",
            "- Installing hashicorp/aws v5.98.0...",
            "\(esc)[31m╷\(esc)[0m\(esc)[0m",
            "\(esc)[31m│\(esc)[0m \(esc)[0m\(esc)[1m\(esc)[31mError: \(esc)[0m\(esc)[0m\(esc)[1mFailed to install provider\(esc)[0m",
            "[31m│[0m [0m",
            "[31m│[0m [0m  with aws_x.y,",
            "[31m│[0m [0mCould not [redacted] the plugin.",
            "[31m╵[0m",
            "Plan: 1 to add, 2 to change, 1 to destroy.",
            "  # aws_a.new will be created",
            "  # aws_b.old will be updated in-place",
            "  # aws_c.big must be replaced",
            "aws_a.new: Creating...",
            "aws_a.new: Still creating... [10s elapsed]",
            "aws_a.new: Creation complete after 2s [id=abc]",
            "Apply complete! Resources: 1 added, 0 changed, 0 destroyed.",
        ].joined(separator: "\n")
        let p = HCPRunLogPresentation.parse(log)
        XCTAssertFalse(p.rawText.contains(esc))
        XCTAssertFalse(p.rawText.contains("[31m"))
        XCTAssertTrue(p.rawText.contains("[id=abc]"))
        XCTAssertFalse(p.unparsedLines.contains { $0.contains(esc) || $0.contains("[0m") })
        XCTAssertEqual(p.terraformVersion, "1.14.9")
        XCTAssertEqual(p.messages, ["Initializing provider plugins...", "- Installing hashicorp/aws v5.98.0..."])
        XCTAssertEqual(p.diagnostics.count, 1)
        XCTAssertEqual(p.diagnostics[0].severity, "error")
        XCTAssertEqual(p.diagnostics[0].summary, "Failed to install provider")
        XCTAssertEqual(p.diagnostics[0].address, "aws_x.y")
        XCTAssertEqual(p.diagnostics[0].detail, "Could not [redacted] the plugin.")
        XCTAssertEqual(p.plannedChanges.map(\.action), [.Create, .Update, .Replace])
        XCTAssertEqual(p.replaceCount, 1)
        XCTAssertEqual(p.summary, .init(add: 1, change: 0, remove: 0, import: 0))
        XCTAssertEqual(p.summaryOperation, "apply")
        XCTAssertEqual(p.applyEvents.map(\.outcome), ["started", "progress", "complete"])
        XCTAssertEqual(p.applyEvents.map(\.elapsedSeconds), [nil, 10, 2])
        XCTAssertTrue(p.unparsedLines.isEmpty)
    }

    func testTextPlanSummaryAndNoChanges() {
        XCTAssertEqual(HCPRunLogPresentation.parse("Plan: 1 to import, 2 to add, 0 to change, 1 to destroy.").summary,
                       .init(add: 2, change: 0, remove: 1, import: 1))
        XCTAssertEqual(HCPRunLogPresentation.parse("No changes. Your infrastructure matches the configuration.").summary,
                       .init(add: 0, change: 0, remove: 0, import: 0))
    }
}
