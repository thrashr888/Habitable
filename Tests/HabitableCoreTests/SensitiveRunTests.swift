import Foundation
import XCTest
@testable import HabitableCore

@MainActor
final class SensitiveRunTests: XCTestCase {
    func testDiscoveredSensitiveValuesAreRedactedWithoutCreatingOverrides() {
        let discovered = TerraformVariable()
        discovered.key = "token"
        discovered.value = "\"discovered-secret-value\""
        discovered.hcl = true
        discovered.sensitive = true
        let defaulted = TerraformVariable()
        defaulted.key = "default_token"
        defaulted.sensitive = true
        defaulted.declaration = TerraformDeclaredInput(name: "default_token", type: "string", description: nil,
            hasDefault: true, defaultJSON: Data("\"default-secret-value\"".utf8), required: false,
            sensitive: true, ephemeral: false, sourceFile: "main.tf", sourceLine: 1)
        let environment = EnvironmentVariable()
        environment.key = "TF_VAR_token"
        environment.value = "environment-discovered-secret"
        environment.sensitive = true
        let redactor = SensitiveInputRedactor(variables: [discovered, defaulted], environmentVariables: [environment])
        XCTAssertFalse(discovered.isUserInput)
        XCTAssertFalse(environment.isUserInput)
        let result = redactor.redact("discovered-secret-value environment-discovered-secret default-secret-value")
        XCTAssertFalse(result.contains("discovered-secret-value"))
        XCTAssertFalse(result.contains("environment-discovered-secret"))
        XCTAssertFalse(result.contains("default-secret-value"))
    }

