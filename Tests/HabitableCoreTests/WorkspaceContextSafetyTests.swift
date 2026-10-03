import XCTest
@testable import HabitableCore

final class WorkspaceContextSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable context \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testFingerprintTracksConfigurationVariablesLocalModulesAndStateButSkipsCaches() throws {
        let tf = root.appendingPathComponent("main.tf")
        let vars = root.appendingPathComponent("prod.auto.tfvars")
        let state = root.appendingPathComponent("terraform.tfstate")
        let module = root.appendingPathComponent("modules/network")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "terraform { required_version = \">= 1.0\" }".write(to: tf, atomically: true, encoding: .utf8)
        try "size = 1".write(to: vars, atomically: true, encoding: .utf8)
        try "state-one".write(to: state, atomically: true, encoding: .utf8)
        try "resource \"terraform_data\" \"network\" {}".write(
            to: module.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8
        )
        let modules = root.appendingPathComponent(".terraform/modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try #"{"Modules":[{"Key":"network","Source":"./modules/network","Dir":"modules/network"}]}"#
            .write(to: modules.appendingPathComponent("modules.json"), atomically: true, encoding: .utf8)
        let providerCache = root.appendingPathComponent(".terraform/providers/large-cache.bin")
        try FileManager.default.createDirectory(at: providerCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "cache".write(to: providerCache, atomically: true, encoding: .utf8)
        try "readme one".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let original = try fingerprint()
        try "cache changed".write(to: providerCache, atomically: true, encoding: .utf8)
        try "readme two".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try fingerprint(), original, "Unrelated documentation and provider cache contents are outside the plan context")

        let beforeModuleMapChange = try fingerprint()
        try #"{"Modules":[{"Key":"network","Source":"./modules/network-v2","Dir":"modules/network"}]}"#
            .write(to: modules.appendingPathComponent("modules.json"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try fingerprint(), beforeModuleMapChange)

        for (url, content) in [(tf, "terraform { required_version = \"1.1\" }"),
                                (vars, "size = 2"), (state, "state-two"),
                                (module.appendingPathComponent("main.tf"), "resource \"terraform_data\" \"changed\" {}") ] {
            let prior = try fingerprint()
            try content.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertNotEqual(try fingerprint(), prior, "Changed execution input should invalidate a reviewed plan: \(url.lastPathComponent)")
        }
        XCTAssertNotEqual(try fingerprint(workspace: "staging"), try fingerprint(workspace: "default"))
        XCTAssertNotEqual(try fingerprint(backend: "local #123"), try fingerprint(backend: "local #456"))
        XCTAssertNotEqual(try fingerprint(terraformVersion: "fixture-2"), try fingerprint(terraformVersion: "fixture-1"))

        let metadata = root.appendingPathComponent(".terraform/terraform.tfstate")
        try #"{"backend":{"type":"local","config":{"path":"custom/state.json","workspace_dir":"named-states"}}}"#
            .write(to: metadata, atomically: true, encoding: .utf8)
        let customState = root.appendingPathComponent("custom/state.json")
        try FileManager.default.createDirectory(at: customState.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "custom-default".write(to: customState, atomically: true, encoding: .utf8)
        let namedState = root.appendingPathComponent("named-states/staging/terraform.tfstate")
        try FileManager.default.createDirectory(at: namedState.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "custom-named".write(to: namedState, atomically: true, encoding: .utf8)
        let beforeNamedChange = try fingerprint(workspace: "staging")
        try "changed-named".write(to: namedState, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try fingerprint(workspace: "staging"), beforeNamedChange)
        let beforeCustomChange = try fingerprint()
        try "changed-default".write(to: customState, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try fingerprint(), beforeCustomChange)
        try "malformed manifest".write(to: modules.appendingPathComponent("modules.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fingerprint(), "An installed module manifest that cannot be verified must fail closed")
    }

    @MainActor
    func testExternalConfigurationEditExpiresPlanBeforeApply() async throws {
        let cli = root.appendingPathComponent("terraform")
        let marker = root.appendingPathComponent("apply-ran")
        try #"""
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"fixture"}' ;;
          plan) echo '{"type":"change_summary","changes":{"add":1,"change":0,"remove":0}}' ;;
          show) echo '{"format_version":"1.0","terraform_version":"fixture","resource_changes":[]}' ;;
          apply) touch apply-ran ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try "terraform_data.example".write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let suite = "Habitable-context-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(
            restoreLastDirectory: false, defaults: defaults,
            historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")),
            descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions"))
        )
        workspace.runner = Runner(executableURL: cli)
        workspace.workingDirectory = root
        workspace.terraformVersion = "fixture"
        workspace.isValid = true
        let record = try workspace.historyStore.create(workspace: root, terraformVersion: "fixture", message: nil)
        let run = TerraformRun(workspace: workspace, record: record, restored: false)
        workspace.runs = [run]

        let planned = expectation(description: "Plan is reviewed")
        run.doPlan { _, error in
            XCTAssertNil(error)
            planned.fulfill()
        }
        await fulfillment(of: [planned], timeout: 10)
        XCTAssertEqual(run.status, .planned)
        XCTAssertTrue(run.canConfirm)

        try "terraform_data.changed".write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        let applied = expectation(description: "Stale plan is rejected")
        run.doApply { _, error in
            XCTAssertNotNil(error)
            applied.fulfill()
        }
        await fulfillment(of: [applied], timeout: 10)
        XCTAssertEqual(run.status, .expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(run.canConfirm)
    }

    @MainActor
    func testCancelDuringPreplanFingerprintNeverStartsTerraform() async throws {
        let cli = root.appendingPathComponent("terraform")
        try #"""
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"fixture"}' ;;
          plan) touch plan-ran ;;
          show) echo '{"format_version":"1.0","resource_changes":[]}' ;;
        esac
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = "Habitable-context-cancel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = RunHistoryStore(directory: root.appendingPathComponent("history"))
        let workspace = Workspace(
            restoreLastDirectory: false, defaults: defaults, historyStore: history,
            commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")),
            descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions"))
        )
        workspace.runner = Runner(executableURL: cli)
        workspace.workingDirectory = root
        workspace.terraformVersion = "fixture"
        workspace.isValid = true
        let record = try history.create(workspace: root, terraformVersion: "fixture", message: nil)
        let run = TerraformRun(workspace: workspace, record: record, restored: false)
        workspace.runs = [run]
        let completed = expectation(description: "Preplan verification cancellation completes")
        run.doPlan { _, error in
            XCTAssertTrue(error?.contains("Canceled") == true)
            completed.fulfill()
        }
        XCTAssertTrue(run.canCancel)
        run.cancel()
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(run.status, .canceled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan-ran").path))
    }

    @MainActor
    func testInputFingerprintChangesWithoutRetainingSecretText() {
        let variable = TerraformVariable()
        variable.isUserInput = true
        variable.key = "token"
        variable.sensitive = true
        variable.value = "secret-value-one"
        let first = WorkspaceContextFingerprint.inputsFingerprint(terraformVariables: [variable], environmentVariables: [])
        variable.value = "secret-value-two"
        let second = WorkspaceContextFingerprint.inputsFingerprint(terraformVariables: [variable], environmentVariables: [])
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("secret-value-one"))
        XCTAssertFalse(second.contains("secret-value-two"))
    }

    private func fingerprint(workspace: String = "default", backend: String = "local",
                             terraformVersion: String = "fixture-1") throws -> String {
        try WorkspaceContextFingerprint.capture(
            directory: root, terraformWorkspace: workspace, backendIdentity: backend,
            terraformVersion: terraformVersion, terraformExecutable: nil, inputsFingerprint: "test-inputs"
        )
    }
}
