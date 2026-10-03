import XCTest
@testable import HabitableCore

/// The concurrent writer fixture shares only this lock-protected failure collection.
private final class HistoryWriteFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}

final class RunHistoryTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var store: RunHistoryStore!
    @MainActor private var testDefaults: UserDefaults { UserDefaults(suiteName: "Habitable-history-\(root.lastPathComponent)")! }
    @MainActor private var testCommandCoordinator: WorkspaceCommandCoordinator {
        WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
    }
    @MainActor private var testDescriptionStore: WorkspaceDescriptionStore {
        WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions"))
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable history \(UUID())")
        directory = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = RunHistoryStore(directory: root.appendingPathComponent("history"))
    }
    override func tearDownWithError() throws {
        UserDefaults(suiteName: "Habitable-history-\(root.lastPathComponent)")?
            .removePersistentDomain(forName: "Habitable-history-\(root.lastPathComponent)")
        try FileManager.default.removeItem(at: root)
    }

    func testRoundTripPreservesResultsAndPrivatePermissions() throws {
        var record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: "First deployment",
                                      selectedTerraformWorkspace: "production", backendIdentity: "remote #12345")
        record.status = .applied
        record.planOutput = #"{"type":"change_summary","changes":{"add":1,"change":0,"remove":0}}"#
        record.applyOutput = #"{"type":"outputs","outputs":{"greeting":{"sensitive":false,"value":"hello"},"token":{"sensitive":true,"value":"never-persist-this"}}}"#
        record.added = 1
        try store.save(record, workspace: directory)
        let reopened = RunHistoryStore(directory: store.directory)
        let loaded = try XCTUnwrap(reopened.load(workspace: directory).first)
        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.createdAt, record.createdAt)
        XCTAssertEqual(loaded.number, 1)
        XCTAssertEqual(loaded.status, .applied)
        XCTAssertEqual(loaded.selectedTerraformWorkspace, "production")
        XCTAssertEqual(loaded.backendIdentity, "remote #12345")
        XCTAssertEqual(loaded.added, 1)
        XCTAssertTrue(loaded.applyOutput?.contains("hello") == true)
        XCTAssertFalse(loaded.applyOutput?.contains("never-persist-this") == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.recordURL(id: record.id, workspace: directory).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: store.workspaceDirectory(directory).path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLegacyRunRecordWithoutExecutionContextStillDecodes() throws {
        let record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        let file = store.recordURL(id: record.id, workspace: directory)
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "selectedTerraformWorkspace")
        object.removeValue(forKey: "backendIdentity")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacyData.write(to: file)

        let decoded = try XCTUnwrap(store.load(workspace: directory).first)
        XCTAssertEqual(decoded.id, record.id)
        XCTAssertNil(decoded.selectedTerraformWorkspace)
        XCTAssertNil(decoded.backendIdentity)
    }

    func testCanonicalWorkspaceIdentityAndIndependentNumbering() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let one = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        XCTAssertEqual(try store.load(workspace: alias).first?.id, one.id)
        XCTAssertEqual(try store.create(workspace: alias, terraformVersion: "1.16.4", message: nil).number, 2)
        let other = root.appendingPathComponent("other")
        XCTAssertTrue(try store.load(workspace: other).isEmpty)
        XCTAssertEqual(try store.create(workspace: other, terraformVersion: "1.16.4", message: nil).number, 1)
        XCTAssertThrowsError(try store.save(one, workspace: other))
    }

    func testCorruptAndFutureRecordsArePreservedAndBlockNewWrites() throws {
        let record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        let file = store.recordURL(id: record.id, workspace: directory)
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try store.load(workspace: directory))
        XCTAssertThrowsError(try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        var future = record
        future.schemaVersion = 99
        let futureData = try JSONEncoder().encode(future)
        try futureData.write(to: file)
        XCTAssertThrowsError(try store.load(workspace: directory))
        XCTAssertEqual(try Data(contentsOf: file), futureData)
    }

    func testIndependentWritersKeepBothRunsAndUniqueNumbers() throws {
        let second = RunHistoryStore(directory: store.directory)
        var firstRecord = try store.create(workspace: directory, terraformVersion: "1.16.4", message: "A")
        let secondRecord = try second.create(workspace: directory, terraformVersion: "1.16.4", message: "B")
        firstRecord.status = .applied
        try store.save(firstRecord, workspace: directory)
        let records = try second.load(workspace: directory)
        XCTAssertEqual(records.map(\.number), [1, 2])
        XCTAssertEqual(records[1].id, secondRecord.id)
        XCTAssertEqual(records[0].status, .applied)
    }

    func testPagedLoadReadsOnlyRequestedPayloadsAndNumbersStayMonotonicAfterDelete() throws {
        var records: [RunRecord] = []
        for _ in 0..<123 {
            records.append(try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil))
        }
        var oldest = try XCTUnwrap(records.first)
        oldest.status = .applied
        try store.save(oldest, workspace: directory)
        let oldestData = try Data(contentsOf: store.recordURL(id: oldest.id, workspace: directory))

        // Off-page payloads are not decoded. Keep the byte count unchanged because
        // metadata validation intentionally blocks externally resized records.
        let corruptPayload = Data(repeating: 0x78, count: oldestData.count)
        try corruptPayload.write(to: store.recordURL(id: oldest.id, workspace: directory))
        let page = try store.loadPage(workspace: directory, offset: 0, limit: 50)
        XCTAssertEqual(page.totalCount, 123)
        XCTAssertEqual(page.records.map(\.number), Array((74...123).reversed()))
        XCTAssertThrowsError(try store.loadPage(workspace: directory, offset: 100, limit: 50))

        // Restore the record so the store can validate it, then delete a terminal run.
        try oldestData.write(to: store.recordURL(id: oldest.id, workspace: directory))
        try store.delete(workspace: directory, id: oldest.id, protecting: [])
        let next = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        XCTAssertEqual(next.number, 124)
    }

    func testDeleteProtectsActiveAndExplicitlyProtectedRuns() throws {
        let active = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        XCTAssertThrowsError(try store.delete(workspace: directory, id: active.id, protecting: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordURL(id: active.id, workspace: directory).path))

        var completed = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        completed.status = .applied
        try store.save(completed, workspace: directory)
        XCTAssertThrowsError(try store.delete(workspace: directory, id: completed.id, protecting: [completed.id]))
        try store.delete(workspace: directory, id: completed.id, protecting: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordURL(id: completed.id, workspace: directory).path))
    }

    func testInterruptedIndexMutationRebuildsWithoutReusingNumbers() throws {
        let first = try store.create(workspace: directory, terraformVersion: "1.16.4", message: "first")
        let orphan = RunRecord(id: UUID(), number: 2, workspacePath: RunHistoryStore.workspacePath(directory),
                               createdAt: Date(), updatedAt: Date(), status: .applied, terraformVersion: "1.16.4",
                               selectedTerraformWorkspace: nil, backendIdentity: nil, message: "recovered", planOutput: nil,
                               applyOutput: nil, errorMessage: nil, added: nil, changed: nil, destroyed: nil)
        try JSONEncoder().encode(orphan).write(to: store.recordURL(id: orphan.id, workspace: directory))
        let marker = store.workspaceDirectory(directory).appendingPathComponent(".dirty")
        try Data(#"{"nextNumber":2}"#.utf8).write(to: marker)

        let recovered = try store.loadPage(workspace: directory, offset: 0, limit: 10)
        XCTAssertEqual(recovered.records.map(\.number), [2, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil).number, 3)

        // Simulate an interrupted deletion after unlinking the highest-numbered record.
        let next = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        try FileManager.default.removeItem(at: store.recordURL(id: next.id, workspace: directory))
        try Data(#"{"nextNumber":4}"#.utf8).write(to: marker)
        XCTAssertEqual(try store.loadPage(workspace: directory, offset: 0, limit: 10).totalCount, 3)
        XCTAssertEqual(try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil).number, 4)
        XCTAssertNotEqual(first.id, orphan.id)
    }

    func testExportReRedactsPersistedSensitiveOutputs() throws {
        let record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        let file = store.recordURL(id: record.id, workspace: directory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["applyOutput"] = #"{"outputs":{"token":{"sensitive":true,"value":"legacy-secret"}}}"#
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let exported = String(decoding: try store.exportData(id: record.id, workspace: directory), as: UTF8.self)
        XCTAssertTrue(exported.contains("(sensitive)"))
        XCTAssertFalse(exported.contains("legacy-secret"))
        let destination = root.appendingPathComponent("export.json")
        try store.export(id: record.id, workspace: directory, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), Data(exported.utf8))
    }

    @MainActor
    func testLargeHistoryPageLoadsOffMainThread() async throws {
        for _ in 0..<400 {
            _ = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        }
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: store, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        workspace.reloadRunHistory()
        XCTAssertTrue(workspace.historyLoading)
        // The main actor can keep servicing work while the archive is read and decoded elsewhere.
        let mainActorWork = Task { @MainActor in
            await Task.yield()
            return true
        }
        let mainActorResponsive = await mainActorWork.value
        XCTAssertTrue(mainActorResponsive)
        try await waitUntil { !workspace.historyLoading }
        XCTAssertEqual(workspace.historyTotalCount, 400)
        XCTAssertEqual(workspace.runs.count, workspace.historyPageSize)

        workspace.isValid = true
        workspace.terraformVersion = "1.16.4"
        workspace.runner = Runner(executableURL: root.appendingPathComponent("missing-terraform"))
        workspace.queueRun()
        XCTAssertTrue(workspace.historyLoading)
        XCTAssertTrue(workspace.locked)
        let queueActorWork = Task { @MainActor in
            await Task.yield()
            return true
        }
        let queueActorResponsive = await queueActorWork.value
        XCTAssertTrue(queueActorResponsive)
        try await waitUntil { workspace.historyTotalCount == 401 }
    }

    @MainActor
    func testQueueingKeepsSavedPageVisibleAlongsideNewRun() async throws {
        for _ in 0..<3 {
            var record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
            record.status = .applied
            try store.save(record, workspace: directory)
        }
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: store, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        workspace.terraformVersion = "1.16.4"
        workspace.reloadRunHistory()
        try await waitUntil { !workspace.historyLoading }
        XCTAssertEqual(workspace.runs.map(\.number).sorted(), [1, 2, 3])

        workspace.runner = Runner(executableURL: root.appendingPathComponent("missing-terraform"))
        workspace.isValid = true
        workspace.queueRun()
        try await waitUntil { workspace.historyTotalCount == 4 && workspace.runs.contains(where: { $0.number == 4 }) }
        XCTAssertEqual(workspace.runs.map(\.number).sorted(), [1, 2, 3, 4])
    }

    func testConcurrentWritersAllocateUniqueNumbers() throws {
        let historyDirectory = store.directory
        let workspaceDirectory = directory!
        let failures = HistoryWriteFailures()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                _ = try RunHistoryStore(directory: historyDirectory).create(workspace: workspaceDirectory,
                    terraformVersion: "1.16.4", message: nil)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        XCTAssertEqual(failures.snapshot, [])
        XCTAssertEqual(try store.load(workspace: directory).map(\.number), Array(1...12))
    }

    @MainActor
    func testRestoredRunsNeverApplyAndRetainTheirResults() throws {
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: store, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        var record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        record.status = .planned
        record.planOutput = #"{"type":"change_summary","changes":{"add":2,"change":0,"remove":0}}"#
        let run = TerraformRun(workspace: workspace, record: record, restored: true)
        XCTAssertEqual(run.status, .expired)
        XCTAssertEqual(run.plan?.changeSummaries.first?.changes.add, 2)
        XCTAssertFalse(run.canConfirm)
        XCTAssertFalse(run.canDiscard)
        run.doApply { _, _ in XCTFail("Restored plan must not execute") }
        XCTAssertEqual(run.status, .expired)
        for status in [RunStatus.pending, .planning, .confirmed, .applying] {
            record.status = status
            let interrupted = TerraformRun(workspace: workspace, record: record, restored: true)
            XCTAssertEqual(interrupted.status, .interrupted)
            XCTAssertNotNil(interrupted.historyNotice)
            XCTAssertFalse(interrupted.canConfirm)
        }
        for status in [RunStatus.applied, .errored, .discarded, .canceled] {
            record.status = status
            XCTAssertEqual(TerraformRun(workspace: workspace, record: record, restored: true).status, status)
        }
    }

    @MainActor
    func testWorkspaceRoundTripRestoresAppliedRunAndContinuesNumbering() async throws {
        guard let path = ProcessInfo.processInfo.environment["HABITABLE_TEST_TERRAFORM"] else {
            throw XCTSkip("Set HABITABLE_TEST_TERRAFORM for the durable-run integration test")
        }
        try #"resource "terraform_data" "example" { input = "history survives restart" }"#
            .write(to: directory.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: store, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: URL(fileURLWithPath: path))
        workspace.workingDirectory = directory
        workspace.terraformVersion = "1.16.4"
        workspace.initialize()
        try await waitUntil { !workspace.locked }
        XCTAssertTrue(workspace.isValid)
        workspace.queueRun("Durable run")
        try await waitUntil { workspace.runs.first?.status == .planned }
        let run = try XCTUnwrap(workspace.runs.first)
        XCTAssertEqual(run.status, .planned)
        XCTAssertNil(workspace.historyError)
        await withCheckedContinuation { continuation in
            run.doApply { _, error in
                XCTAssertNil(error)
                continuation.resume()
            }
        }
        try await waitUntil { !workspace.locked }
        let reopened = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: RunHistoryStore(directory: store.directory), commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        reopened.workingDirectory = directory
        reopened.reloadRunHistory()
        try await waitUntil { !reopened.historyLoading }
        let restored = try XCTUnwrap(reopened.runs.first)
        XCTAssertEqual(restored.id, run.id)
        XCTAssertEqual(restored.status, .applied)
        XCTAssertEqual(restored.message, "Durable run")
        XCTAssertEqual(restored.added, 1)
        XCTAssertEqual(restored.apply?.resources.first?.stages.last?.done, true)
        XCTAssertFalse(restored.canConfirm)
        XCTAssertEqual(try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil).number, 2)
    }

    @MainActor
    func testUnwritableHistoryBlocksCommandBeforeItStarts() async throws {
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: RunHistoryStore(directory: file), commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        // Isolate this write-failure test from the default CLI's asynchronous
        // version probe, which could otherwise invalidate the queue context.
        workspace.runner = Runner(executableURL: root.appendingPathComponent("must-not-run"))
        workspace.terraformVersion = "fixture"
        workspace.workingDirectory = directory
        workspace.isValid = true
        workspace.queueRun()
        try await waitUntil { !workspace.locked && !workspace.historyLoading }
        XCTAssertTrue(workspace.runs.isEmpty)
        XCTAssertFalse(workspace.locked)
        XCTAssertNotNil(workspace.historyError)
    }

    @MainActor
    func testSaveFailureStaysVisibleUntilRetryAndDoesNotLoseResult() async throws {
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: store, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        var record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        let folder = store.workspaceDirectory(directory)
        let preserved = folder.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: folder, to: preserved)
        try Data().write(to: folder)
        record.status = .applied
        record.added = 3
        XCTAssertFalse(workspace.persistRun(record, directory: directory))
        XCTAssertNotNil(workspace.historyError)
        workspace.isValid = true
        workspace.queueRun()
        XCTAssertTrue(workspace.runs.isEmpty)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: preserved, to: folder)
        workspace.reloadRunHistory()
        try await waitUntil { !workspace.historyLoading }
        XCTAssertNil(workspace.historyError)
        XCTAssertEqual(workspace.runs.first?.status, .applied)
        XCTAssertEqual(try store.load(workspace: directory).first?.added, 3)
    }

    @MainActor
    func testFailedApplyRetiresOtherPlansAndPersistsError() async throws {
        let executable = root.appendingPathComponent("fake-terraform")
        try "#!/bin/sh\ncase \"$1\" in\nversion) echo '{\"terraform_version\":\"1.16.4\"}' ;;\nplan) echo '{\"type\":\"change_summary\",\"changes\":{\"add\":1,\"change\":0,\"remove\":0}}' ;;\napply) echo 'partial apply failed' >&2; exit 1 ;;\nshow) case \"$3\" in *.tfplan) echo '{\"format_version\":\"1.0\",\"resource_changes\":[{\"address\":\"terraform_data.example\",\"change\":{\"actions\":[\"create\"],\"before\":null,\"after\":{\"input\":\"x\"},\"after_unknown\":{}}}]}' ;; *) echo '{\"values\":{\"root_module\":{\"resources\":[]}}}' ;; esac ;;\nesac\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, historyStore: store,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: executable)
        workspace.workingDirectory = directory
        let record = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        try store.save(record, workspace: directory)
        let run = TerraformRun(workspace: workspace, record: record, restored: false)
        var otherRecord = try store.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        otherRecord.status = .planned
        try store.save(otherRecord, workspace: directory)
        let other = TerraformRun(workspace: workspace, record: otherRecord, restored: false)
        workspace.runs = [run, other]
        let planning = expectation(description: "Plan completes")
        var planningError: String?
        run.doPlan { _, error in
            planningError = error
            planning.fulfill()
        }
        await fulfillment(of: [planning], timeout: 15)
        XCTAssertNil(planningError)
        try await waitUntil { !workspace.locked }
        XCTAssertEqual(run.status, .planned)
        let applying = expectation(description: "Apply completes")
        var applyError: String?
        run.doApply { _, error in
            applyError = error
            applying.fulfill()
        }
        await fulfillment(of: [applying], timeout: 15)
        XCTAssertTrue(applyError?.contains("partial apply failed") == true)
        try await waitUntil { !workspace.locked }
        XCTAssertEqual(run.status, .errored)
        XCTAssertEqual(other.status, .discarded)
        XCTAssertNotNil(workspace.state)
        let records = try store.load(workspace: directory)
        XCTAssertEqual(records.map(\.status), [.errored, .discarded])
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Command did not finish in time")
    }
}
