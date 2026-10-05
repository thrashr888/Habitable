import Foundation
import XCTest
@testable import HabitableCore

final class LocalCloudConnectionsTests: XCTestCase {
    private actor LoginHarness {
        var authenticated = false
        var loginResult = CloudCommandResult(exitCode: 0, output: "", timedOut: false)
        var logins: [(String, [String], [String: String], TimeInterval)] = []
        var discoveryCalls: [[String]] = []

        func setAuthenticated(_ value: Bool) { authenticated = value }
        func setLoginResult(_ value: CloudCommandResult) { loginResult = value }
        func recordLogin(_ executable: String, _ args: [String], _ env: [String: String], _ timeout: TimeInterval) -> CloudCommandResult {
            logins.append((executable, args, env, timeout))
            return loginResult
        }
        func loginCount() -> Int { logins.count }
        func lastLogin() -> (String, [String], [String: String], TimeInterval)? { logins.last }
        func recordDiscovery(_ args: [String]) -> (Bool, [[String]]) {
            discoveryCalls.append(args)
            return (authenticated, discoveryCalls)
        }
    }

    private func connectionRunner(_ harness: LoginHarness) -> CloudCommandRunner {
        { _, args, _, _ in
            let (authenticated, _) = await harness.recordDiscovery(args)
            let command = args.joined(separator: " ")
            guard authenticated else { return .init(exitCode: 1, output: "private credential diagnostic", timedOut: false) }
            switch command {
            case "configure list-profiles": return .init(exitCode: 0, output: "default\n", timedOut: false)
            case "sts get-caller-identity --output json": return .init(exitCode: 0, output: #"{"Account":"123","Arn":"arn:aws:iam::123:user/test"}"#, timedOut: false)
            case "account show --output json": return .init(exitCode: 0, output: #"{"name":"Test subscription","id":"sub-id","tenantId":"tenant","user":{"name":"test@example.com"}}"#, timedOut: false)
            case "account get-access-token --query expiresOn --output tsv": return .init(exitCode: 0, output: "expires", timedOut: false)
            case "config get-value account": return .init(exitCode: 0, output: "test@example.com\n", timedOut: false)
            case "config get-value project": return .init(exitCode: 0, output: "test-project\n", timedOut: false)
            case "auth print-access-token", "auth application-default print-access-token": return .init(exitCode: 0, output: "token", timedOut: false)
            default: return .init(exitCode: 1, output: "", timedOut: false)
            }
        }
    }

    @MainActor
    func testConnectRunsProviderSpecificLoginAndRefreshesAfterSuccess() async {
        let expected: [(String, String, [String])] = [
            ("aws", "aws", ["login"]),
            ("azure", "az", ["login"]),
            ("gcp", "gcloud", ["auth", "login", "--update-adc"])
        ]
        for (id, executable, arguments) in expected {
            let harness = LoginHarness()
            let model = LocalCloudConnectionsModel(environment: ["PATH": "/usr/bin", "AWS_PROFILE": "qa"],
                runner: connectionRunner(harness),
                loginRunner: { cli, args, env, timeout in
                    let result = await harness.recordLogin(cli.lastPathComponent, args, env, timeout)
                    await harness.setAuthenticated(true)
                    return result
                },
                executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
            await model.refresh()
            XCTAssertTrue(model.canConnect(id))
            await model.connect(id)
            let login = await harness.lastLogin()
            XCTAssertEqual(login?.0, executable)
            XCTAssertEqual(login?.1, arguments)
            XCTAssertEqual(login?.2["AWS_PROFILE"], "qa")
            XCTAssertEqual(login?.3, 600)
            XCTAssertTrue(model.connections.first(where: { $0.id == id })?.isAuthenticated == true)
            XCTAssertNil(model.loginMessages[id])
            XCTAssertNil(model.connectingID)
        }
    }

    @MainActor
    func testConnectedAccountsAndMissingCLIsDoNotLaunchLogin() async {
        let connectedHarness = LoginHarness()
        await connectedHarness.setAuthenticated(true)
        let connected = LocalCloudConnectionsModel(environment: ["PATH": "/bin"], runner: connectionRunner(connectedHarness),
            loginRunner: { cli, args, env, timeout in await connectedHarness.recordLogin(cli.path, args, env, timeout) },
            executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
        await connected.refresh()
        XCTAssertFalse(connected.canConnect("aws"))
        await connected.connect("aws")
        let connectedLoginCount = await connectedHarness.loginCount()
        XCTAssertEqual(connectedLoginCount, 0)

        let missingHarness = LoginHarness()
        let missing = LocalCloudConnectionsModel(environment: ["PATH": ""], runner: connectionRunner(missingHarness),
            loginRunner: { cli, args, env, timeout in await missingHarness.recordLogin(cli.path, args, env, timeout) },
            executableLookup: { _, _ in nil })
        await missing.refresh()
        XCTAssertFalse(missing.canConnect("azure"))
        await missing.connect("azure")
        let missingLoginCount = await missingHarness.loginCount()
        XCTAssertEqual(missingLoginCount, 0)
    }

    @MainActor
    func testFailedAndTimedOutLoginMessagesDoNotExposeRunnerOutput() async {
        for result in [CloudCommandResult(exitCode: 9, output: "SECRET diagnostic", timedOut: false),
                       CloudCommandResult(exitCode: -1, output: "SECRET diagnostic", timedOut: true)] {
            let harness = LoginHarness()
            await harness.setLoginResult(result)
            let model = LocalCloudConnectionsModel(environment: ["PATH": "/bin"], runner: connectionRunner(harness),
                loginRunner: { cli, args, env, timeout in await harness.recordLogin(cli.path, args, env, timeout) },
                executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
            await model.refresh()
            await model.connect("gcp")
            XCTAssertNil(model.connectingID)
            XCTAssertFalse(model.loginMessages["gcp", default: ""].contains("SECRET"))
            XCTAssertTrue(model.loginMessages["gcp", default: ""].contains(result.timedOut ? "Still waiting" : "did not finish"))
        }
    }

    func testLoginScriptQuotesShellInputsAndExcludesSecretEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable-login-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resultFile = folder.appendingPathComponent("result with ' quote")
        let injectionMarker = folder.appendingPathComponent("injected")
        let hostile = "value'; touch \(injectionMarker.path); printf '"
        let secret = "DO_NOT_STORE_SECRET"
        let script = LocalCloudConnectionsModel.loginScript(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [hostile],
            environment: ["PATH": "/usr/bin:/bin", "AWS_PROFILE": hostile, "SECRET_TOKEN": secret], resultFile: resultFile)
        XCTAssertFalse(script.contains(secret))
        let scriptURL = folder.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertEqual(try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: injectionMarker.path))
        XCTAssertTrue(script.contains("export AWS_PROFILE='value'\"'\"'"))
        XCTAssertFalse(script.contains("SECRET_TOKEN"))
    }

    @MainActor
    func testRefreshReportsAuthenticatedProviderMetadataWithoutTokens() async throws {
        let runner: CloudCommandRunner = { _, args, _, _ in
            let command = args.joined(separator: " ")
            if command == "configure list-profiles" { return .init(exitCode: 0, output: "default\ndev\n", timedOut: false) }
            if command == "sts get-caller-identity --output json" { return .init(exitCode: 0, output: #"{"Account":"123","Arn":"arn:aws:iam::123:user/me"}"#, timedOut: false) }
            if command == "account show --output json" { return .init(exitCode: 0, output: #"{"name":"Sub","id":"sub-id","tenantId":"tenant","user":{"name":"me@example.com"}}"#, timedOut: false) }
            if command == "account get-access-token --query expiresOn --output tsv" { return .init(exitCode: 0, output: "2030-01-01T00:00:00Z\n", timedOut: false) }
            if command == "config get-value account" { return .init(exitCode: 0, output: "gcp@example.com\n", timedOut: false) }
            if command == "config get-value project" { return .init(exitCode: 0, output: "project-x\n", timedOut: false) }
            if command == "auth print-access-token" || command == "auth application-default print-access-token" { return .init(exitCode: 0, output: "secret-token-must-not-appear", timedOut: false) }
            return .init(exitCode: 1, output: "", timedOut: false)
        }
        let model = LocalCloudConnectionsModel(environment: ["PATH": "/bin"], runner: runner, executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
        await model.refresh()
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.connections.map(\.id), ["aws", "azure", "gcp"])
        XCTAssertTrue(model.connections.allSatisfy(\.isAuthenticated))
        XCTAssertTrue(model.connections[0].details.contains("Profiles: default, dev"))
        XCTAssertTrue(model.connections[1].details.contains("Subscription: Sub"))
        XCTAssertTrue(model.connections[2].details.contains("Application Default Credentials: available"))
        XCTAssertFalse(model.connections.flatMap(\.details).joined().contains("secret-token"))
    }

    @MainActor
    func testMissingCLIsAndFailedChecksAreClearAndDoNotExposeStderr() async {
        let runner: CloudCommandRunner = { _, _, _, _ in .init(exitCode: 1, output: "private stderr or token", timedOut: false) }
        let missing = LocalCloudConnectionsModel(environment: ["PATH": "/definitely/missing"], runner: runner, executableLookup: { _, _ in nil })
        await missing.refresh()
        XCTAssertTrue(missing.connections.allSatisfy { $0.status == "CLI not installed" && !$0.isAuthenticated })
        XCTAssertTrue(missing.connections.allSatisfy { $0.details.isEmpty })

        let failing = LocalCloudConnectionsModel(environment: ["PATH": "/usr/bin:/bin"], runner: runner, executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
        await failing.refresh()
        XCTAssertTrue(failing.connections.allSatisfy { !$0.isAuthenticated })
        XCTAssertFalse(failing.connections.map(\.status).joined().contains("private stderr"))
        XCTAssertFalse(failing.connections.flatMap(\.details).joined().contains("private stderr"))
    }

    @MainActor
    func testTimeoutIsReportedAsFailure() async {
        let runner: CloudCommandRunner = { _, _, _, _ in .init(exitCode: -1, output: "", timedOut: true) }
        let model = LocalCloudConnectionsModel(environment: ["PATH": "/usr/bin:/bin"], runner: runner, executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
        await model.refresh()
        XCTAssertTrue(model.connections.allSatisfy { !$0.isAuthenticated && $0.status.localizedCaseInsensitiveContains("timed out") })
    }
    @MainActor
    func testMalformedAWSIdentityAndPartialGCPAuthenticationStayUnauthenticated() async {
        let runner: CloudCommandRunner = { _, args, _, _ in
            let command = args.joined(separator: " ")
            switch command {
            case "configure list-profiles": return .init(exitCode: 0, output: "default\n", timedOut: false)
            case "sts get-caller-identity --output json": return .init(exitCode: 0, output: "not-json", timedOut: false)
            case "account show --output json": return .init(exitCode: 0, output: "{}", timedOut: false)
            case "account get-access-token --query expiresOn --output tsv": return .init(exitCode: 0, output: "", timedOut: false)
            case "config get-value account": return .init(exitCode: 0, output: "selected@example.com\n", timedOut: false)
            case "config get-value project": return .init(exitCode: 1, output: "sensitive failure output", timedOut: false)
            case "auth print-access-token": return .init(exitCode: 0, output: "secret", timedOut: false)
            case "auth application-default print-access-token": return .init(exitCode: 1, output: "secret", timedOut: false)
            default: return .init(exitCode: 1, output: "", timedOut: false)
            }
        }
        let model = LocalCloudConnectionsModel(environment: ["PATH": ""], runner: runner, executableLookup: { name, _ in URL(fileURLWithPath: "/fake/\(name)") })
        await model.refresh()
        XCTAssertFalse(model.connections[0].isAuthenticated)
        XCTAssertFalse(model.connections[1].isAuthenticated)
        XCTAssertFalse(model.connections[0].details.contains(where: { $0.hasPrefix("Account:") }))
        XCTAssertFalse(model.connections[2].isAuthenticated)
        XCTAssertEqual(model.connections[2].status, "Sign-in incomplete: configure both CLI and ADC")
        XCTAssertFalse(model.connections[2].details.joined().contains("sensitive failure output"))
    }

}
