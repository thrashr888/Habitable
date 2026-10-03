import Foundation
import MCP
import XCTest
@testable import HabitableCore

final class AgentConnectionModelTests: XCTestCase {
    func testJSONInstallPreservesOtherEntriesAndCreatesBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("client.json")
        try #"{"theme":"dark","mcpServers":{"other":{"command":"keep"}}}"#.write(to: config, atomically: true, encoding: .utf8)

        try AgentJSONConfigurationEditor.install(serverName: "habitable", server: ["url": "http://127.0.0.1:1/mcp"], at: config)

        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(result["theme"] as? String, "dark")
        let servers = try XCTUnwrap(result["mcpServers"] as? [String: [String: String]])
        XCTAssertEqual(servers["other"]?["command"], "keep")
        XCTAssertEqual(servers["habitable"]?["url"], "http://127.0.0.1:1/mcp")
        XCTAssertTrue(AgentJSONConfigurationEditor.configured(serverName: "habitable", at: config))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testMalformedJSONIsLeftUntouched() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: config) }
        try "{broken".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentJSONConfigurationEditor.install(serverName: "habitable", server: [:], at: config))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{broken")
    }

    func testMCPRequestPolicyRequiresPathPostBearerAndBoundedBody() {
        let token = String(repeating: "x", count: HabitableMCPRequestPolicy.bearerTokenBytes)
        let goodHeaders = ["authorization": "Bearer \(token)"]
        let body = Data("{}".utf8)
        XCTAssertNil(HabitableMCPRequestPolicy.rejection(method: "POST", path: "/mcp", headers: goodHeaders, body: body, token: token))
        XCTAssertEqual(HabitableMCPRequestPolicy.rejection(method: "GET", path: "/mcp", headers: goodHeaders, body: body, token: token)?.0, 405)
        XCTAssertEqual(HabitableMCPRequestPolicy.rejection(method: "POST", path: "/elsewhere", headers: goodHeaders, body: body, token: token)?.0, 404)
        XCTAssertEqual(HabitableMCPRequestPolicy.rejection(method: "POST", path: "/mcp", headers: [:], body: body, token: token)?.0, 401)
        XCTAssertEqual(HabitableMCPRequestPolicy.rejection(method: "POST", path: "/mcp", headers: goodHeaders, body: Data(repeating: 0, count: HabitableMCPRequestPolicy.maximumRequestBytes + 1), token: token)?.0, 413)
    }

    @MainActor
    func testLiveListenerAuthenticatesAndCompletesMCPInitializeListAndCall() async throws {
        let expectedStatus = "selected workspace: fixture"
        let actions = HabitableMCPActions(
            workspaceStatus: { expectedStatus }, declarations: { "declarations" },
            resourceMetadata: { "resources" }, outputMetadata: { "outputs" },
            runSummaries: { "runs" }, diagnostics: { "diagnostics" },
            validate: { "valid" }, requestPlan: { "plan queued" }, runStatus: { _ in "complete" }
        )
        let server = HabitableMCPServer(actions: actions)
        try await server.startListening()
        let endpoint = try XCTUnwrap(server.endpointURL)
        defer { Task { @MainActor in await server.stop() } }

        var unauthorizedRequest = URLRequest(url: endpoint)
        unauthorizedRequest.httpMethod = "POST"
        unauthorizedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthorizedRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        unauthorizedRequest.httpBody = Data("{}".utf8)
        let (_, unauthorizedResponse) = try await URLSession.shared.data(for: unauthorizedRequest)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)

        let client = Client(name: "HabitableTests", version: "1.0")
        let token = server.bearerToken
        let modifier: @Sendable (URLRequest) -> URLRequest = { request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        let transport = HTTPClientTransport(
            endpoint: endpoint, streaming: false,
            requestModifier: modifier
        )
        _ = try await client.connect(transport: transport)
        let (tools, _) = try await client.listTools()
        XCTAssertTrue(tools.contains(where: { $0.name == "workspace_status" }))
        let (content, isError) = try await client.callTool(name: "workspace_status", arguments: [:])
        XCTAssertFalse(isError ?? false)
        guard case .text(let text, _, _) = try XCTUnwrap(content.first) else {
            return XCTFail("Expected workspace status text")
        }
        XCTAssertEqual(text, expectedStatus)
        await client.disconnect()
        await server.stop()
        XCTAssertNil(server.endpointURL)
        XCTAssertEqual(server.runtimeState, .stopped)
    }

    @MainActor
    func testLiveListenerCanRestartAfterStop() async throws {
        let actions = HabitableMCPActions(
            workspaceStatus: { "ok" }, declarations: { "" }, resourceMetadata: { "" },
            outputMetadata: { "" }, runSummaries: { "" }, diagnostics: { "" },
            validate: { "" }, requestPlan: { "" }, runStatus: { _ in "" }
        )
        let server = HabitableMCPServer(actions: actions)
        try await server.startListening()
        XCTAssertNotNil(server.endpointURL)
        await server.stop()
        XCTAssertNil(server.endpointURL)
        try await server.startListening()
        XCTAssertNotNil(server.endpointURL)
        await server.stop()
        XCTAssertEqual(server.runtimeState, .stopped)
    }

    func testSkillDescribesPlanOnlyAndSecretBoundaries() {
        XCTAssertTrue(HabitableAgentSkill.markdown.contains("plan-only"))
        XCTAssertTrue(HabitableAgentSkill.markdown.contains("credentials"))
        XCTAssertTrue(HabitableAgentSkill.markdown.contains("selected workspace"))
    }

    func testHTTPParserAcceptsBoundedContentLengthAndRejectsChunking() {
        let valid = Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nAuthorization: Bearer token\r\n\r\n{}".utf8)
        guard case .request("POST", "/mcp", let headers, let body) = HabitableMCPHTTPParser.parse(valid) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(headers["authorization"], "Bearer token")
        XCTAssertEqual(String(data: body, encoding: .utf8), "{}")
        let chunked = Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n".utf8)
        guard case .invalid(400, _) = HabitableMCPHTTPParser.parse(chunked) else {
            return XCTFail("Chunked requests must be rejected")
        }
    }

    func testStdioClientConfigDoesNotContainBearerToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:43129/mcp"))
        let script = try HabitableStdioBridgeInstaller.prepare(endpoint: endpoint, bearerToken: "private-token", in: directory)
        let config = directory.appendingPathComponent("agent.json")
        try HabitableStdioBridgeInstaller.installInClientConfiguration(script: script, at: config)
        let configText = try String(contentsOf: config, encoding: .utf8)
        let credentialsText = try String(contentsOf: directory.appendingPathComponent("habitable-mcp-stdio.json"), encoding: .utf8)
        XCTAssertFalse(configText.contains("private-token"))
        XCTAssertTrue(credentialsText.contains("private-token"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("habitable-mcp-stdio.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
