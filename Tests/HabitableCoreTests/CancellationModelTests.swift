import XCTest
@testable import HabitableCore

@MainActor
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
        let defaults = UserDefaults(suiteName: "Habitable-cancel-\(UUID().uuidString)")!
        let workspace = Workspace(restoreLastDirectory: false,
                                  defaults: defaults,
                                  historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
                                  commandCoordinator: coordinator,
                                  descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions")))
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
        let defaults = UserDefaults(suiteName: "Habitable-init-cancel-\(UUID().uuidString)")!
        let workspace = Workspace(restoreLastDirectory: false,
                                  defaults: defaults,
                                  historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
                                  commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")),
                                  descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions")))
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
    func testCancelApplyRetainsLeaseThroughCleanupThenRefreshesUnknownOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable apply cancel \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("terraform")
        try #"""
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"fixture"}' ;;
          plan) echo '{"type":"change_summary","changes":{"add":1,"change":0,"remove":0}}' ;;
          show)
            if [ -n "$3" ]; then
              echo '{"format_version":"1.0","resource_changes":[]}'
            else
              echo '{"values":{"root_module":{"resources":[]}}}'
            fi
            ;;
          apply)
            trap 'echo cleanup-started; /bin/sleep 0.25; echo cleanup-finished; exit 130' INT
            echo apply-started
            while :; do /bin/sleep 0.05; done
            ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
        let history = RunHistoryStore(directory: root.appendingPathComponent("history"))
        let suiteName = "Habitable-apply-cancel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(restoreLastDirectory: false, defaults: defaults, historyStore: history,
                                  commandCoordinator: coordinator,
                                  descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions")))
        workspace.runner = Runner(executableURL: cli)
        workspace.workingDirectory = root
        workspace.terraformVersion = "fixture"
        workspace.isValid = true
        let record = try history.create(workspace: root, terraformVersion: "fixture", message: nil)
        let run = TerraformRun(workspace: workspace, record: record, restored: false)
        workspace.runs = [run]

        let planFinished = expectation(description: "plan completes")
        run.doPlan { _, error in
            XCTAssertNil(error)
            planFinished.fulfill()
        }
        await fulfillment(of: [planFinished], timeout: 5)
        XCTAssertEqual(run.status, .planned)

        let applyFinished = expectation(description: "canceled apply completes after cleanup")
        run.doApply { _, _ in applyFinished.fulfill() }
        try await waitUntil { run.textOutput?.contains("apply-started") == true }
        run.cancel()
        try await waitUntil { run.textOutput?.contains("cleanup-started") == true }
        XCTAssertTrue(workspace.locked)
        XCTAssertTrue(workspace.lockedBy === run)
        XCTAssertThrowsError(try coordinator.acquire(workspace: root, contextIdentity: workspace.executionContextIdentifier))

        await fulfillment(of: [applyFinished], timeout: 5)
        try await waitUntil { !workspace.locked }
        XCTAssertEqual(run.status, .canceled)
        XCTAssertFalse(run.canCancel)
        XCTAssertNotNil(workspace.state, "Canceled apply outcome is uncertain, so state must be refreshed")
        XCTAssertTrue(run.textOutput?.contains("cleanup-finished") == true)
        let persisted = try history.readPersistedRecord(id: run.id, workspace: root)
        XCTAssertEqual(persisted.status, .canceled)
        XCTAssertTrue(persisted.applyHistoryOutput?.contains("cleanup-finished") == true)
        let reopened = TerraformRun(workspace: workspace, record: persisted, restored: true)
        XCTAssertEqual(reopened.status, .canceled)
        XCTAssertTrue(reopened.apply?.logs.contains(where: { $0.message?.contains("cleanup-finished") == true }) == true)
        let available = try coordinator.acquire(workspace: root, contextIdentity: workspace.executionContextIdentifier)
        available.release()
    }

    @MainActor
    func testPlanOutputOverflowKeepsLateStreamedDiagnosticVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable plan overflow \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("terraform")
        try #"""
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"fixture"}' ;;
          plan)
            printf '{"type":"version","terraform":"1.16.4","ui":"1.7"}\n'
            i=0
            while [ "$i" -lt 18000 ]; do
              printf '{"type":"log","@message":"filler-%05d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}\n' "$i"
              i=$((i + 1))
            done
            printf '[Earlier live output omitted; consult the completed run events]\n'
            printf '{"type":"diagnostic","diagnostic":{"severity":"error","summary":"Late overflow failure","detail":"This event follows the bounded capture."}}\n'
            printf '\033[31mprovider stderr stream-secret after overflow\033[0m\n' >&2
            exit 1
            ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
        let history = RunHistoryStore(directory: root.appendingPathComponent("history"))
        let suiteName = "Habitable-plan-overflow-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(restoreLastDirectory: false, defaults: defaults, historyStore: history,
                                  commandCoordinator: coordinator,
                                  descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions")))
        workspace.runner = Runner(executableURL: cli)
        workspace.workingDirectory = root
        workspace.terraformVersion = "fixture"
        let secret = TerraformVariable()
        secret.key = "TOKEN"
        secret.value = "stream-secret"
        secret.sensitive = true
        secret.isUserInput = true
        workspace.terraformVariables = [secret]
        let record = try history.create(workspace: root, terraformVersion: "fixture", message: nil)
        let run = TerraformRun(workspace: workspace, record: record, restored: false)
        workspace.runs = [run]

        let finished = expectation(description: "overflow plan fails closed")
        var completionError: String?
        run.doPlan { _, error in
            completionError = error
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(run.status, .errored)
        XCTAssertTrue(completionError?.contains("bounded capture") == true)
        XCTAssertEqual(run.plan?.diagnostics.last?.diagnostic.summary, "Late overflow failure")
        let lateStderr = try XCTUnwrap(run.plan?.logs.first(where: { $0.message?.contains("provider stderr") == true })?.message)
        XCTAssertFalse(lateStderr.contains("\u{001B}"), "Live diagnostics must not expose terminal control codes")
        XCTAssertTrue(lateStderr.contains("provider stderr (sensitive) after overflow"))
        XCTAssertFalse(lateStderr.contains("stream-secret"), "Live diagnostics must preserve sensitive-input redaction")
        XCTAssertTrue(run.textOutput?.contains("provider stderr (sensitive) after overflow") == true)
        XCTAssertFalse(run.textOutput?.contains("stream-secret") == true)
        XCTAssertFalse(run.textOutput?.contains("\u{001B}") == true)
        XCTAssertTrue(run.plan?.isComplete == true)
        let persisted = try history.readPersistedRecord(id: run.id, workspace: root)
        XCTAssertNotNil(persisted.planOutput)
        XCTAssertTrue(persisted.planHistoryOutput?.contains("Late overflow failure") == true)
        XCTAssertTrue(persisted.planHistoryOutput?.contains("Earlier live output omitted; consult the completed run events") == true)
        XCTAssertTrue(persisted.planHistoryOutput?.contains("provider stderr (sensitive) after overflow") == true)
        XCTAssertFalse(persisted.planHistoryOutput?.contains("stream-secret") == true)
        XCTAssertEqual(persisted.planHistoryOutputTruncated, true)
        let historyBytes = try XCTUnwrap(persisted.planHistoryOutput?.data(using: .utf8))
        XCTAssertLessThanOrEqual(historyBytes.count, 256 * 1024)
        let historyLines = try XCTUnwrap(String(data: historyBytes, encoding: .utf8))
            .split(separator: "\n")
        XCTAssertFalse(historyLines.isEmpty)
        for line in historyLines {
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(event["type"])
        }
        let firstHistoryEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(historyLines[0].utf8)) as? [String: Any])
        XCTAssertEqual(firstHistoryEvent["type"] as? String, "version")

        let reopened = TerraformRun(workspace: workspace, record: persisted, restored: true)
        XCTAssertEqual(reopened.status, .errored)
        XCTAssertEqual(reopened.plan?.diagnostics.last?.diagnostic.summary, "Late overflow failure")
        let reopenedStderr = try XCTUnwrap(reopened.plan?.logs.first(where: { $0.message?.contains("provider stderr") == true })?.message)
        XCTAssertTrue(reopenedStderr.contains("provider stderr (sensitive) after overflow"))
        XCTAssertFalse(reopenedStderr.contains("stream-secret"))
        XCTAssertTrue(reopened.historyNotice?.contains("Earlier streamed events omitted") == true)
        let available = try coordinator.acquire(workspace: root, contextIdentity: workspace.executionContextIdentifier)
        available.release()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Fixture did not reach the expected state")
    }
}
