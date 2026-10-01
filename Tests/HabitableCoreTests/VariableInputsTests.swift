import Foundation
import XCTest
@testable import HabitableCore

@MainActor
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

    func testSensitiveInputRedactorProtectsStringsEnvironmentAndNestedJSON() throws {
        let string = TerraformVariable()
        string.isUserInput = true
        string.sensitive = true
        string.value = "string-secret-value"

        let structured = TerraformVariable()
        structured.isUserInput = true
        structured.sensitive = true
        structured.hcl = true
        structured.value = #"{"profile":{"token":"nested-secret-value","count":42,"enabled":false,"items":["deep-secret-value"]}}"#

        let environment = EnvironmentVariable()
        environment.isUserInput = true
        environment.sensitive = true
        environment.value = "environment-secret-value"

        let multiline = EnvironmentVariable()
        multiline.isUserInput = true
        multiline.sensitive = true
        multiline.value = "first-secret-line\nsecond-secret-line"

        let visible = TerraformVariable()
        visible.isUserInput = true
        visible.value = "public-value"

        let redactor = SensitiveInputRedactor(variables: [string, structured, visible],
                                              environmentVariables: [environment, multiline])
        let text = redactor.redact("string-secret-value environment-secret-value nested-secret-value deep-secret-value public-value\nfirst-secret-line\nsecond-secret-line")
        XCTAssertFalse(text.contains("string-secret-value"))
        XCTAssertFalse(text.contains("environment-secret-value"))
        XCTAssertFalse(text.contains("nested-secret-value"))
        XCTAssertFalse(text.contains("deep-secret-value"))
        XCTAssertFalse(text.contains("first-secret-line"))
        XCTAssertFalse(text.contains("second-secret-line"))
        XCTAssertTrue(text.contains("public-value"))

        let jsonLine = #"{"type":"diagnostic","diagnostic":{"detail":"nested-secret-value","extra":{"items":["deep-secret-value"],"count":42,"enabled":false}},"outputs":{"token":{"sensitive":true,"value":"nested-secret-value"}}}"#
        let sanitized = redactor.redact(jsonLine)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sanitized.utf8)) as? [String: Any])
        let diagnostic = try XCTUnwrap(object["diagnostic"] as? [String: Any])
        let detail = try XCTUnwrap(diagnostic["detail"] as? String)
        let extra = try XCTUnwrap(diagnostic["extra"] as? [String: Any])
        let items = try XCTUnwrap(extra["items"] as? [String])
        let outputs = try XCTUnwrap(object["outputs"] as? [String: [String: Any]])
        let token = try XCTUnwrap(outputs["token"])
        XCTAssertFalse(detail.contains("nested-secret-value"))
        XCTAssertFalse(items.joined().contains("deep-secret-value"))
        XCTAssertEqual(extra["count"] as? String, "(sensitive)")
        XCTAssertEqual(extra["enabled"] as? String, "(sensitive)")
        XCTAssertEqual(token["sensitive"] as? Bool, true)
        XCTAssertEqual(token["value"] as? String, "(sensitive)")
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
