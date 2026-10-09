import XCTest
@testable import HabitableCore

final class HCPProposalTests: XCTestCase {
    func testStepMapping() {
        XCTAssertEqual(HCPProposal.step(forStatus: "pending"), .planning)
        XCTAssertEqual(HCPProposal.step(forStatus: "planning"), .planning)
        XCTAssertEqual(HCPProposal.step(forStatus: "planned"), .needsConfirmation)
        XCTAssertEqual(HCPProposal.step(forStatus: "policy_checked"), .needsConfirmation)
        XCTAssertEqual(HCPProposal.step(forStatus: "confirmed"), .applying)
        XCTAssertEqual(HCPProposal.step(forStatus: "applying"), .applying)
        XCTAssertEqual(HCPProposal.step(forStatus: "applied"), .applied)
        XCTAssertEqual(HCPProposal.step(forStatus: "discarded"), .discarded)
        if case .errored = HCPProposal.step(forStatus: "errored") {} else { XCTFail("errored") }
        if case .errored = HCPProposal.step(forStatus: "canceled") {} else { XCTFail("canceled") }
    }

    func testPlannedAndFinishedIsAppliedWithNoChanges() {
        let proposal = HCPProposal(runID: "run-1", workspaceID: "ws-1", message: "m", createdAt: Date(),
                                   status: "planned_and_finished", planID: nil, folder: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(proposal.step, .applied)
        XCTAssertTrue(proposal.isPlanOnlyComplete)
    }

    func testRunRequestBodyShape() throws {
        let body = HCPProposal.previewRequestBody(workspaceID: "ws-1", configurationVersionID: "cv-1", message: "Hi", planOnly: false)
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(row["type"] as? String, "runs")
        let attributes = try XCTUnwrap(row["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["message"] as? String, "Hi")
        XCTAssertEqual(attributes["plan-only"] as? Bool, false)
        let relationships = try XCTUnwrap(row["relationships"] as? [String: Any])
        let workspace = try XCTUnwrap((relationships["workspace"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(workspace["id"] as? String, "ws-1")
        XCTAssertEqual(workspace["type"] as? String, "workspaces")
        let version = try XCTUnwrap((relationships["configuration-version"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(version["id"] as? String, "cv-1")
        XCTAssertEqual(version["type"] as? String, "configuration-versions")
    }

    func testArchiveListsConfigAndExcludesNoise() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hcp-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent(".terraform"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "resource \"null_resource\" \"a\" {}".write(to: dir.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".terraform/provider.bin"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("terraform.tfstate.backup"), atomically: true, encoding: .utf8)

        let archive = try ConfigurationArchive.make(folder: dir)
        XCTAssertFalse(archive.isEmpty)
        let file = dir.appendingPathComponent("out.tgz")
        try archive.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertTrue(listing.contains("./main.tf"), listing)
        XCTAssertFalse(listing.contains(".terraform"), listing)
        XCTAssertFalse(listing.contains(".git"), listing)
        XCTAssertFalse(listing.contains("tfstate"), listing)
    }
}

extension HCPProposalTests {
    func testLogTailStripsANSIAndKeepsLastLines() {
        let raw = "\u{1B}[31mError:\u{1B}[0m bad\n[1m[31mUnsupported block type[0m\n\n  on main.tf line 2\n"
        let tail = HCPAPIClient.logTail(raw, lines: 2)
        XCTAssertEqual(tail, "Unsupported block type\non main.tf line 2")
        XCTAssertEqual(HCPAPIClient.stripANSI("a [31mred[0m b"), "a red b")
        XCTAssertEqual(HCPAPIClient.stripANSI("list[0] = x"), "list[0] = x")
    }
}
