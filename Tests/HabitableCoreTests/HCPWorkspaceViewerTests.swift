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

    func testWorkspaceVariableDisplayMaskUsesSensitivityAndConservativeCredentialKeyNames() {
        func variable(_ key: String, sensitive: Bool = false) -> HCPWorkspaceVariable {
            HCPWorkspaceVariable(id: key, key: key, value: "sample", category: "env", description: "test",
                                 isSensitive: sensitive, isHCL: false)
        }

        for key in ["API_KEY", "CLIENT_SECRET", "AUTH_SECRET_KEY", "database_password", "refresh_token", "ssh_private_key"] {
            let candidate = variable(key)
            XCTAssertFalse(candidate.isSensitive, "API sensitivity remains unchanged for \(key)")
            XCTAssertTrue(candidate.isMaskedForDisplay, "Expected display masking for \(key)")
        }
        for key in ["github_owner", "admin_ips", "ssh_public_key", "GITHUB_OAUTH_CLIENT_ID"] {
            XCTAssertFalse(variable(key).isMaskedForDisplay, "Expected value to remain visible for \(key)")
        }
        XCTAssertTrue(variable("ORDINARY_NAME", sensitive: true).isMaskedForDisplay)
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

    func testStateArtifactRedirectPolicyStripsCredentialsAcrossRedirectChain() throws {
        let session = URLSession(configuration: .ephemeral)
        let sourceURL = URL(string: "https://app.terraform.io/api/state-versions/sv-1/hosted_state")!
        var source = URLRequest(url: sourceURL)
        source.setValue("Bearer state-token", forHTTPHeaderField: "Authorization")
        source.setValue("session-cookie=private", forHTTPHeaderField: "Cookie")
        source.setValue("Proxy private", forHTTPHeaderField: "Proxy-Authorization")
        let task = session.dataTask(with: source)
        let policy = HCPStateArtifactRedirectPolicy()

        func redirected(_ responseURL: URL, to target: URL, carrying credentials: Bool) throws -> URLRequest? {
            var request = URLRequest(url: target)
            if credentials {
                request.setValue("Bearer state-token", forHTTPHeaderField: "Authorization")
                request.setValue("session-cookie=private", forHTTPHeaderField: "Cookie")
                request.setValue("Proxy private", forHTTPHeaderField: "Proxy-Authorization")
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 302,
                                                         httpVersion: "HTTP/1.1", headerFields: nil))
            var result: URLRequest?
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                result = $0
            }
            return result
        }

        let signedStorageURL = URL(string: "https://archivist.terraform.io/v1/object/state?signature=keep-this")!
        let firstHop = try XCTUnwrap(redirected(sourceURL, to: signedStorageURL, carrying: true))
        XCTAssertEqual(firstHop.url?.query, "signature=keep-this")
        XCTAssertNil(firstHop.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(firstHop.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(firstHop.value(forHTTPHeaderField: "Proxy-Authorization"))

        let secondArchivistURL = URL(string: "https://archivist.terraform.io/v1/object/final?signature=keep-this")!
        let secondHop = try XCTUnwrap(redirected(try XCTUnwrap(firstHop.url), to: secondArchivistURL, carrying: false))
        XCTAssertEqual(secondHop.url?.query, "signature=keep-this")
        XCTAssertNil(secondHop.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(secondHop.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(secondHop.value(forHTTPHeaderField: "Proxy-Authorization"))

        let otherHost = URL(string: "https://storage.example.net/object/state?signature=keep-this")!
        XCTAssertNil(try redirected(try XCTUnwrap(secondHop.url), to: otherHost, carrying: false))
    }

    func testStateArtifactRedirectPolicyRejectsHTTPAndUserInfoTargets() throws {
        let session = URLSession(configuration: .ephemeral)
        let sourceURL = URL(string: "https://app.terraform.io/api/state-versions/sv-1/hosted_state")!
        let task = session.dataTask(with: URLRequest(url: sourceURL))
        let response = try XCTUnwrap(HTTPURLResponse(url: sourceURL, statusCode: 302,
                                                    httpVersion: "HTTP/1.1", headerFields: nil))
        let policy = HCPStateArtifactRedirectPolicy()

        for target in [URL(string: "http://archivist.terraform.io/object/state?signature=keep")!,
                       URL(string: "https://user:password@archivist.terraform.io/object/state?signature=keep")!,
                       URL(string: "https://archivist.terraform.io.example.net/object/state?signature=keep")!,
                       URL(string: "https://archivist.terraform.io:444/object/state?signature=keep")!] {
            var result: URLRequest?
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: target)) { result = $0 }
            XCTAssertNil(result, "Unsafe artifact redirect should be rejected: \(target.host ?? "unknown")")
        }
    }

    func testStateArtifactRedirectPolicyRejectsUnexpectedOriginalRequest() throws {
        let session = URLSession(configuration: .ephemeral)
        let target = URL(string: "https://archivist.terraform.io/v1/object/state?signature=keep")!
        let policy = HCPStateArtifactRedirectPolicy()
        let unexpectedSources: [(String, String)] = [
            ("https://enterprise.example.test/api/state-versions/sv-1/hosted_state", "GET"),
            ("https://app.terraform.io/api/v2/state-versions/sv-1/hosted_state", "GET"),
            ("https://app.terraform.io/api/state-versions/sv-1/hosted_state", "POST")
        ]

        for (sourceString, method) in unexpectedSources {
            var sourceRequest = URLRequest(url: try XCTUnwrap(URL(string: sourceString)))
            sourceRequest.httpMethod = method
            sourceRequest.setValue("Bearer state-token", forHTTPHeaderField: "Authorization")
            let task = session.dataTask(with: sourceRequest)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(sourceRequest.url), statusCode: 302,
                                                         httpVersion: "HTTP/1.1", headerFields: nil))
            var result: URLRequest?
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: target)) { result = $0 }
            XCTAssertNil(result, "Unexpected source should not receive the state artifact redirect exception")
        }
    }

    func testStateArtifactRedirectPolicyDoesNotForwardBodyOrCustomHeaders() throws {
        let session = URLSession(configuration: .ephemeral)
        let sourceURL = URL(string: "https://app.terraform.io/api/state-versions/sv-1/hosted_state")!
        let targetURL = URL(string: "https://archivist.terraform.io/v1/object/state?signature=keep")!
        let task = session.dataTask(with: URLRequest(url: sourceURL))
        let response = try XCTUnwrap(HTTPURLResponse(url: sourceURL, statusCode: 302,
                                                    httpVersion: "HTTP/1.1", headerFields: nil))
        var redirectedRequest = URLRequest(url: targetURL)
        redirectedRequest.httpMethod = "POST"
        redirectedRequest.httpBody = Data("private request body".utf8)
        redirectedRequest.setValue("private custom value", forHTTPHeaderField: "X-Custom-Secret")

        var result: URLRequest?
        HCPStateArtifactRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                    newRequest: redirectedRequest) { result = $0 }
        let sanitized = try XCTUnwrap(result)
        XCTAssertEqual(sanitized.httpMethod, "GET")
        XCTAssertNil(sanitized.httpBody)
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "X-Custom-Secret"))
        XCTAssertEqual(sanitized.url?.query, "signature=keep")
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

    func testWorkspaceVariablesPaginateAndNeverExposeSensitiveValues() async throws {
        let path = "/api/v2/workspaces/ws-1/vars"
        HCPURLProtocolStub.responses[path + "#page=1"] = Data(#"{"data":[{"id":"var-1","type":"vars","attributes":{"key":"REGION","value":"us-west-2","category":"env","description":"region","sensitive":false,"hcl":false}},{"id":"var-secret","type":"vars","attributes":{"key":"TOKEN","value":"backend-secret","category":"env","sensitive":true,"hcl":false}}],"links":{"next":"https://app.terraform.io/api/v2/workspaces/ws-1/vars?page[number]=2"}}"#.utf8)
        HCPURLProtocolStub.responses[path + "#page=2"] = Data(#"{"data":[{"id":"var-3","type":"vars","attributes":{"key":"POLICY","value":"{enabled=true}","category":"terraform","sensitive":false,"hcl":true}}],"links":{}}"#.utf8)

        let first = try await makeClient().workspaceVariables(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test-token", page: 1)
        let second = try await makeClient().workspaceVariables(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test-token", page: 2)
        XCTAssertTrue(first.hasNextPage)
        XCTAssertEqual(first.items.map(\.id), ["var-1", "var-secret"])
        XCTAssertEqual(first.items[0].value, "us-west-2")
        XCTAssertNil(first.items[1].value)
        XCTAssertTrue(first.items[1].isSensitive)
        XCTAssertEqual(second.items.first?.value, "{enabled=true}")
        XCTAssertTrue(second.items.first?.isHCL == true)
    }

    func testWorkspaceVariablePatchOnlySendsValue() async throws {
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars/var-1"] = Data(#"{"data":{"id":"var-1","type":"vars","attributes":{"value":"new-value"}}}"#.utf8)
        try await makeClient().updateWorkspaceVariable(hostname: "app.terraform.io", workspaceID: "ws-1", variableID: "var-1", value: "new-value", token: "test-token")
        let request = try XCTUnwrap(HCPURLProtocolStub.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(request.httpBody ?? readBody(request.httpBodyStream))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "vars")
        XCTAssertEqual(data["id"] as? String, "var-1")
        XCTAssertEqual(data["attributes"] as? [String: String], ["value": "new-value"])
    }

    func testWorkspaceVariableHTTPErrorOmitsBackendBody() async throws {
        HCPURLProtocolStub.statusCode = 403
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars"] = Data(#"{"errors":[{"detail":"echoed-private-variable"}]}"#.utf8)
        do {
            _ = try await makeClient().workspaceVariables(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test-token", page: 1)
            XCTFail("Expected sanitized API error")
        } catch let error as HCPViewerError {
            XCTAssertEqual(error, .response(status: 403, message: "This account cannot view that organization, workspace, or run. Check its permissions and entitlements."))
            XCTAssertFalse(error.localizedDescription.contains("echoed-private-variable"))
        }
    }

    func testWorkspaceVariablePatchRejectsMalformedSuccessResponse() async throws {
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars/var-1"] = Data("{}".utf8)
        do {
            try await makeClient().updateWorkspaceVariable(hostname: "app.terraform.io", workspaceID: "ws-1", variableID: "var-1", value: "new-value", token: "test-token")
            XCTFail("Malformed success must not be confirmed")
        } catch let error as HCPViewerError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    @MainActor
    func testStaleVariableResponseCannotReplaceNewWorkspaceVariables() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage([
            workspaceRecord(id: "ws-1", name: "first"), workspaceRecord(id: "ws-2", name: "second")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars"] = Data(#"{"data":[{"id":"old","type":"vars","attributes":{"key":"OLD","sensitive":false}}],"links":{}}"#.utf8)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/vars"] = Data(#"{"data":[{"id":"new","type":"vars","attributes":{"key":"NEW","sensitive":false}}],"links":{}}"#.utf8)
        HCPURLProtocolStub.delays["/api/v2/workspaces/ws-1/vars"] = 0.15
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        let loading = Task { await model.refreshVariables() }
        for _ in 0..<100 where !model.isLoadingVariables { try await Task.sleep(nanoseconds: 1_000_000) }
        model.selectedWorkspaceID = "ws-2"
        await model.refreshVariables()
        await loading.value
        XCTAssertEqual(model.workspaceVariables.map(\.id), ["new"])
    }

    @MainActor
    func testFailedVariableSaveKeepsLoadedValueAndSanitizesError() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage(
            [workspaceRecord(id: "ws-1", name: "first")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars"] = Data(#"{"data":[{"id":"var-1","type":"vars","attributes":{"key":"REGION","value":"us-west-2","description":"region","sensitive":false}}],"links":{}}"#.utf8)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars/var-1"] = Data(#"{"errors":[{"detail":"echoed-secret-value"}]}"#.utf8)
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        await model.refreshVariables()
        HCPURLProtocolStub.statusCode = 403

        let saved = await model.updateVariable(variableID: "var-1", value: "new-value")

        XCTAssertFalse(saved)
        XCTAssertEqual(model.workspaceVariables.first?.value, "us-west-2")
        XCTAssertEqual(model.workspaceVariables.first?.description, "region")
        XCTAssertTrue(model.variablesError?.contains("Couldn’t save") == true)
        XCTAssertFalse(model.variablesError?.contains("echoed-secret-value") == true)
    }

    @MainActor
    func testSuccessfulSaveUpdatesNonsensitiveValueAndPreservesMetadataAndSensitiveMask() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage(
            [workspaceRecord(id: "ws-1", name: "first")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars"] = Data(#"{"data":[{"id":"plain","type":"vars","attributes":{"key":"REGION","value":"us-east-1","category":"env","description":"deployment region","sensitive":false,"hcl":false}},{"id":"secret","type":"vars","attributes":{"key":"TOKEN","value":"backend-secret","category":"env","description":"private credential","sensitive":true,"hcl":false}}],"links":{}}"#.utf8)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars/plain"] = Data(#"{"data":{"id":"plain","type":"vars","attributes":{"value":"us-west-2"}}}"#.utf8)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars/secret"] = Data(#"{"data":{"id":"secret","type":"vars","attributes":{"value":"new-secret"}}}"#.utf8)
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        await model.refreshVariables()

        let plainSaved = await model.updateVariable(variableID: "plain", value: "us-west-2")
        let secretSaved = await model.updateVariable(variableID: "secret", value: "new-secret")
        XCTAssertTrue(plainSaved)
        XCTAssertTrue(secretSaved)

        let plain = try XCTUnwrap(model.workspaceVariables.first { $0.id == "plain" })
        XCTAssertEqual(plain.value, "us-west-2")
        XCTAssertEqual(plain.key, "REGION")
        XCTAssertEqual(plain.category, "env")
        XCTAssertEqual(plain.description, "deployment region")
        XCTAssertFalse(plain.isSensitive)
        XCTAssertFalse(plain.isHCL)
        let secret = try XCTUnwrap(model.workspaceVariables.first { $0.id == "secret" })
        XCTAssertNil(secret.value)
        XCTAssertEqual(secret.key, "TOKEN")
        XCTAssertEqual(secret.description, "private credential")
        XCTAssertTrue(secret.isSensitive)
        XCTAssertFalse(String(describing: model.workspaceVariables).contains("backend-secret"))
        XCTAssertFalse(String(describing: model.workspaceVariables).contains("new-secret"))
    }

    @MainActor
    func testUnknownVariableIDDoesNotSendPatch() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage(
            [workspaceRecord(id: "ws-1", name: "first")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars"] = Data(#"{"data":[{"id":"known","type":"vars","attributes":{"key":"KNOWN","value":"current","sensitive":false}}],"links":{}}"#.utf8)
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        await model.refreshVariables()

        let saved = await model.updateVariable(variableID: "not-loaded", value: "forbidden")
        XCTAssertFalse(saved)
        XCTAssertFalse(HCPURLProtocolStub.requests.contains { $0.httpMethod == "PATCH" })
        XCTAssertEqual(model.workspaceVariables.first?.value, "current")
    }

    @MainActor
    func testStaleSuccessfulSaveDoesNotAffectNewWorkspace() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage([
            workspaceRecord(id: "ws-1", name: "first"), workspaceRecord(id: "ws-2", name: "second")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars"] = Data(#"{"data":[{"id":"var-1","type":"vars","attributes":{"key":"OLD","value":"before","sensitive":false}}],"links":{}}"#.utf8)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/vars"] = Data(#"{"data":[{"id":"var-2","type":"vars","attributes":{"key":"NEW","value":"current","sensitive":false}}],"links":{}}"#.utf8)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/vars/var-1"] = Data(#"{"data":{"id":"var-1","type":"vars","attributes":{"value":"late-write"}}}"#.utf8)
        HCPURLProtocolStub.delays["/api/v2/workspaces/ws-1/vars/var-1"] = 0.15
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        await model.refreshVariables()

        let save = Task { await model.updateVariable(variableID: "var-1", value: "late-write") }
        for _ in 0..<100 where model.savingVariableID == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        model.selectedWorkspaceID = "ws-2"
        await model.refreshVariables()
        let didSave = await save.value
        XCTAssertFalse(didSave)

        XCTAssertEqual(model.selectedWorkspaceID, "ws-2")
        XCTAssertEqual(model.workspaceVariables.map(\.id), ["var-2"])
        XCTAssertEqual(model.workspaceVariables.first?.value, "current")
    }

    private func readBody(_ stream: InputStream?) throws -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? HCPViewerError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
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

    @MainActor
    func testOfflineMapSampleNeverRequestsOrPersistsAccountData() async throws {
        let store = HCPMemorySelectionStore()
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: store,
                                           client: makeClient(), isSample: true)
        await model.refreshMap()
        XCTAssertEqual(model.mapSnapshot?.resources.count, 10)
        XCTAssertTrue(model.workspaces.contains { $0.id == "sample-reference" && $0.name == "Map reference · sample" })
        model.selectedWorkspaceID = "sample-reference"
        await model.refreshMap()
        let reference = try XCTUnwrap(model.mapSnapshot)
        XCTAssertEqual(reference.versionID, "sample-reference")
        XCTAssertEqual(reference.resources.count, 17)
        XCTAssertEqual(reference.map.dataSources.count, 3)
        XCTAssertEqual(reference.resources.filter { $0.type == "aws_bedrock_model_invocation_logging_configuration" }.count, 2)
        XCTAssertEqual(reference.resources.filter { $0.type == "aws_cloudwatch_event_rule" }.count, 2)
        XCTAssertEqual(reference.resources.filter { $0.type == "aws_sns_topic" }.count, 2)
        XCTAssertTrue(reference.resources.contains { $0.address == "aws_bedrock_model_invocation_logging_configuration.bedrock_logging[0]" })
        XCTAssertTrue(reference.resources.contains { $0.address == "aws_bedrock_model_invocation_logging_configuration.bedrock_logging[1]" })
        XCTAssertEqual(reference.map.workspaceReferences.map(\.address), [
            "data.terraform_remote_state.cluster", "data.terraform_remote_state.root_dns",
            "data.terraform_remote_state.vpc"
        ])
        let tileIDs = Set(reference.map.tiles.map(\.id))
        XCTAssertTrue(reference.map.workspaceReferences.allSatisfy {
            !$0.consumers.isEmpty && Set($0.consumers).isSubset(of: tileIDs)
        })
        XCTAssertEqual(reference.map.tiles.filter { $0.kind == .messaging }.count, 3)
        for type in ["aws_cloudwatch_event_rule", "aws_sns_topic", "aws_chatbot_slack_channel_configuration"] {
            let addresses = Set(reference.resources.filter { $0.type == type }.map(\.address))
            XCTAssertTrue(reference.map.tiles.contains { $0.kind == .messaging && !addresses.isDisjoint(with: $0.resources) })
        }
        XCTAssertFalse(reference.map.tiles.contains { $0.kind == .frontDoor || $0.kind == .network })
        model.selectedWorkspaceID = "sample-empty"
        await model.refreshMap()
        XCTAssertEqual(model.mapSnapshot?.resources.count, 0)
        model.selectedWorkspaceID = "sample-unavailable"
        await model.refreshMap()
        XCTAssertNil(model.mapSnapshot)
        XCTAssertNotNil(model.mapError)
        await model.connect()
        await model.refreshRuns()
        XCTAssertTrue(HCPURLProtocolStub.requests.isEmpty)
        XCTAssertNil(store.load())
    }

    func testEmptyCloudStateAcceptsMetadataOnlyJSON() throws {
        let snapshot = try HCPMapSnapshot.decode(versionID: "sv-empty",
            raw: Data(#"{"version":4,"resources":[]}"#.utf8),
            shown: Data(#"{"format_version":"1.0"}"#.utf8))
        XCTAssertTrue(snapshot.map.tiles.isEmpty)
        XCTAssertTrue(snapshot.resources.isEmpty)
    }

    private var mapRaw: Data {
        Data(#"{"version":4,"resources":[{"mode":"managed","type":"aws_db_instance","name":"orders","instances":[{"attributes":{"password":"NEVER_DISPLAY_THIS"}}]}]}"#.utf8)
    }

    private var mapShown: Data {
        Data(#"{"format_version":"1.0","values":{"root_module":{"resources":[{"address":"aws_db_instance.orders","mode":"managed","type":"aws_db_instance","name":"orders","values":{"engine":"postgres","nested":{"password":"NEVER_DISPLAY_THIS"},"url":"db://NEVER_DISPLAY_THIS@host"},"sensitive_values":{"nested":{"password":true}}}]}}}"#.utf8)
    }

    private func installMapResponses(workspaceID: String = "ws-1", json: Bool = true,
                                    stateCreatedAt: String? = nil, stateSerial: Int? = nil) throws {
        var attrs: [String: Any] = ["hosted-state-download-url": "https://archivist.terraform.io/map/raw?signature=private"]
        if json { attrs["hosted-json-state-download-url"] = "https://archivist.terraform.io/map/show?signature=private" }
        if let stateCreatedAt { attrs["created-at"] = stateCreatedAt }
        if let stateSerial { attrs["serial"] = stateSerial }
        HCPURLProtocolStub.responses["/api/v2/workspaces/\(workspaceID)/current-state-version"] = try JSONSerialization.data(withJSONObject:
            ["data": ["id": "sv-\(workspaceID)", "type": "state-versions", "attributes": attrs,
                      "relationships": ["workspace": ["data": ["id": workspaceID]]]]])
        HCPURLProtocolStub.responses["/map/raw"] = mapRaw
        HCPURLProtocolStub.responses["/map/show"] = mapShown
    }

    func testCurrentMapUsesOneVersionAndRedactsNestedAndRepeatedSecrets() async throws {
        try installMapResponses(stateCreatedAt: "2026-10-03T12:00:00.000Z", stateSerial: 42)
        let result = try await makeClient().currentMap(hostname: "app.terraform.io", workspaceID: "ws-1", token: "api-secret")
        XCTAssertEqual(result.versionID, "sv-ws-1")
        XCTAssertEqual(result.stateCreatedAt, ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))
        XCTAssertEqual(result.stateSerial, 42)
        XCTAssertEqual(result.map.tiles.count, 1)
        XCTAssertNil(result.notice)
        XCTAssertFalse(String(describing: result).contains("NEVER_DISPLAY_THIS"))
        XCTAssertFalse(String(describing: result).contains("signature="))
        XCTAssertTrue(result.resources[0].displayAttributes.contains { $0.value == "postgres" })
        XCTAssertTrue(result.resources[0].displayAttributes.contains { $0.value == "(sensitive value)" })
        for request in HCPURLProtocolStub.requests where request.url?.host == "archivist.terraform.io" {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "GET")
        }
        XCTAssertEqual(HCPURLProtocolStub.requests.count, 3)
    }

    func testCurrentMapToleratesMalformedOptionalStateDateAndSerial() async throws {
        try installMapResponses(stateCreatedAt: "not-a-date", stateSerial: nil)
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/current-state-version"] = Data(#"{"data":{"id":"sv-ws-1","type":"state-versions","attributes":{"hosted-state-download-url":"https://archivist.terraform.io/map/raw?signature=private","hosted-json-state-download-url":"https://archivist.terraform.io/map/show?signature=private","created-at":"not-a-date","serial":"not-a-number"}}}"#.utf8)
        let result = try await makeClient().currentMap(hostname: "app.terraform.io", workspaceID: "ws-1", token: "api-secret")
        XCTAssertEqual(result.versionID, "sv-ws-1")
        XCTAssertNil(result.stateCreatedAt)
        XCTAssertNil(result.stateSerial)
        XCTAssertEqual(result.map.tiles.count, 1)
    }

    func testOlderStateWithoutJSONKeepsMapButNeverExposesRawAttributes() async throws {
        try installMapResponses(json: false)
        let result = try await makeClient().currentMap(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test")
        XCTAssertEqual(result.resources.count, 1)
        XCTAssertTrue(result.resources[0].displayAttributes.isEmpty)
        XCTAssertNotNil(result.notice)
        XCTAssertFalse(String(describing: result).contains("NEVER_DISPLAY_THIS"))
    }

    func testCurrentMapRejectsMismatchedOrMalformedArtifacts() async throws {
        try installMapResponses()
        for shown in [Data(#"{"format_version":"1.0","values":{"outputs":{}}}"#.utf8), Data("not json".utf8)] {
            HCPURLProtocolStub.responses["/map/show"] = shown
            do {
                _ = try await makeClient().currentMap(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test")
                XCTFail("Invalid artifacts must not become a map")
            } catch { XCTAssertEqual(error as? HCPViewerError, .invalidResponse) }
        }
    }

    func testCurrentMapRejectsOversizedStateAndInsecureURLs() async throws {
        try installMapResponses()
        HCPURLProtocolStub.contentLengths["/map/raw"] = 33 * 1024 * 1024
        do {
            _ = try await makeClient().currentMap(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test")
            XCTFail("Oversized state must fail")
        } catch { XCTAssertEqual(error as? HCPViewerError, .responseTooLarge) }
        HCPURLProtocolStub.contentLengths = [:]
        HCPURLProtocolStub.requests = []
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/current-state-version"] = Data(#"{"data":{"id":"sv-1","type":"state-versions","attributes":{"hosted-state-download-url":"http://example.test/raw"}}}"#.utf8)
        do {
            _ = try await makeClient().currentMap(hostname: "app.terraform.io", workspaceID: "ws-1", token: "test")
            XCTFail("Insecure URL must fail")
        } catch { XCTAssertEqual(error as? HCPViewerError, .invalidResponse) }
        XCTAssertEqual(HCPURLProtocolStub.requests.count, 1)
    }

    func testEnterpriseStateAuthenticationStaysOnExactAPIOrigin() async throws {
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/current-state-version"] = Data(#"{"data":{"id":"sv-1","type":"state-versions","attributes":{"hosted-state-download-url":"https://enterprise.example.test/api/state-versions/sv-1/hosted_state"}}}"#.utf8)
        HCPURLProtocolStub.responses["/api/state-versions/sv-1/hosted_state"] = mapRaw
        _ = try await makeClient().currentMap(hostname: "enterprise.example.test", workspaceID: "ws-1", token: "test-token")
        XCTAssertEqual(HCPURLProtocolStub.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    @MainActor
    func testMapWorkspaceSwitchAndDisconnectRejectLateResponses() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage([
            workspaceRecord(id: "ws-1", name: "first"), workspaceRecord(id: "ws-2", name: "second")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-2/runs"] = emptyRunPage()
        try installMapResponses()
        try installMapResponses(workspaceID: "ws-2")
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        await model.refreshMap()
        XCTAssertEqual(model.mapSnapshot?.versionID, "sv-ws-1")
        HCPURLProtocolStub.delays["/api/v2/workspaces/ws-1/current-state-version"] = 0.15
        let oldRequest = Task { await model.refreshMap() }
        for _ in 0..<100 where !model.isLoadingMap { try await Task.sleep(for: .milliseconds(1)) }
        model.selectedWorkspaceID = "ws-2"
        XCTAssertNil(model.mapSnapshot)
        await model.refreshMap()
        await oldRequest.value
        XCTAssertEqual(model.mapSnapshot?.versionID, "sv-ws-2")
        HCPURLProtocolStub.delays["/api/v2/workspaces/ws-2/current-state-version"] = 0.15
        let disconnected = Task { await model.refreshMap() }
        for _ in 0..<100 where !model.isLoadingMap { try await Task.sleep(for: .milliseconds(1)) }
        model.disconnect()
        await disconnected.value
        XCTAssertNil(model.mapSnapshot)
        XCTAssertFalse(model.isLoadingMap)
        XCTAssertNil(model.mapError)
    }

    @MainActor
    func testMapMissingStateAndAccessFailuresAreNotReportedAsEmptyInfrastructure() async throws {
        HCPURLProtocolStub.responses["/api/v2/organizations/pthrasher_v2/workspaces"] = try workspacePage([workspaceRecord(id: "ws-1", name: "first")], hasNext: false)
        HCPURLProtocolStub.responses["/api/v2/organizations"] = organizationPage()
        HCPURLProtocolStub.responses["/api/v2/workspaces/ws-1/runs"] = emptyRunPage()
        try installMapResponses()
        let model = HCPWorkspaceViewerModel(tokenStore: HCPMemoryTokenStore(), selectionStore: HCPMemorySelectionStore(), client: makeClient())
        await model.connect()
        for status in [403, 404, 500] {
            HCPURLProtocolStub.statusCode = status
            await model.refreshMap()
            XCTAssertNil(model.mapSnapshot)
            XCTAssertNotNil(model.mapError)
            XCTAssertFalse(model.isLoadingMap)
            XCTAssertFalse(model.mapError?.contains("signature") == true)
        }
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
