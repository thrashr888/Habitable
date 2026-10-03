import Foundation
import XCTest
@testable import HabitableCore

final class HCPWorkspaceViewerTests: XCTestCase {
    override func setUp() {
        HCPURLProtocolStub.reset()
        super.setUp()
    }

    override func tearDown() {
        HCPURLProtocolStub.reset()
        super.tearDown()
    }

    func testWorkspaceListingUsesEncodedPaginationAndMapsWorkspaceIdentity() async throws {
        HCPURLProtocolStub.responses = [
            "/api/v2/organizations/pthrasher_v2/workspaces": #"{"data":[{"id":"ws-1","type":"workspaces","attributes":{"name":"habitable-prod","terraform-version":"1.10.0","execution-mode":"remote","locked":false}}],"links":{"next":"https://app.terraform.io/api/v2/organizations/pthrasher_v2/workspaces?page[number]=2"},"meta":{"pagination":{"total-count":51}}}"#.data(using: .utf8)!
        ]
        let result = try await makeClient().workspaces(hostname: "app.terraform.io", organization: "pthrasher_v2", token: "test-token", page: 1)
        XCTAssertEqual(result.items.map(\.id), ["ws-1"])
        XCTAssertEqual(result.items.first?.name, "habitable-prod")
        XCTAssertEqual(result.items.first?.terraformVersion, "1.10.0")
        XCTAssertTrue(result.hasNextPage)
        XCTAssertEqual(result.totalCount, 51)
        let request = try XCTUnwrap(HCPURLProtocolStub.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v2/organizations/pthrasher_v2/workspaces")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page[number]" })?.value, "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testRunHistoryPreservesRemoteRunIDAndReadsSignedLogsWithoutForwardingAPIToken() async throws {
        let signedURL = "https://archivist.terraform.io/v1/object/signed?token=do-not-store-this-url"
        HCPURLProtocolStub.responses = [
            "/api/v2/workspaces/ws-1/runs": #"{"data":[{"id":"run-remote-92","type":"runs","attributes":{"status":"applied","message":"scale service","operation":"plan_and_apply","created-at":"2026-10-03T12:00:00.000Z","has-changes":true,"is-destroy":false},"relationships":{"plan":{"data":{"id":"plan-9","type":"plans"}},"apply":{"data":{"id":"apply-9","type":"applies"}}}}],"links":{},"meta":{"pagination":{"total-count":1}}}"#.data(using: .utf8)!,
            "/api/v2/runs/run-remote-92": Data("""
            {"data":{"id":"run-remote-92","type":"runs","attributes":{"status":"applied","message":"scale service","operation":"plan_and_apply","created-at":"2026-10-03T12:00:00.000Z","has-changes":true,"is-destroy":false},"relationships":{"plan":{"data":{"id":"plan-9","type":"plans"}},"apply":{"data":{"id":"apply-9","type":"applies"}}}},"included":[{"id":"plan-9","type":"plans","attributes":{"status":"finished","log-read-url":"\(signedURL)"}},{"id":"apply-9","type":"applies","attributes":{"status":"finished"}}]}
            """.utf8),
            "/v1/object/signed": Data("password = \"secret-value\"\nAuthorization: Bearer secret-token\n".utf8)
        ]
        let workspace = HCPWorkspace(id: "ws-1", name: "production", terraformVersion: "1.10.0", executionMode: "remote", locked: false,
                                     htmlURL: URL(string: "https://app.terraform.io/app/pthrasher_v2/workspaces/production"))
        let page = try await makeClient().runs(hostname: "app.terraform.io", organization: "pthrasher_v2", workspace: workspace,
                                               token: "api-secret-token", page: 1)
        let remoteRun = try XCTUnwrap(page.items.first)
        XCTAssertEqual(remoteRun.id, "run-remote-92")
        XCTAssertEqual(remoteRun.workspaceID, "ws-1")
        XCTAssertEqual(remoteRun.workspaceName, "production")
        XCTAssertTrue(remoteRun.isActive == false)
        let details = try await makeClient().runDetails(hostname: "app.terraform.io", organization: "pthrasher_v2",
                                                        run: remoteRun, token: "api-secret-token")
        XCTAssertEqual(details.planStatus, "finished")
        XCTAssertEqual(details.applyStatus, "finished")
        XCTAssertTrue(details.planLogs?.contains("[redacted]") == true)
        XCTAssertFalse(details.planLogs?.contains("secret-value") == true)
        XCTAssertFalse(details.planLogs?.contains("secret-token") == true)
        XCTAssertFalse(String(describing: details).contains("do-not-store-this-url"))
        let artifactRequest = try XCTUnwrap(HCPURLProtocolStub.requests.first(where: { $0.url?.host == "archivist.terraform.io" }))
        XCTAssertNil(artifactRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(remoteRun.htmlURL?.absoluteString, "https://app.terraform.io/app/pthrasher_v2/workspaces/production/runs/run-remote-92")
    }

