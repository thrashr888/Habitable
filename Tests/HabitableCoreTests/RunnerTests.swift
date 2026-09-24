import XCTest
@testable import HabitableCore

final class RunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable tests ' \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func result(_ start: (@escaping Runner.Completion) -> Void) async -> (String?, TerraformCommandError?) {
        await withCheckedContinuation { continuation in
            start { output, error in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: (output, error))
            }
        }
    }

    private func fakeCLI(_ script: String) throws -> URL {
        let executable = directory.appendingPathComponent("terraform executable")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testMissingTerraformReportsErrorInsteadOfCrashing() async {
        let runner = Runner(environment: ["PATH": ""], searchPaths: [])
        let (output, error) = await result { runner.validate(workingDirectory: directory, completion: $0) }
        XCTAssertNil(output)
        XCTAssertTrue(error?.message.contains("Terraform was not found") == true)
    }

    func testInvalidOverrideDoesNotSilentlySelectAnotherTerraform() async {
        let runner = Runner(environment: ["HABITABLE_TERRAFORM_PATH": "/missing/terraform", "PATH": "/opt/homebrew/bin"])
        XCTAssertNil(runner.executableURL)
    }

    func testArgumentsAndDirectoryArePassedLiterally() async throws {
        let executable = try fakeCLI("printf '%s\\n' \"$PWD\" \"$@\"\n")
        let runner = Runner(executableURL: executable)
        let (output, error) = await result { runner.plan(workingDirectory: directory, runId: "test-plan", completion: $0) }
        XCTAssertNil(error)
        let lines = try XCTUnwrap(output).split(separator: "\n").map(String.init)
        XCTAssertEqual(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertEqual(Array(lines.dropFirst()), ["plan", "-input=false", "-json", "-out=\(runner.planURL(runId: "test-plan").path)"])
    }

    func testLargeOutputAndNonzeroExitPreserveBothStreams() async throws {
        let executable = try fakeCLI("i=0; while [ $i -lt 5000 ]; do echo stdout-line; echo stderr-line >&2; i=$((i+1)); done; exit 7\n")
        let runner = Runner(executableURL: executable)
        let (output, error) = await result { runner.validate(workingDirectory: directory, completion: $0) }
        XCTAssertNil(output)
        XCTAssertEqual(error?.output.components(separatedBy: "stdout-line").count, 5001)
        XCTAssertEqual(error?.message.components(separatedBy: "stderr-line").count, 5001)
    }

    func testApplyUsesSavedPlanWithoutAutoApprove() async throws {
        let executable = try fakeCLI("printf '%s\\n' \"$@\"\n")
        let runner = Runner(executableURL: executable)
        let (output, error) = await result { runner.apply(workingDirectory: directory, runId: "reviewed", completion: $0) }
        XCTAssertNil(error)
        XCTAssertEqual(output?.split(separator: "\n").map(String.init), ["apply", "-input=false", "-json", runner.planURL(runId: "reviewed").path])
    }

    func testRealTerraformLocalWorkflow() async throws {
        guard let path = ProcessInfo.processInfo.environment["HABITABLE_TEST_TERRAFORM"] else {
            throw XCTSkip("Set HABITABLE_TEST_TERRAFORM to run the local-only integration test.")
        }
        let config = directory.appendingPathComponent("main.tf")
        try "resource \"terraform_data\" \"example\" { input = \"local only\" }\noutput \"greeting\" { value = \"reviewed plan\" }\n".write(to: config, atomically: true, encoding: .utf8)
        let runner = Runner(executableURL: URL(fileURLWithPath: path))
        let (_, initError) = await result { runner.initialize(workingDirectory: directory, completion: $0) }
        XCTAssertNil(initError)
        let (_, validateError) = await result { runner.validate(workingDirectory: directory, completion: $0) }
        XCTAssertNil(validateError)
        let (plan, planError) = await result { runner.plan(workingDirectory: directory, runId: "integration", completion: $0) }
        XCTAssertNil(planError)
        XCTAssertFalse(handleNDJsonSuccess(try XCTUnwrap(plan)).versions.isEmpty)
        // The configuration changes after review; Apply must still use the saved plan.
        try "output \"greeting\" { value = \"unreviewed change\" }\n".write(to: config, atomically: true, encoding: .utf8)
        let (apply, applyError) = await result { runner.apply(workingDirectory: directory, runId: "integration", completion: $0) }
        XCTAssertNil(applyError)
        let applied = handleNDJsonSuccess(try XCTUnwrap(apply))
        XCTAssertEqual(applied.resources.first?.stages.last?.state, .Created)
        XCTAssertEqual(applied.resources.first?.stages.last?.done, true)
        let (state, showError) = await result { runner.show(workingDirectory: directory, completion: $0) }
        XCTAssertNil(showError)
        let parsedState = transformShow(parseJsonOutput(try XCTUnwrap(state)))
        XCTAssertEqual(parsedState.resources.first?.values?["input"]?.string, "local only")
        XCTAssertTrue(try XCTUnwrap(state).contains("reviewed plan"))
        XCTAssertFalse(try XCTUnwrap(state).contains("unreviewed change"))
        runner.discardPlan(runId: "integration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.planURL(runId: "integration").path))
    }
}
