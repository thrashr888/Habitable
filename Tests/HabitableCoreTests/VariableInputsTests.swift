import Foundation
import XCTest
@testable import HabitableCore

final class VariableInputsTests: XCTestCase {
    func testTerraformVariableSerializesStringAndStructuredJSONValues() throws {
        let string = TerraformVariable()
        string.key = "message"
        string.value = "east=west"

        let list = TerraformVariable()
        list.key = "subnets"
        list.value = "[\"a\", \"b\"]"
        list.hcl = true

        let map = TerraformVariable()
        map.key = "settings"
        map.value = #"{"enabled": true, "count": 3}"#
        map.hcl = true

        let boolean = TerraformVariable()
        boolean.key = "enabled"
        boolean.value = "false"
        boolean.hcl = true

        XCTAssertEqual(try string.terraformJSONValue() as? String, "east=west")
        XCTAssertEqual(try list.terraformJSONValue() as? [String], ["a", "b"])
        let parsedMap = try XCTUnwrap(try map.terraformJSONValue() as? [String: Any])
        XCTAssertEqual(parsedMap["enabled"] as? Bool, true)
        XCTAssertEqual(parsedMap["count"] as? Int, 3)
        XCTAssertEqual(try boolean.terraformJSONValue() as? Bool, false)
    }

    func testTerraformVariableRejectsInvalidKeysAndMalformedStructuredValues() {
        let invalidKey = TerraformVariable()
        invalidKey.key = "bad-name"
        invalidKey.value = "value"
        XCTAssertNotNil(invalidKey.validationError)

        let invalidJSON = TerraformVariable()
        invalidJSON.key = "value"
        invalidJSON.value = "[not json]"
        invalidJSON.hcl = true
        XCTAssertNotNil(invalidJSON.validationError)
    }

    func testEnvironmentVariableValidationAndSensitiveMetadata() throws {
        let variable = EnvironmentVariable()
        variable.key = "APP_TOKEN"
        variable.value = "secret"
        variable.sensitive = true
        try variable.validate()
        XCTAssertTrue(variable.sensitive)

        variable.key = "BAD=KEY"
        XCTAssertThrowsError(try variable.validate())
    }

    func testPlanPassesSavedVariablesAndEnvironmentOverridesToTerraform() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Habitable variable inputs \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capturedVariableFile = directory.appendingPathComponent("captured.json")

        let executable = directory.appendingPathComponent("terraform fake")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@"
        printf 'APP_TOKEN=%s\n' "$APP_TOKEN"
        for arg in "$@"; do
          case "$arg" in
            -var-file=*) cp "${arg#-var-file=}" "$CAPTURE" ;;
          esac
        done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = Runner(executableURL: executable,
                            environment: ["PATH": "/bin:/usr/bin", "APP_TOKEN": "original", "CAPTURE": capturedVariableFile.path])

        let variable = TerraformVariable()
        variable.key = "message"
        variable.value = "east=west"
        let structured = TerraformVariable()
        structured.key = "settings"
        structured.value = #"{"enabled": true, "regions": ["a", "b"]}"#
        structured.hcl = true
        let secret = EnvironmentVariable()
        secret.key = "APP_TOKEN"
        secret.value = "test-secret"
        secret.sensitive = true

        let output = await withCheckedContinuation { continuation in
            runner.plan(workingDirectory: directory, runId: "inputs",
                        variables: [variable, structured], environmentVariables: [secret]) { output, error in
                XCTAssertNil(error)
                continuation.resume(returning: output)
            }
        }

        let text = try XCTUnwrap(output)
        XCTAssertTrue(text.contains("APP_TOKEN=test-secret"))
        XCTAssertTrue(text.contains("-var-file="))
        let variableFileData = try Data(contentsOf: capturedVariableFile)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: variableFileData) as? [String: Any])
        XCTAssertEqual(values["message"] as? String, "east=west")
        let settings = try XCTUnwrap(values["settings"] as? [String: Any])
        XCTAssertEqual(settings["enabled"] as? Bool, true)
        XCTAssertEqual(settings["regions"] as? [String], ["a", "b"])
    }
}