    func testRememberedRunOutsideLoadedPageRetainsItsHCPLink() async throws {
        HCPURLProtocolStub.responses = [
            "/api/v2/runs/run-remembered": Data(#"{"data":{"id":"run-remembered","type":"runs","attributes":{"status":"applied"},"relationships":{}},"included":[]}"#.utf8)
        ]
        let remembered = HCPRun(id: "run-remembered", workspaceID: "ws-1", workspaceName: "example",
            status: "loading", message: nil, operation: nil, createdAt: nil, hasChanges: nil,
            isDestroy: false, planID: nil, applyID: nil, htmlURL: nil)
        let result = try await makeClient().runDetails(hostname: "app.terraform.io", organization: "pthrasher_v2", run: remembered, token: "test-token")
        XCTAssertTrue(result.runURL?.absoluteString.contains("run-remembered") == true)
    }

    func testHostnameValidationRejectsPathsAndCredentials() {
        XCTAssertEqual(HCPAPIClient.normalizedHostname("https://app.terraform.io/"), "app.terraform.io")
        XCTAssertNil(HCPAPIClient.normalizedHostname("app.terraform.io/path"))
        XCTAssertNil(HCPAPIClient.normalizedHostname("user@app.terraform.io"))
        XCTAssertNil(HCPAPIClient.normalizedHostname("app.terraform.io:443"))
    }

    func testLogRedactionMasksSensitiveStructuredValuesAndNamedCredentials() {
        let logs = #"{"sensitive":true,"value":"state-secret"}"# + "\npassword = \"plan-secret\""
        let redacted = try! XCTUnwrap(HCPAPIClient.redactLogs(logs))
        XCTAssertFalse(redacted.contains("state-secret"))
        XCTAssertFalse(redacted.contains("plan-secret"))
        XCTAssertTrue(redacted.contains("[redacted]"))
    }

    func testCredentialedRedirectPolicyRejectsCrossOriginAndKeepsSameOrigin() throws {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        var apiRequest = URLRequest(url: URL(string: "https://app.terraform.io/api/v2/organizations")!)
        apiRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: apiRequest)
        let response = HTTPURLResponse(url: try XCTUnwrap(apiRequest.url), statusCode: 302, httpVersion: nil, headerFields: nil)!

        var crossOriginRedirect: URLRequest?
        HCPRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                       newRequest: URLRequest(url: URL(string: "https://other.example/api/v2/organizations")!)) {
            crossOriginRedirect = $0
        }
        XCTAssertNil(crossOriginRedirect)

