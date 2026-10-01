import XCTest
@testable import HabitableCore

final class CancellationModelTests: XCTestCase {
    @MainActor
    func testCancelKeepsWorkspaceLeaseUntilTerraformCleanupExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable cancel \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("terraform")
        try """
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"fixture"}'; exit 0 ;;
          plan)
            trap 'echo cleanup-started; /bin/sleep 0.4; echo cleanup-finished; exit 0' INT
            echo started
            while :; do /bin/sleep 0.05; done
            ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
        let workspace = Workspace(restoreLastDirectory: false,
                                  historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
                                  commandCoordinator: coordinator)
        workspace.runner = Runner(executableURL: cli)
        workspace.workingDirectory = root
        let run = TerraformRun(workspace: workspace)
        let finished = expectation(description: "Canceled command completed")
        run.doPlan { _, _ in finished.fulfill() }
        try await waitUntil { run.textOutput?.contains("started") == true }
        run.cancel()
        XCTAssertTrue(run.isCanceling)
        XCTAssertTrue(workspace.locked)
        try await waitUntil { run.textOutput?.contains("cleanup-started") == true }
        XCTAssertTrue(workspace.locked, "A graceful stop must retain the lease during cleanup")
        XCTAssertThrowsError(try coordinator.acquire(workspace: root, contextIdentity: workspace.executionContextIdentifier))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(workspace.locked)
        XCTAssertFalse(run.canCancel)
        XCTAssertEqual(run.status, .canceled)
        XCTAssertTrue(run.textOutput?.contains("cleanup-finished") == true)
        let available = try coordinator.acquire(workspace: root, contextIdentity: workspace.executionContextIdentifier)
        available.release()
    }

    @MainActor
    func testInitializeStreamsAndCanBeCanceledWithoutStartingValidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable init cancel \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("terraform")
        try """
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"fixture"}'; exit 0 ;;
          init)
            trap 'echo stopped; exit 0' INT
            echo initializing
            while :; do /bin/sleep 0.05; done
            ;;
          validate) touch validate-started ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let workspace = Workspace(restoreLastDirectory: false,
                                  historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
                                  commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")))
        workspace.runner = Runner(executableURL: cli)
        workspace.workingDirectory = root
        workspace.initialize()
        try await waitUntil { workspace.textOutput?.contains("initializing") == true }
        workspace.cancelCommand()
        XCTAssertTrue(workspace.locked)
        try await waitUntil { !workspace.locked }
        XCTAssertFalse(workspace.canCancelCommand)
        XCTAssertFalse(workspace.isInitialized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("validate-started").path))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Fixture did not reach the expected state")
    }
}
