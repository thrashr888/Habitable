import Foundation
import MCP
import XCTest
@testable import HabitableCore

final class HabitableAgentAccessTests: XCTestCase {
    @MainActor
    func testGrantRequiresFolderAndPlansStayPlanOnlyAcrossScopeChanges() async throws {
        guard let path = ProcessInfo.processInfo.environment["HABITABLE_TEST_TERRAFORM"] else {
            throw XCTSkip("Set HABITABLE_TEST_TERRAFORM for agent plan policy coverage")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"resource "terraform_data" "example" { input = "local fixture" }"#.write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let suite = "Habitable-agent-scope-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(restoreLastDirectory: false, defaults: defaults,
            historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")),
            descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions")),
            workspaceInputStore: WorkspaceInputStore(root: root.appendingPathComponent("inputs")))
        let access = HabitableAgentAccess()
        access.setEnabled(true, in: workspace)
        XCTAssertNil(access.server)
        XCTAssertFalse(access.isEnabled)
        workspace.runner = Runner(executableURL: URL(fileURLWithPath: path))
        workspace.workingDirectory = root
        workspace.initialize()
        try await waitUntil { !workspace.locked && workspace.isInitialized && workspace.isValid }
        workspace.autoApply = true
        access.setEnabled(true, in: workspace)
        try await waitUntil { access.isEnabled }
        let server = try XCTUnwrap(access.server)
        let endpoint = try XCTUnwrap(server.endpointURL)
        defer { access.setEnabled(false, in: workspace) }
        let token = server.bearerToken
        let modifier: @Sendable (URLRequest) -> URLRequest = { original in
            var request = original
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        let client = Client(name: "HabitableScopeTests", version: "1.0")
        _ = try await client.connect(transport: HTTPClientTransport(endpoint: endpoint, streaming: false, requestModifier: modifier))
        let (reply, _) = try await client.callTool(name: "plan_workspace", arguments: [:])
        guard case .text(let jobReply, _, _) = try XCTUnwrap(reply.first) else { return XCTFail("Expected a job reply") }
        XCTAssertTrue(jobReply.contains("Plan-only job:"))
        try await waitUntil { workspace.runs.first?.status == .planned }
        let run = try XCTUnwrap(workspace.runs.first)
        XCTAssertTrue(run.planOnly)
        XCTAssertEqual(run.triggerSource, "mcp")
        XCTAssertFalse(run.canConfirm)
        XCTAssertNil(run.apply)
        let record = try workspace.historyStore.readPersistedRecord(id: run.id, workspace: root)
        XCTAssertTrue(record.planOnly == true)
        let (statusReply, _) = try await client.callTool(name: "run_status", arguments: ["id": .string(run.id.uuidString)])
        guard case .text(let status, _, _) = try XCTUnwrap(statusReply.first) else { return XCTFail("Expected run status") }
        XCTAssertTrue(status.contains(RunStatus.planned.rawValue))
        workspace.workingDirectory = nil
        let (scopeReply, _) = try await client.callTool(name: "workspace_status", arguments: [:])
        guard case .text(let scope, _, _) = try XCTUnwrap(scopeReply.first) else { return XCTFail("Expected disabled scope") }
        XCTAssertEqual(scope, "Agent access disabled.", "Old callbacks cannot inherit a different folder")
        access.workspaceChanged(in: workspace)
        XCTAssertNil(access.server)
        XCTAssertFalse(access.isEnabled)
        await client.disconnect()
        await server.stop()
        XCTAssertNil(server.endpointURL)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "Timed out waiting for the local fixture")
    }
}
