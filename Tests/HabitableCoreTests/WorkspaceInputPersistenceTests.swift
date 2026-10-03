import Foundation
import XCTest
import Security
@testable import HabitableCore

private final class FakeInputSecrets: WorkspaceInputSecretStore {
    var values: [String: String] = [:]
    var shouldFail = false
    var shouldFailDeletes = false
    func read(id: String) throws -> String? {
        if shouldFail { throw WorkspaceInputStoreError.keychain(errSecInteractionNotAllowed) }
        return values[id]
    }
    func write(_ value: String, id: String) throws {
        if shouldFail { throw WorkspaceInputStoreError.keychain(errSecInteractionNotAllowed) }
        values[id] = value
    }
    func delete(id: String) throws {
        if shouldFail || shouldFailDeletes { throw WorkspaceInputStoreError.keychain(errSecInteractionNotAllowed) }
        values.removeValue(forKey: id)
    }
}

final class WorkspaceInputPersistenceTests: XCTestCase {
    func testSensitiveValueNeverAppearsInWorkspaceInputFileAndReloadsFromInjectedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: secrets)
        let secret = "value-that-must-not-be-written"
        try store.save([
            StoredWorkspaceInput(kind: .terraform, key: "region", value: "west", secretID: nil,
                                 description: "region", sensitive: false, hcl: false),
            StoredWorkspaceInput(kind: .environment, key: "TF_VAR_token", value: secret, secretID: nil,
                                 description: "token", sensitive: true, hcl: false)
        ], workspace: workspace)

        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("inputs"), includingPropertiesForKeys: nil).first)
        let permissions = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("secretID"))
        let loaded = try store.load(workspace: workspace)
        XCTAssertEqual(loaded.map(\.1), ["west", secret])
    }

    func testKeychainFailureDoesNotWriteRememberedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets()
        secrets.shouldFail = true
        let inputRoot = root.appendingPathComponent("inputs")
        let store = WorkspaceInputStore(root: inputRoot, secrets: secrets)
        XCTAssertThrowsError(try store.save([
            StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: "draft-secret", secretID: nil,
                                 description: "", sensitive: true, hcl: false)
        ], workspace: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputRoot.path))
    }

    func testMetadataWriteFailureDeletesOnlyStagedSecret() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let badRoot = root.appendingPathComponent("inputs")
        try Data("not a directory".utf8).write(to: badRoot)
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: badRoot, secrets: secrets)
        XCTAssertThrowsError(try store.save([
            StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: "draft-secret", secretID: nil,
                                 description: "", sensitive: true, hcl: false)
        ], workspace: workspace))
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testFailedSecretEditKeepsPreviouslyRememberedValueAndReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: secrets)
        func record(_ value: String) -> StoredWorkspaceInput {
            StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: value, secretID: nil,
                                 description: "", sensitive: true, hcl: false)
        }
        try store.save([record("old-secret")], workspace: workspace)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("inputs"), includingPropertiesForKeys: nil).first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let oldReference = try XCTUnwrap(json.first?["secretID"] as? String)
        secrets.shouldFail = true
        XCTAssertThrowsError(try store.save([record("new-secret")], workspace: workspace))
        XCTAssertEqual(secrets.values[oldReference], "old-secret")
        secrets.shouldFail = false
        XCTAssertEqual(try store.load(workspace: workspace).first?.1, "old-secret")
    }

    func testMetadataCommitFailureLeavesOldSecretAndReferenceIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let inputRoot = root.appendingPathComponent("inputs")
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: inputRoot, secrets: secrets)
        func record(_ value: String) -> StoredWorkspaceInput {
            StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: value, secretID: nil,
                                 description: "", sensitive: true, hcl: false)
        }
        try store.save([record("old-secret")], workspace: workspace)
        let oldID = try XCTUnwrap(try store.load(workspace: workspace).first?.0.secretID)
        let failingStore = WorkspaceInputStore(root: inputRoot, secrets: secrets, fileWriter: { _, _ in
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertThrowsError(try failingStore.save([record("new-secret")], workspace: workspace))
        XCTAssertEqual(secrets.values.count, 1)
        XCTAssertEqual(secrets.values[oldID], "old-secret")
        XCTAssertEqual(try store.load(workspace: workspace).first?.1, "old-secret")
    }

    func testRenameAndSensitiveToggleRetireOldSecretOnlyAfterMetadataCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: secrets)
        let secret = StoredWorkspaceInput(kind: .environment, key: "OLD_TOKEN", value: "old", secretID: nil,
                                          description: "", sensitive: true, hcl: false)
        try store.save([secret], workspace: workspace)
        let oldID = try XCTUnwrap(try store.load(workspace: workspace).first?.0.secretID)
        let renamed = StoredWorkspaceInput(kind: .environment, key: "NEW_TOKEN", value: "new", secretID: nil,
                                           description: "", sensitive: true, hcl: false)
        try store.save([renamed], workspace: workspace)
        XCTAssertNil(secrets.values[oldID])
        XCTAssertEqual(try store.load(workspace: workspace).first?.0.key, "NEW_TOKEN")
        try store.save([StoredWorkspaceInput(kind: .environment, key: "NEW_TOKEN", value: "public", secretID: nil,
                                             description: "", sensitive: false, hcl: false)], workspace: workspace)
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertEqual(try store.load(workspace: workspace).first?.1, "public")
    }

    func testOldKeychainCleanupFailureIsReportedAndRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: secrets)
        func record(_ value: String) -> StoredWorkspaceInput {
            StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: value, secretID: nil,
                                 description: "", sensitive: true, hcl: false)
        }
        try store.save([record("first")], workspace: workspace)
        let oldID = try XCTUnwrap(try store.load(workspace: workspace).first?.0.secretID)
        secrets.shouldFailDeletes = true
        let warning = try store.save([record("second")], workspace: workspace)
        XCTAssertNotNil(warning)
        XCTAssertEqual(try store.load(workspace: workspace).first?.1, "second")
        XCTAssertEqual(secrets.values[oldID], "first")
        secrets.shouldFailDeletes = false
        XCTAssertNil(try store.save([record("third")], workspace: workspace))
        XCTAssertNil(secrets.values[oldID])
    }

    func testPlaintextSensitiveRecordIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: FakeInputSecrets())
        try store.save([], workspace: workspace)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("inputs"), includingPropertiesForKeys: nil).first)
        try Data(#"[{"kind":"environment","key":"TOKEN","value":"must-not-be-written","secretID":"opaque","description":"","sensitive":true,"hcl":false}]"#.utf8).write(to: file)
        XCTAssertThrowsError(try store.load(workspace: workspace))
    }

    func testInvalidRememberedStructuredAndEnvironmentValuesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: FakeInputSecrets())
        XCTAssertThrowsError(try store.save([
            StoredWorkspaceInput(kind: .terraform, key: "settings", value: "{bad", secretID: nil,
                                 description: "", sensitive: false, hcl: true)
        ], workspace: workspace))
        XCTAssertThrowsError(try store.save([
            StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: "bad\0value", secretID: nil,
                                 description: "", sensitive: false, hcl: false)
        ], workspace: workspace))
    }

    func testRememberedInputsAreIsolatedByCanonicalWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: FakeInputSecrets())
        try store.save([StoredWorkspaceInput(kind: .terraform, key: "only_first", value: "yes", secretID: nil,
                                             description: "", sensitive: false, hcl: false)], workspace: first)
        XCTAssertEqual(try store.load(workspace: first).map(\.0.key), ["only_first"])
        XCTAssertTrue(try store.load(workspace: second).isEmpty)
    }
}