        var sameOriginRedirect: URLRequest?
        HCPRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                       newRequest: URLRequest(url: URL(string: "https://app.terraform.io/api/v2/next")!)) {
            sameOriginRedirect = $0
        }
        XCTAssertEqual(sameOriginRedirect?.url?.path, "/api/v2/next")
    }

    func testOversizedAPIResponseIsRejectedFromHeadersBeforeBodyRead() async throws {
        HCPURLProtocolStub.contentLengths = ["/api/v2/organizations": 9 * 1024 * 1024]
        HCPURLProtocolStub.responses = ["/api/v2/organizations": Data("{}".utf8)]
        do {
            _ = try await makeClient().organizations(hostname: "app.terraform.io", token: "test-token", page: 1)
            XCTFail("Oversized response must be rejected.")
        } catch let error as HCPViewerError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    @MainActor
    func testConnectNormalizesHostBeforeGenerationAndRestoresSavedWorkspaceFromNextPage() async throws {
        let workspacesPath = "/api/v2/organizations/pthrasher_v2/workspaces"
        HCPURLProtocolStub.responses[workspacesPath + "#page=1"] = try workspacePage(
            (1...50).map { workspaceRecord(id: "ws-\($0)", name: "workspace-\($0)") }, hasNext: true)
        HCPURLProtocolStub.responses[workspacesPath + "#page=2"] = try workspacePage(
            [workspaceRecord(id: "ws-saved", name: "saved-workspace")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-saved/runs"] = emptyRunPage()
        let selection = HCPMemorySelectionStore(selection: HCPStoredSelection(
            identity: HCPConnectionIdentity(hostname: "https://app.terraform.io/", organization: "pthrasher_v2", workspaceID: "ws-saved", runID: nil),
            selectedWorkspaceID: "ws-saved", selectedRunID: nil))
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: selection, client: makeClient())

        await model.connect()

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.hostname, "app.terraform.io")
        XCTAssertEqual(model.selectedWorkspaceID, "ws-saved")
        XCTAssertEqual(model.selectedWorkspace?.name, "saved-workspace")
        XCTAssertEqual(model.workspacePage, 2)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(HCPURLProtocolStub.requests.contains {
            guard let url = $0.url, url.path == workspacesPath else { return false }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page[number]" })?.value == "2"
        })
    }

    @MainActor
    func testWorkspaceSwitchResetsRunCooldownAndStopsActiveRunPolling() async throws {
        let workspacesPath = "/api/v2/organizations/pthrasher_v2/workspaces"
        HCPURLProtocolStub.responses[workspacesPath] = try workspacePage([
            workspaceRecord(id: "ws-1", name: "first"), workspaceRecord(id: "ws-2", name: "second")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = activeRunPage()
        HCPURLProtocolStub.responses["/api/v2/runs/run-active"] = activeRunDetails()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/runs"] = emptyRunPage()
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())

        await model.connect()
        XCTAssertTrue(model.isPolling)
        model.setVisible(false)
        XCTAssertFalse(model.isPolling)
        model.setVisible(true)
        XCTAssertTrue(model.isPolling)
        model.selectedWorkspaceID = "ws-2"
        XCTAssertFalse(model.isPolling)
        XCTAssertFalse(model.isLoading)
        await model.refreshRuns()

        XCTAssertTrue(HCPURLProtocolStub.requests.contains { $0.url?.path == "/api/v2/workspaces/ws-2/runs" })
        XCTAssertTrue(model.isConnected)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isPolling)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testDisconnectAndRunSelectionInvalidationClearLoadingState() async throws {
        let workspacesPath = "/api/v2/organizations/pthrasher_v2/workspaces"
        HCPURLProtocolStub.responses[workspacesPath] = try workspacePage([
            workspaceRecord(id: "ws-1", name: "first"), workspaceRecord(id: "ws-2", name: "second")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/runs"] = emptyRunPage()
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()

        model.selectedWorkspaceID = "ws-2"
        HCPURLProtocolStub.delays["/api/v2/workspaces/ws-2/runs"] = 0.25
        let disconnecting = Task { await model.refreshRuns(force: true) }
        try await waitForLoading(model)
        XCTAssertTrue(model.isLoading)
        model.disconnect()
        XCTAssertFalse(model.isLoading)
        await disconnecting.value

        HCPURLProtocolStub.delays.removeValue(forKey: "/api/v2/workspaces/ws-2/runs")
        await model.connect()
        model.selectedWorkspaceID = "ws-1"
        HCPURLProtocolStub.delays["/api/v2/workspaces/ws-1/runs"] = 0.25
        let selecting = Task { await model.refreshRuns(force: true) }
        try await waitForLoading(model)
        model.selectedRunID = "run-new-selection"
        XCTAssertFalse(model.isLoading)
        await selecting.value
        XCTAssertTrue(model.runs.isEmpty)
    }

    @MainActor
    private func waitForLoading(_ model: HCPWorkspaceViewerModel) async throws {
        for _ in 0..<100 where !model.isLoading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(model.isLoading)
    }

    private func workspaceRecord(id: String, name: String) -> [String: Any] {
        ["id": id, "type": "workspaces", "attributes": ["name": name, "terraform-version": "1.10.0", "execution-mode": "remote", "locked": false]]
    }

    private func workspacePage(_ records: [[String: Any]], hasNext: Bool) throws -> Data {
        var object: [String: Any] = ["data": records, "links": [:] as [String: Any], "meta": ["pagination": ["total-count": records.count]]]
        if hasNext { object["links"] = ["next": "https://app.terraform.io/api/v2/organizations/pthrasher_v2/workspaces?page[number]=2"] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func organizationPage() -> Data {
        Data(#"{"data":[{"id":"org-pthrasher-v2","type":"organizations","attributes":{"name":"pthrasher_v2"}}],"links":{}}"#.utf8)
    }

    private func emptyRunPage() -> Data { Data(#"{"data":[],"links":{},"meta":{"pagination":{"total-count":0}}}"#.utf8) }

    private func activeRunPage() -> Data {
        Data(#"{"data":[{"id":"run-active","type":"runs","attributes":{"status":"planning","message":"active","operation":"plan_and_apply","created-at":"2026-10-03T12:00:00.000Z","is-destroy":false},"relationships":{}}],"links":{},"meta":{"pagination":{"total-count":1}}}"#.utf8)
    }

    private func activeRunDetails() -> Data {
        Data(#"{"data":{"id":"run-active","type":"runs","attributes":{"status":"planning","message":"active","operation":"plan_and_apply","created-at":"2026-10-03T12:00:00.000Z","is-destroy":false},"relationships":{}}}"#.utf8)
    }

    private func makeClient() -> HCPAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HCPURLProtocolStub.self]
        return HCPAPIClient(configuration: configuration)
    }
}

private final class HCPURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var redirects: [String: URL] = [:]
    nonisolated(unsafe) static var contentLengths: [String: Int] = [:]
    nonisolated(unsafe) static var delays: [String: TimeInterval] = [:]
    nonisolated(unsafe) static var statusCode = 200

    static func reset() { responses = [:]; requests = []; redirects = [:]; contentLengths = [:]; delays = [:]; statusCode = 200 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        Self.requests.append(request)
        if let destination = Self.redirects[url.path] {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page[number]" })?.value
        let key = page.map { url.path + "#page=" + $0 } ?? url.path
        guard let data = Self.responses[key] ?? Self.responses[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        if let delay = Self.delays[url.path], delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.reply(data, url: url) }
            return
        }
        reply(data, url: url)
    }
    private func reply(_ data: Data, url: URL) {
        var headers = ["Content-Type": "application/vnd.api+json"]
        if let size = Self.contentLengths[url.path] { headers["Content-Length"] = String(size) }
        let response = HTTPURLResponse(url: url, statusCode: Self.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct HCPMemoryTokenStore: HCPTokenStore {
    func read(hostname: String) throws -> String? { hostname == "app.terraform.io" ? "fake-hcp-token" : nil }
    func write(_ token: String, hostname: String) throws {}
    func delete(hostname: String) throws {}
}

private final class HCPMemorySelectionStore: HCPSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSelection: HCPStoredSelection?
    init(selection: HCPStoredSelection? = nil) { storedSelection = selection }
    func load() -> HCPStoredSelection? {
        lock.lock(); defer { lock.unlock() }
        return storedSelection
    }
    func save(_ selection: HCPStoredSelection) {
        lock.lock(); defer { lock.unlock() }
        storedSelection = selection
    }
}
