import Foundation
import XCTest
@testable import HabitableCore

final class LocalCloudConnectionsTests: XCTestCase {
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