@MainActor
final class WorkspaceInputWorkspaceTests: XCTestCase {
    func testSessionOnlyInputDoesNotCreatePersistenceFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeRoot = root.appendingPathComponent("inputs")
        let workspace = Workspace(restoreLastDirectory: false,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("locks")),
            workspaceInputStore: WorkspaceInputStore(root: storeRoot, secrets: FakeInputSecrets()))
        workspace.workingDirectory = directory
        let input = TerraformVariable()
        input.key = "region"; input.value = "west"
        try workspace.addTerraformVariable(input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.path))
    }

    func testRememberFailureLeavesDraftValueAvailableToEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets(); secrets.shouldFail = true
        let workspace = Workspace(restoreLastDirectory: false,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("locks")),
            workspaceInputStore: WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: secrets))
        workspace.workingDirectory = directory
        let draft = EnvironmentVariable()
        draft.key = "TOKEN"; draft.value = "draft-secret"; draft.sensitive = true; draft.isRemembered = true
        XCTAssertThrowsError(try workspace.addEnvironmentVariable(draft))
        XCTAssertEqual(draft.value, "draft-secret")
        XCTAssertFalse(workspace.environmentVariables.contains { $0 === draft })
    }

    func testMissingSecretOpensAsUnavailablePlaceholderAndBlocksValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secrets = FakeInputSecrets()
        let store = WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: secrets)
        try store.save([StoredWorkspaceInput(kind: .environment, key: "TOKEN", value: "original", secretID: nil,
                                             description: "", sensitive: true, hcl: false)], workspace: directory)
        secrets.values.removeAll()
        let workspace = Workspace(restoreLastDirectory: false,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("locks")),
            workspaceInputStore: store)
        XCTAssertTrue(workspace.openWorkspaceDirectory(directory))
        let input = try XCTUnwrap(workspace.environmentVariables.first)
        XCTAssertTrue(input.rememberedSecretUnavailable)
        XCTAssertEqual(input.value, "")
        XCTAssertTrue(workspace.hasUnavailableRememberedInputs)
        workspace.validate()
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertFalse(workspace.locked)
        try workspace.removeEnvironmentVariable(input)
        XCTAssertFalse(workspace.hasUnavailableRememberedInputs)
        XCTAssertTrue(try store.load(workspace: directory).isEmpty)
    }

    func testCorruptRememberedStoreRejectsFolderSwitchWithoutDroppingCurrentInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let inputRoot = root.appendingPathComponent("inputs")
        let store = WorkspaceInputStore(root: inputRoot, secrets: FakeInputSecrets())
        try store.save([StoredWorkspaceInput(kind: .terraform, key: "target", value: "second", secretID: nil,
                                             description: "", sensitive: false, hcl: false)], workspace: second)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: inputRoot, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)

        let workspace = Workspace(restoreLastDirectory: false,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("locks")),
            workspaceInputStore: store)
        workspace.workingDirectory = first
        let current = EnvironmentVariable()
        current.key = "CURRENT"; current.value = "kept"; current.isUserInput = true
        workspace.environmentVariables = [current]
        XCTAssertFalse(workspace.openWorkspaceDirectory(second))
        XCTAssertEqual(workspace.workingDirectory, first)
        XCTAssertTrue(workspace.environmentVariables.contains { $0 === current })
        XCTAssertNotNil(workspace.workspaceOpenError)
    }

    func testMissingInitialFolderIsNotActivated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("gone")
        let workspace = Workspace(dir: missing, restoreLastDirectory: false,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("locks")),
            workspaceInputStore: WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: FakeInputSecrets()))
        XCTAssertNil(workspace.workingDirectory)
        XCTAssertNotNil(workspace.workspaceOpenError)
    }

    func testMissingRestoredFolderIsNotActivated() throws {
        let defaults = UserDefaults.standard
        let prior = defaults.url(forKey: "lastWorkingDirectory")
        defer {
            if let prior { defaults.set(prior, forKey: "lastWorkingDirectory") }
            else { defaults.removeObject(forKey: "lastWorkingDirectory") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.appendingPathComponent("gone"), forKey: "lastWorkingDirectory")
        let workspace = Workspace(restoreLastDirectory: true,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("locks")),
            workspaceInputStore: WorkspaceInputStore(root: root.appendingPathComponent("inputs"), secrets: FakeInputSecrets()))
        XCTAssertNil(workspace.workingDirectory)
        XCTAssertNotNil(workspace.workspaceOpenError)
    }
}
