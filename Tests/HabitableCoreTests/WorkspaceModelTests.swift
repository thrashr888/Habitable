import XCTest
@testable import HabitableCore

@MainActor
final class WorkspaceModelTests: XCTestCase {
    // XCTest calls setup, each test body, and teardown serially on its managed test instance.
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var directory: URL!
    private var testCommandCoordinator: WorkspaceCommandCoordinator {
        WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
    }
    private var testDefaults: UserDefaults { UserDefaults(suiteName: "Habitable-workspace-\(root.lastPathComponent)")! }
    private var testDescriptionStore: WorkspaceDescriptionStore {
        WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions"))
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable workspace \(UUID())")
        directory = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: "Habitable-workspace-\(root.lastPathComponent)")?
            .removePersistentDomain(forName: "Habitable-workspace-\(root.lastPathComponent)")
        try FileManager.default.removeItem(at: root)
    }

    private func fakeTerraform(_ script: String) throws -> URL {
        let executable = root.appendingPathComponent("terraform")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    @MainActor
    func testSuccessfulValidateRecognizesProviderFreeInitAfterReopen() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          init) echo 'Terraform has been successfully initialized!' ;;
          validate) echo '{"valid":true}' ;;
          show) echo '{"values":{"root_module":{"resources":[]}}}' ;;
        esac
        """)
        try "terraform { required_version = \"~> 1.0\" }\n".write(to: directory.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let first = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        first.runner = Runner(executableURL: executable)
        first.workingDirectory = directory
        first.initialize()
        try await waitUntil { !first.locked }
        XCTAssertTrue(first.isInitialized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".terraform").path))
        first.initialize()
        try await waitUntil { !first.locked }
        XCTAssertTrue(first.isInitialized, "Repeated successful inits should keep the workspace initialized")

        let reopened = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        reopened.runner = Runner(executableURL: executable)
        reopened.updateWorkingDirectory(dir: directory)
        try await waitUntil { !reopened.locked }

        XCTAssertTrue(reopened.isValid)
        XCTAssertTrue(reopened.isInitialized)
    }

    @MainActor
    func testValidationLoadsRemoteBackendStateWithoutLocalStateFile() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          validate) echo '{"valid":true}' ;;
          show) echo '{"values":{"outputs":{"remote_value":{"value":"loaded","sensitive":false}},"root_module":{"resources":[]}}}' ;;
        esac
        """)
        let config = #"terraform { backend "remote" { hostname = "example.invalid" organization = "test" workspaces { name = "fixture" } } }"#
        try config.write(to: directory.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)

        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: executable)
        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("terraform.tfstate").path))
        XCTAssertTrue(workspace.isValid)
        XCTAssertTrue(workspace.hasState)
        XCTAssertEqual(workspace.state?.outputs.first?.key, "remote_value")
        XCTAssertNil(workspace.errorMessage)
    }

    @MainActor
    func testTerraformShowWithoutStateIsNeutral() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          validate) echo '{"valid":true}' ;;
          show) echo '{"format_version":"1.0"}' ;;
        esac
        """)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: executable)
        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }

        XCTAssertTrue(workspace.isValid)
        XCTAssertFalse(workspace.hasState)
        XCTAssertNil(workspace.state)
        XCTAssertNil(workspace.errorMessage)
    }

    @MainActor
    func testMalformedShowDataRemainsVisible() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          validate) echo '{"valid":true}' ;;
          show) echo '{"values":null}' ;;
        esac
        """)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: executable)
        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }

        XCTAssertTrue(workspace.isValid)
        XCTAssertFalse(workspace.hasState)
        XCTAssertNil(workspace.state)
        XCTAssertEqual(workspace.errorMessage, "Terraform returned malformed state data.")
    }

    @MainActor
    func testShowCommandFailureRemainsVisible() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          validate) echo '{"valid":true}' ;;
          show) echo 'remote backend is unavailable' >&2; exit 1 ;;
        esac
        """)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: executable)
        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }

        XCTAssertTrue(workspace.isValid)
        XCTAssertFalse(workspace.hasState)
        XCTAssertNil(workspace.state)
        XCTAssertTrue(workspace.errorMessage?.contains("remote backend is unavailable") == true)
    }

    func testCoordinationLeaseSerializesWindowsAndInvalidatesSiblingPlans() throws {
        let coordinationDirectory = root.appendingPathComponent("coordination")
        let firstCoordinator = WorkspaceCommandCoordinator(directory: coordinationDirectory)
        let secondCoordinator = WorkspaceCommandCoordinator(directory: coordinationDirectory)
        let context = "workspace=default;backend=local #fixture"
        let first = try firstCoordinator.acquire(workspace: directory, contextIdentity: context)
        let plannedGeneration = first.generation
        XCTAssertThrowsError(try secondCoordinator.acquire(workspace: directory, contextIdentity: context)) { error in
            XCTAssertTrue(error is WorkspaceCommandCoordinator.CoordinatorError)
        }

        try first.invalidatePlans()
        first.release()
        let second = try secondCoordinator.acquire(workspace: directory, contextIdentity: context)
        XCTAssertGreaterThan(second.generation, plannedGeneration)
        second.release()
    }

    func testContextChangeAdvancesGeneration() throws {
        let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
        let first = try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local")
        let initial = first.generation
        first.release()
        let selectedOtherWorkspace = try coordinator.acquire(workspace: directory, contextIdentity: "workspace=production;backend=local")
        XCTAssertGreaterThan(selectedOtherWorkspace.generation, initial)
        selectedOtherWorkspace.release()
    }

    func testFailedGenerationWriteBlocksFutureLeasesWithoutAdvancingInMemory() throws {
        let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
        let lease = try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local")
        let generation = lease.generation
        try FileManager.default.removeItem(at: lease.metadataURL)
        try FileManager.default.createDirectory(at: lease.metadataURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try lease.invalidatePlans())
        XCTAssertEqual(lease.generation, generation)
        XCTAssertThrowsError(try coordinator.recover(workspace: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("using this Terraform workspace"))
        }
        XCTAssertTrue(coordinator.recoveryRequired(workspace: directory))
        lease.release()
        XCTAssertThrowsError(try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local"))

        try FileManager.default.removeItem(at: lease.metadataURL)
        try String(generation).write(to: lease.metadataURL, atomically: true, encoding: .utf8)
        let recoveredGeneration = try coordinator.recover(workspace: directory)
        XCTAssertGreaterThan(recoveredGeneration, generation)
        XCTAssertFalse(coordinator.recoveryRequired(workspace: directory))

        let recoveredLease = try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local")
        XCTAssertEqual(recoveredLease.generation, recoveredGeneration)
        recoveredLease.release()
    }

    func testRecoveryKeepsFailureMarkerWhenGenerationIsMissingOrCorrupt() throws {
        for invalidGeneration in [false, true] {
            let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination-\(invalidGeneration)"))
            let lease = try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local")
            try FileManager.default.removeItem(at: lease.metadataURL)
            try FileManager.default.createDirectory(at: lease.metadataURL, withIntermediateDirectories: false)
            XCTAssertThrowsError(try lease.invalidatePlans())
            lease.release()

            try FileManager.default.removeItem(at: lease.metadataURL)
            if invalidGeneration {
                try "not-a-generation".write(to: lease.metadataURL, atomically: true, encoding: .utf8)
            }
            XCTAssertThrowsError(try coordinator.recover(workspace: directory))
            XCTAssertTrue(coordinator.recoveryRequired(workspace: directory))
            XCTAssertThrowsError(try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local"))
        }
    }

    @MainActor
    func testWorkspaceRecoveryRevalidatesBeforeNewPlans() async throws {
        let coordinator = WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination"))
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: coordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        workspace.runner = Runner(executableURL: try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"fixture"}' ;;
          validate) echo 'valid' ;;
          show) echo '{"values":{"root_module":{"resources":[]}}}' ;;
        esac
        """))
        let lease = try workspace.acquireCommandLease()
        let generation = lease.generation
        try FileManager.default.removeItem(at: lease.metadataURL)
        try FileManager.default.createDirectory(at: lease.metadataURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try lease.invalidatePlans())
        lease.release()
        try FileManager.default.removeItem(at: lease.metadataURL)
        try String(generation).write(to: lease.metadataURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(workspace.isValid)
        workspace.recoverCoordination()
        try await waitUntil { !workspace.locked }
        XCTAssertTrue(workspace.isValid)
        XCTAssertFalse(workspace.coordinationRecoveryRequired)
        XCTAssertNotNil(workspace.coordinationRecoveryNotice)
    }

    @MainActor
    func testReadsSelectedTerraformWorkspaceAndBackendIdentity() throws {
        let terraformDirectory = directory.appendingPathComponent(".terraform")
        try FileManager.default.createDirectory(at: terraformDirectory, withIntermediateDirectories: true)
        try "production\n".write(to: terraformDirectory.appendingPathComponent("environment"), atomically: true, encoding: .utf8)
        try #"{"backend":{"type":"remote","hash":12345,"config":{}}}"#
            .write(to: terraformDirectory.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory

        let lease = try workspace.acquireCommandLease()
        XCTAssertEqual(workspace.selectedTerraformWorkspace, "production")
        XCTAssertEqual(workspace.backendIdentity, "remote #12345")
        XCTAssertTrue(workspace.executionContextIdentifier.hasPrefix("workspace=production;backend=remote #12345;terraform="))
        XCTAssertEqual(workspace.executionContextDisplay, "Workspace: production · Backend: remote #12345")
        lease.release()
    }

    @MainActor
    func testImplicitLocalBackendWithoutMetadata() throws {
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        let lease = try workspace.acquireCommandLease()
        defer { lease.release() }
        XCTAssertEqual(workspace.backendIdentity, "local")
        XCTAssertEqual(workspace.executionContextDisplay, "Workspace: default · Backend: local")
        let run = TerraformRun(workspace: workspace)
        XCTAssertEqual(run.executionContextDescription, "Terraform workspace: default · Backend: local")
    }

    @MainActor
    func testMalformedBackendMetadataRemainsUnknown() throws {
        let terraformDirectory = directory.appendingPathComponent(".terraform")
        try FileManager.default.createDirectory(at: terraformDirectory, withIntermediateDirectories: true)
        try "invalid metadata".write(to: terraformDirectory.appendingPathComponent("terraform.tfstate"),
                                     atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        let lease = try workspace.acquireCommandLease()
        defer { lease.release() }
        XCTAssertEqual(workspace.backendIdentity, "unknown backend")
    }

    @MainActor
    func testVariableRefreshPreservesEditorInputsAndRemovesStaleDiscoveries() async throws {
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        let editorVariable = TerraformVariable()
        editorVariable.key = "saved"
        editorVariable.value = "keep-me"
        editorVariable.sensitive = true
        editorVariable.isUserInput = true
        try workspace.addTerraformVariable(editorVariable)
        let editorEnvironment = EnvironmentVariable()
        editorEnvironment.key = "EDITOR_TOKEN"
        editorEnvironment.value = "secret"
        editorEnvironment.sensitive = true
        editorEnvironment.isUserInput = true
        try workspace.addEnvironmentVariable(editorEnvironment)

        try "from_file = \"old\"\n".write(to: directory.appendingPathComponent("terraform.tfvars"), atomically: true, encoding: .utf8)
        workspace.checkVariables()
        try await waitUntil { !workspace.isInspectingInputs }
        XCTAssertEqual(workspace.terraformVariables.map(\.key), ["saved", "from_file"])
        XCTAssertTrue(workspace.hasVariables)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("terraform.tfvars"))
        workspace.checkVariables()
        try await waitUntil { !workspace.isInspectingInputs }

        XCTAssertEqual(workspace.terraformVariables.map(\.key), ["saved"])
        XCTAssertTrue(workspace.terraformVariables[0].sensitive)
        XCTAssertEqual(workspace.environmentVariables.map(\.key), ["EDITOR_TOKEN"])
        XCTAssertTrue(workspace.environmentVariables[0].sensitive)
        XCTAssertFalse(workspace.hasVariables)

        let otherWorkspace = root.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        workspace.runner = Runner(executableURL: try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          validate) echo '{"valid":true}' ;;
          show) echo '{"values":{"root_module":{"resources":[]}}}' ;;
        esac
        """))
        workspace.updateWorkingDirectory(dir: otherWorkspace)
        try await waitUntil { !workspace.locked }
        XCTAssertFalse(workspace.terraformVariables.contains { $0.isUserInput })
        XCTAssertFalse(workspace.environmentVariables.contains { $0.isUserInput })
        XCTAssertFalse(workspace.hasVariables)
    }

    @MainActor
    func testTfvarsDiscoveryPreservesEqualsAndTypedJSONValues() async throws {
        workspaceFile("message = \"east=west\"\nlist = [\"a\", \"b\"]\nobject = {\n  ignored = true\n}\n# comment\n", named: "terraform.tfvars")
        workspaceFile(#"{"enabled":true,"count":3,"message":"north=south","nullable":null,"items":[1,"x"],"settings":{"region":"west"}}"#, named: "terraform.tfvars.json")
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        workspace.checkVariables()
        try await waitUntil { !workspace.isInspectingInputs }

        let discovered = Dictionary(uniqueKeysWithValues: workspace.terraformVariables.map { ($0.key, $0) })
        XCTAssertEqual(try discovered["message"]?.terraformJSONValue() as? String, "north=south")
        XCTAssertEqual(try discovered["list"]?.terraformJSONValue() as? [String], ["a", "b"])
        XCTAssertNotNil(discovered["object"], "Multiline nested HCL values are parsed by the HCL helper")
        XCTAssertEqual(discovered["enabled"]?.value, "true")
        XCTAssertEqual(discovered["count"]?.value, "3")
        XCTAssertEqual(discovered["nullable"]?.value, "null")
        XCTAssertTrue(discovered["nullable"]?.hcl == true)
        XCTAssertEqual(discovered["items"]?.value, "[1,\"x\"]")
        XCTAssertEqual(discovered["settings"]?.value, #"{"region":"west"}"#)
    }

    @MainActor
    func testAppTFVarEnvironmentAppearsAndYieldsToFilesAfterRefresh() async throws {
        let terraformKey = "habitable_app_env_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        workspaceFile("variable \"\(terraformKey)\" { type = string }", named: "variables.tf")
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        let appEnvironment = EnvironmentVariable()
        appEnvironment.key = "TF_VAR_\(terraformKey)"
        appEnvironment.value = "from-app-environment"
        try workspace.addEnvironmentVariable(appEnvironment)
        try await waitUntil { !workspace.isInspectingInputs }

        let overridden = try XCTUnwrap(workspace.terraformVariables.first { $0.key == terraformKey })
        XCTAssertEqual(try overridden.terraformJSONValue() as? String, "from-app-environment")
        XCTAssertEqual(overridden.discoveredSource, "Habitable environment override")
        XCTAssertEqual(workspace.environmentVariables.filter(\.isUserInput).map(\.key), ["TF_VAR_\(terraformKey)"])

        workspaceFile("\(terraformKey) = \"from-file\"", named: "terraform.tfvars")
        workspace.checkVariables()
        try await waitUntil { !workspace.isInspectingInputs }
        let fileWins = try XCTUnwrap(workspace.terraformVariables.first { $0.key == terraformKey })
        XCTAssertEqual(try fileWins.terraformJSONValue() as? String, "from-file")
        XCTAssertEqual(fileWins.discoveredSource, "terraform.tfvars")

        try workspace.removeEnvironmentVariable(appEnvironment)
        try await waitUntil { !workspace.isInspectingInputs }
        let restored = try XCTUnwrap(workspace.terraformVariables.first { $0.key == terraformKey })
        XCTAssertEqual(try restored.terraformJSONValue() as? String, "from-file")
        XCTAssertEqual(restored.discoveredSource, "terraform.tfvars")
    }

    @MainActor
    func testInputMutationsValidateDuplicatesAndRetirePlansOnlyForEffectiveChanges() throws {
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        let variable = TerraformVariable()
        variable.key = "message"; variable.value = "one"
        try workspace.addTerraformVariable(variable)
        let initial = try generation(for: workspace)

        try workspace.updateTerraformVariable(variable, key: "message", value: "one", description: "note", sensitive: false, hcl: false)
        XCTAssertEqual(try generation(for: workspace), initial, "Description changes do not alter the planned inputs")
        try workspace.updateTerraformVariable(variable, key: "message", value: "two", description: "note", sensitive: false, hcl: false)
        let updated = try generation(for: workspace)
        XCTAssertGreaterThan(updated, initial)

        let duplicate = TerraformVariable()
        duplicate.key = "message"; duplicate.value = "duplicate"
        XCTAssertThrowsError(try workspace.addTerraformVariable(duplicate)) { error in
            XCTAssertTrue(error.localizedDescription.contains("listed more than once"))
        }

        let environment = EnvironmentVariable()
        environment.key = "APP_TOKEN"; environment.value = "first"
        try workspace.addEnvironmentVariable(environment)
        let withEnvironment = try generation(for: workspace)
        XCTAssertGreaterThan(withEnvironment, updated)
        try workspace.updateEnvironmentVariable(environment, key: "APP_TOKEN", value: "second", description: "", sensitive: false)
        let changedEnvironment = try generation(for: workspace)
        XCTAssertGreaterThan(changedEnvironment, withEnvironment)

        try workspace.removeTerraformVariable(variable)
        let removed = try generation(for: workspace)
        XCTAssertGreaterThan(removed, changedEnvironment)
        try workspace.removeEnvironmentVariable(environment)
        XCTAssertTrue(workspace.terraformVariables.isEmpty)
        XCTAssertTrue(workspace.environmentVariables.isEmpty)
        XCTAssertTrue(workspace.runs.isEmpty)
    }

    private func generation(for workspace: Workspace) throws -> Int64 {
        let lease = try workspace.acquireCommandLease()
        defer { lease.release() }
        return lease.generation
    }

    private func workspaceFile(_ contents: String, named name: String) {
        try! contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @MainActor
    func testWorkspaceDescriptionSurvivesRestartAndIsScopedToCanonicalDirectory() async throws {
        let descriptions = WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions"))
        let otherDirectory = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)

        let first = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator,
                              descriptionStore: descriptions)
        first.updateWorkingDirectory(dir: alias)
        try await waitUntil { !first.locked }
        first.description = "Manually written description"
        XCTAssertNil(first.descriptionPersistenceError)

        let reopened = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator,
                                 descriptionStore: descriptions)
        reopened.updateWorkingDirectory(dir: directory)
        try await waitUntil { !reopened.locked }
        XCTAssertEqual(reopened.description, "Manually written description")

        reopened.updateWorkingDirectory(dir: otherDirectory)
        try await waitUntil { !reopened.locked }
        XCTAssertEqual(reopened.description, "")
        reopened.description = "Other workspace"
        reopened.updateWorkingDirectory(dir: directory)
        try await waitUntil { !reopened.locked }
        XCTAssertEqual(reopened.description, "Manually written description")
    }

    @MainActor
    func testWorkspaceDescriptionSaveFailureIsVisibleAndKeepsEditedText() throws {
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedParent)
        let descriptions = WorkspaceDescriptionStore(directory: blockedParent.appendingPathComponent("descriptions"))
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator,
                                 descriptionStore: descriptions)
        workspace.updateWorkingDirectory(dir: directory)

        workspace.description = "Keep this edit visible"

        XCTAssertEqual(workspace.description, "Keep this edit visible")
        XCTAssertTrue(workspace.descriptionPersistenceError?.contains("Cannot save the workspace description") == true)
    }

    @MainActor
    func testUnsavedDescriptionBlocksFolderChangeUntilRetrySucceeds() async throws {
        let blockedParent = root.appendingPathComponent("description-storage-blocker")
        try Data("file".utf8).write(to: blockedParent)
        let descriptions = WorkspaceDescriptionStore(directory: blockedParent.appendingPathComponent("descriptions"))
        let otherDirectory = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults, commandCoordinator: testCommandCoordinator,
                                  descriptionStore: descriptions)
        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }

        workspace.description = "Keep this unsaved edit"
        XCTAssertTrue(workspace.descriptionNeedsSave)
        workspace.updateWorkingDirectory(dir: otherDirectory)

        XCTAssertEqual(workspace.workingDirectory, directory)
        XCTAssertEqual(workspace.description, "Keep this unsaved edit")
        XCTAssertTrue(workspace.descriptionNeedsSave)

        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        workspace.retrySavingWorkspaceDescription()
        XCTAssertFalse(workspace.descriptionNeedsSave)
        XCTAssertNil(workspace.descriptionPersistenceError)

        workspace.updateWorkingDirectory(dir: otherDirectory)
        try await waitUntil { !workspace.locked }
        XCTAssertEqual(workspace.workingDirectory, otherDirectory)
        XCTAssertEqual(workspace.description, "")

        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }
        XCTAssertEqual(workspace.description, "Keep this unsaved edit")
    }

    @MainActor
    func testExternalTerraformWorkspaceSelectionInvalidatesEarlierGeneration() throws {
        let terraformDirectory = directory.appendingPathComponent(".terraform")
        try FileManager.default.createDirectory(at: terraformDirectory, withIntermediateDirectories: true)
        try #"{"backend":{"type":"local","hash":12345,"config":{}}}"#
            .write(to: terraformDirectory.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
                                  commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.workingDirectory = directory
        let initial = try workspace.acquireCommandLease()
        let initialGeneration = initial.generation
        initial.release()

        try "production\n".write(to: terraformDirectory.appendingPathComponent("environment"), atomically: true, encoding: .utf8)
        let changed = try workspace.acquireCommandLease()
        XCTAssertEqual(workspace.selectedTerraformWorkspace, "production")
        XCTAssertGreaterThan(changed.generation, initialGeneration)
        changed.release()
    }

    @MainActor
    func testValidateAndPlanRecoveryDoesNotStartPlanUntilValidationSucceeds() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"fixture"}' ;;
          validate)
            if [ ! -f ready ]; then echo 'Fix configuration before retrying' >&2; exit 1; fi
            echo 'Valid configuration'
            ;;
          plan)
            touch plan-started
            echo '{"type":"version","ui":"1.2","terraform":"fixture"}'
            echo '{"type":"change_summary","changes":{"add":0,"change":0,"remove":0}}'
            ;;
          show) echo '{"format_version":"1.0","resource_changes":[]}' ;;
        esac
        """)
        let workspace = Workspace(restoreLastDirectory: false, defaults: testDefaults,
            historyStore: RunHistoryStore(directory: root.appendingPathComponent("history")),
            commandCoordinator: testCommandCoordinator, descriptionStore: testDescriptionStore)
        workspace.runner = Runner(executableURL: executable)
        workspace.workingDirectory = directory
        workspace.validateAndQueueRun()
        try await waitUntil { !workspace.locked }
        XCTAssertFalse(workspace.isValid)
        XCTAssertTrue(workspace.errorMessage?.contains("Fix configuration") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("plan-started").path))
        XCTAssertTrue(workspace.runs.isEmpty)

        try Data().write(to: directory.appendingPathComponent("ready"))
        workspace.validateAndQueueRun()
        try await waitUntil { workspace.runs.first?.status == .planned && !workspace.locked }
        XCTAssertTrue(workspace.isValid)
        XCTAssertNil(workspace.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("plan-started").path))
        XCTAssertEqual(workspace.runs.count, 1)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Terraform fixture did not finish in time")
    }
}
