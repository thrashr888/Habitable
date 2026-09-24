import XCTest
@testable import HabitableCore

final class WorkspaceModelTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable workspace \(UUID())")
        directory = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

        let first = Workspace(restoreLastDirectory: false)
        first.runner = Runner(executableURL: executable)
        first.workingDirectory = directory
        first.initialize()
        try await waitUntil { !first.locked }
        XCTAssertTrue(first.isInitialized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".terraform").path))
        first.initialize()
        try await waitUntil { !first.locked }
        XCTAssertTrue(first.isInitialized, "Repeated successful inits should keep the workspace initialized")

        let reopened = Workspace(restoreLastDirectory: false)
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

        let workspace = Workspace(restoreLastDirectory: false)
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
    func testEmptyShowDoesNotPretendStateIsAvailable() async throws {
        let executable = try fakeTerraform("""
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          validate) echo '{"valid":true}' ;;
          show) echo '{"values":null}' ;;
        esac
        """)
        let workspace = Workspace(restoreLastDirectory: false)
        workspace.runner = Runner(executableURL: executable)
        workspace.updateWorkingDirectory(dir: directory)
        try await waitUntil { !workspace.locked }

        XCTAssertTrue(workspace.isValid)
        XCTAssertFalse(workspace.hasState)
        XCTAssertNil(workspace.state)
        XCTAssertTrue(workspace.errorMessage?.contains("no state data") == true)
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
        lease.release()
        XCTAssertThrowsError(try coordinator.acquire(workspace: directory, contextIdentity: "workspace=default;backend=local"))
    }

    @MainActor
    func testReadsSelectedTerraformWorkspaceAndBackendIdentity() throws {
        let terraformDirectory = directory.appendingPathComponent(".terraform")
        try FileManager.default.createDirectory(at: terraformDirectory, withIntermediateDirectories: true)
        try "production\n".write(to: terraformDirectory.appendingPathComponent("environment"), atomically: true, encoding: .utf8)
        try #"{"backend":{"type":"remote","hash":12345,"config":{}}}"#
            .write(to: terraformDirectory.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreLastDirectory: false,
                                  commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")))
        workspace.workingDirectory = directory

        let lease = try workspace.acquireCommandLease()
        XCTAssertEqual(workspace.selectedTerraformWorkspace, "production")
        XCTAssertEqual(workspace.backendIdentity, "remote #12345")
        XCTAssertTrue(workspace.executionContextIdentifier.hasPrefix("workspace=production;backend=remote #12345;terraform="))
        XCTAssertEqual(workspace.executionContextDisplay, "Workspace: production · Backend: remote #12345")
        lease.release()
    }

    @MainActor
    func testExternalTerraformWorkspaceSelectionInvalidatesEarlierGeneration() throws {
        let terraformDirectory = directory.appendingPathComponent(".terraform")
        try FileManager.default.createDirectory(at: terraformDirectory, withIntermediateDirectories: true)
        try #"{"backend":{"type":"local","hash":12345,"config":{}}}"#
            .write(to: terraformDirectory.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreLastDirectory: false,
                                  commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")))
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
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Terraform fixture did not finish in time")
    }
}