    @MainActor
    func testRunSnapshotRedactsPlanReviewApplyErrorsAndHistoryButKeepsSavedPlanBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable sensitive run \(UUID())")
        let directory = root.appendingPathComponent("workspace")
        let history = RunHistoryStore(directory: root.appendingPathComponent("history"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("terraform fake")
        let applyCapture = root.appendingPathComponent("applied-plan-copy")
        let script = #"""
        #!/bin/sh
        case "$1" in
          version) echo '{"terraform_version":"1.16.4"}' ;;
          plan)
            for arg in "$@"; do
              case "$arg" in
                -var-file=*) cp "${arg#-var-file=}" "$PLAN_PATH" ;;
                -out=*) cp "$PLAN_PATH" "${arg#-out=}" ;;
              esac
            done
            printf '{"type":"diagnostic","diagnostic":{"severity":"warning","summary":"plan detail","detail":"%s"}}\n' "$APP_TOKEN"
            ;;
          show)
            if [ -n "$3" ]; then
              echo '{"format_version":"1.0","resource_changes":[{"address":"terraform_data.example","change":{"actions":["create"],"before":null,"after":{"input":"string-secret-value","nested":"nested-secret-value"},"before_sensitive":{},"after_sensitive":{},"after_unknown":{}}}]}'
            else
              echo '{"values":{"root_module":{"resources":[]}}}'
            fi
            ;;
          apply)
            cp "$4" "$PLAN_CAPTURE"
            printf '{"type":"diagnostic","diagnostic":{"severity":"warning","summary":"apply detail","detail":"%s"}}\n' "$APP_TOKEN"
            printf 'apply failed: %s\n' "$APP_TOKEN" >&2
            exit 1
            ;;
        esac
        """#
        try script.write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)

        let defaults = UserDefaults(suiteName: "Habitable-sensitive-\(UUID().uuidString)")!
        let workspace = Workspace(restoreLastDirectory: false, defaults: defaults, historyStore: history,
                                  commandCoordinator: WorkspaceCommandCoordinator(directory: root.appendingPathComponent("coordination")),
                                  descriptionStore: WorkspaceDescriptionStore(directory: root.appendingPathComponent("descriptions")))
        workspace.runner = Runner(executableURL: source,
                                  environment: ["PATH": "/bin:/usr/bin", "APP_TOKEN": "environment-secret-value",
                                                "PLAN_PATH": root.appendingPathComponent("temporary-plan").path,
                                                "PLAN_CAPTURE": applyCapture.path])
        workspace.workingDirectory = directory
        workspace.terraformVersion = "1.16.4"
        workspace.isValid = true

        let string = TerraformVariable()
        string.key = "message"
        string.value = "string-secret-value"
        string.sensitive = true
        string.isUserInput = true
        let structured = TerraformVariable()
        structured.key = "settings"
        structured.value = #"{"auth":{"token":"nested-secret-value","items":["deep-secret-value"]}}"#
        structured.hcl = true
        structured.sensitive = true
        structured.isUserInput = true
        let environment = EnvironmentVariable()
        environment.key = "APP_TOKEN"
        environment.value = "environment-secret-value"
        environment.sensitive = true
        environment.isUserInput = true
        workspace.terraformVariables = [string, structured]
        workspace.environmentVariables = [environment]

        let record = try history.create(workspace: directory, terraformVersion: "1.16.4", message: nil)
        let run = TerraformRun(workspace: workspace, record: record, restored: false)
        workspace.runs = [run]
        await withCheckedContinuation { continuation in
            run.doPlan { _, error in
                XCTAssertNil(error)
                continuation.resume()
            }
        }
        try await waitUntil { !workspace.locked }

        let planURL = workspace.runner.planURL(runId: run.id.uuidString)
        let reviewedPlanBytes = try Data(contentsOf: planURL)
        let reviewedInputs = try XCTUnwrap(JSONSerialization.jsonObject(with: reviewedPlanBytes) as? [String: Any])
        XCTAssertEqual(reviewedInputs["message"] as? String, "string-secret-value")
        let reviewedSettings = try XCTUnwrap(reviewedInputs["settings"] as? [String: Any])
        let reviewedAuth = try XCTUnwrap(reviewedSettings["auth"] as? [String: Any])
        XCTAssertEqual(reviewedAuth["token"] as? String, "nested-secret-value")
        XCTAssertEqual(run.status, .planned)

        // The run must keep protecting the values it started with even if the
        // editor model changes after the Terraform command begins.
        string.value = "replacement-string-value"
        structured.value = #"{"auth":{"token":"replacement-nested-value"}}"#
        environment.value = "replacement-environment-value"

        guard let change = run.planDiff?.resourceChanges.first,
              let input = change.attributes.first(where: { $0.path == "$[\"input\"]" }) else {
            return XCTFail("Expected the saved plan review to include the input attribute")
        }
        XCTAssertEqual(input.after, .value("(sensitive)"))
        XCTAssertFalse(String(describing: run.planDiff).contains("string-secret-value"))
        XCTAssertFalse(run.plan?.diagnostics.first?.diagnostic.detail?.contains("environment-secret-value") == true)
        XCTAssertFalse(run.textOutput?.contains("environment-secret-value") == true)

        // Restore the reviewed inputs before confirmation. Context verification now
        // intentionally rejects changed editor values rather than applying them.
        string.value = "string-secret-value"
        structured.value = #"{"auth":{"token":"nested-secret-value","items":["deep-secret-value"]}}"#
        environment.value = "environment-secret-value"

        await withCheckedContinuation { continuation in
            run.doApply { _, error in
                XCTAssertTrue(error?.contains("(sensitive)") == true)
                XCTAssertFalse(error?.contains("environment-secret-value") == true)
                continuation.resume()
            }
        }
        try await waitUntil { !workspace.locked }

        XCTAssertEqual(try Data(contentsOf: applyCapture), reviewedPlanBytes,
                       "Apply must receive the exact binary artifact that was reviewed.")
        XCTAssertFalse(run.apply?.diagnostics.first?.diagnostic.detail?.contains("environment-secret-value") == true)
        XCTAssertFalse(run.textOutput?.contains("environment-secret-value") == true)
        let saved = try XCTUnwrap(history.load(workspace: directory).first)
        for output in [saved.planOutput, saved.applyOutput, saved.errorMessage].compactMap({ $0 }) {
            for secret in ["string-secret-value", "nested-secret-value", "deep-secret-value", "environment-secret-value"] {
                XCTAssertFalse(output.contains(secret))
            }
        }
        XCTAssertTrue(saved.errorMessage?.contains("(sensitive)") == true)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Command did not finish in time")
    }
}
