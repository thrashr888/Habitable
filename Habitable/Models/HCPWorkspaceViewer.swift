import Foundation
import Combine
import Security

struct HCPConnectionIdentity: Codable, Equatable, Sendable {
    var hostname: String
    var organization: String
    var workspaceID: String?
    var runID: String?

    static let app = HCPConnectionIdentity(hostname: "app.terraform.io", organization: "pthrasher_v2")
}

struct HCPOrganization: Identifiable, Equatable, Sendable {
    let name: String
    let email: String?
    var id: String { name }
}

struct HCPWorkspace: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let terraformVersion: String?
    let executionMode: String?
    let locked: Bool
    let htmlURL: URL?
    let tagNames: [String]

    /// VCS connection when the workspace is repository-backed; lets the app check it out.
    let vcs: HCPVCSRepository?
    let projectID: String?
    let projectName: String?
    let currentRunStatus: String?
    let currentRunCreatedAt: Date?
    let updatedAt: Date?
    let resourceCount: Int?
    let description: String?
    /// Settings Habitable can change: apply without confirmation, and the
    /// subfolder Terraform runs in.
    let autoApply: Bool
    let workingDirectory: String?
    init(id: String, name: String, terraformVersion: String?, executionMode: String?,
         locked: Bool, htmlURL: URL?, tagNames: [String] = [], vcs: HCPVCSRepository? = nil,
         projectID: String? = nil, projectName: String? = nil, currentRunStatus: String? = nil,
         currentRunCreatedAt: Date? = nil, updatedAt: Date? = nil, resourceCount: Int? = nil,
         description: String? = nil, autoApply: Bool = false, workingDirectory: String? = nil) {
        self.description = description
        self.autoApply = autoApply; self.workingDirectory = workingDirectory
        self.id = id; self.name = name; self.terraformVersion = terraformVersion
        self.executionMode = executionMode; self.locked = locked; self.htmlURL = htmlURL
        self.tagNames = tagNames; self.vcs = vcs
        self.projectID = projectID; self.projectName = projectName
        self.currentRunStatus = currentRunStatus; self.currentRunCreatedAt = currentRunCreatedAt
        self.updatedAt = updatedAt; self.resourceCount = resourceCount
    }
}

/// The workspace settings a save may change; nil means "leave as is".
struct HCPWorkspaceSettingsChange: Equatable, Sendable {
    var terraformVersion: String?
    var autoApply: Bool?
    var executionMode: String?
    var workingDirectory: String?
    var description: String?

    var isEmpty: Bool { attributes.isEmpty }

    var attributes: [String: Any] {
        var attributes: [String: Any] = [:]
        if let terraformVersion { attributes["terraform-version"] = terraformVersion }
        if let autoApply { attributes["auto-apply"] = autoApply }
        if let executionMode { attributes["execution-mode"] = executionMode }
        if let workingDirectory { attributes["working-directory"] = workingDirectory }
        if let description { attributes["description"] = description }
        return attributes
    }
}

struct HCPMergedPullRequest: Equatable, Sendable {
    let number: Int
    let title: String
    let baseBranch: String
    let mergedAt: Date
    let workspaceID: String
}

struct HCPVariableSet: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let isGlobal: Bool
    let priority: Bool
    let variables: [HCPWorkspaceVariable]
}

struct HCPExplorerWorkspace: Equatable, Sendable {
    let workspaceID: String?
    let workspaceName: String
    let projectName: String?
    let currentRunStatus: String?
    let currentRunAppliedAt: Date?
    let drifted: Bool?
    let resourcesDrifted: Int?
    let resourcesUndrifted: Int?
    let resourceCount: Int?
    let terraformVersion: String?
    let vcsRepoIdentifier: String?
    let tags: [String]
    let checksFailed: Int?
    let checksErrored: Int?
    let updatedAt: Date?
}

struct HCPRun: Identifiable, Equatable, Sendable {
    let id: String
    let workspaceID: String
    let workspaceName: String
    let status: String
    let message: String?
    let operation: String?
    let createdAt: Date?
    let hasChanges: Bool?
    let isDestroy: Bool
    let planID: String?
    let applyID: String?
    let htmlURL: URL?
    /// Provenance, when HCP recorded it: how the run was started, who started
    /// it, and for repository-backed runs the branch, commit and sender.
    var source: String? = nil
    var createdBy: String? = nil
    var branch: String? = nil
    var commitSHA: String? = nil
    var commitURL: URL? = nil
    var sender: String? = nil
    var pullRequestNumber: Int? = nil

    /// "VCS", "API", "UI", "CLI", "Lifecycle", "Run trigger" from HCP's source string.
    var sourceWord: String? {
        switch source {
        case "tfe-configuration-version", "tfe-vcs": return "VCS"
        case "tfe-api": return "API"
        case "tfe-ui": return "UI"
        case "terraform+cloud", "terraform", "tfe-cli": return "CLI"
        case "tfe-infrastructure-lifecycle": return "Lifecycle"
        case "tfe-run-trigger": return "Run trigger"
        case "tfe-module-deploy": return "No-code module"
        case let other?: return other.replacingOccurrences(of: "tfe-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
        case nil: return nil
        }
    }
    var shortSHA: String? { commitSHA.map { String($0.prefix(7)) } }
    var isActive: Bool {
        !["applied", "discarded", "errored", "canceled", "force_canceled", "planned_and_finished", "planned_and_saved"].contains(status)
    }
}

struct HCPWorkspaceVariable: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let value: String?
    let category: String?
    let description: String
    let isSensitive: Bool
    let isHCL: Bool

    /// UI-only conservative mask for variables whose key looks credential-like.
    /// Keep `isSensitive` as the API's explicit value for write/editor policy.
    var isMaskedForDisplay: Bool {
        guard !isSensitive else { return true }
        let normalizedKey = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["secret", "password", "passwd", "token", "apikey", "accesskey", "privatekey",
                "credential", "authorization", "bearer"].contains { normalizedKey.contains($0) }
    }
}

struct HCPRunDetails: Equatable, Sendable {
    let run: HCPRun
    let planStatus: String?
    let applyStatus: String?
    let planLogs: String?
    let applyLogs: String?
    let planReviewURL: URL?
    let runURL: URL?
}

/// One recorded state version of a workspace. The run is the one that produced it, when HCP names one.
struct HCPStateVersionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let serial: Int?
    let createdAt: Date?
    let runID: String?
    let resourceCount: Int?
}

struct HCPPage<T: Sendable>: Sendable {
    let items: [T]
    let page: Int
    let hasNextPage: Bool
    let totalCount: Int?
}

enum HCPViewerError: LocalizedError, Equatable {
    case invalidHost
    case noCredential
    case invalidCredentialFile
    case credentialTooLarge
    case response(status: Int, message: String)
    case invalidResponse
    case rateLimited
    case responseTooLarge
    case transport(String)
    case featureUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHost: "Enter a valid HCP Terraform hostname."
        case .noCredential: "Import a Terraform CLI credential before connecting."
        case .invalidCredentialFile: "The selected Terraform credentials file does not contain a token for app.terraform.io."
        case .credentialTooLarge: "The Terraform credentials file is larger than the allowed 64 KB."
        case .response(let status, let message): "HCP Terraform returned HTTP \(status): \(message)"
        case .invalidResponse: "HCP Terraform returned a response Habitable could not read."
        case .rateLimited: "Refresh is cooling down to respect HCP Terraform's run-history limit. Try again shortly."
        case .responseTooLarge: "HCP Terraform returned more data than Habitable will read for this request."
        case .transport(let message): message
        case .featureUnavailable: "Explorer isn't available on this organization's plan."
        }
    }
}

protocol HCPTokenStore: Sendable {
    func read(hostname: String) throws -> String?
    func write(_ token: String, hostname: String) throws
    func delete(hostname: String) throws
}

struct KeychainHCPTokenStore: HCPTokenStore {
    private let service = "com.thrashr888.Habitable.hcp-terraform"
    func read(hostname: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(hostname, returningData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw HCPViewerError.transport("Could not read the HCP Terraform credential from Keychain (\(status)).")
        }
        return token
    }
    func write(_ token: String, hostname: String) throws {
        let base = query(hostname)
        let data = Data(token.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = base
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(insertion as CFDictionary, nil)
            guard add == errSecSuccess else { throw HCPViewerError.transport("Could not store the HCP Terraform credential in Keychain (\(add)).") }
        } else if status != errSecSuccess {
            throw HCPViewerError.transport("Could not store the HCP Terraform credential in Keychain (\(status)).")
        }
    }
    func delete(hostname: String) throws {
        let status = SecItemDelete(query(hostname) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HCPViewerError.transport("Could not remove the HCP Terraform credential from Keychain (\(status)).")
        }
    }
    private func query(_ host: String, returningData: Bool = false) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: host,
            kSecMatchLimit as String: kSecMatchLimitOne]
        if returningData { value[kSecReturnData as String] = true }
        return value
    }
}

struct HCPStoredSelection: Codable, Sendable {
    var identity: HCPConnectionIdentity
    var selectedWorkspaceID: String?
    var selectedRunID: String?
}

protocol HCPSelectionStore: Sendable {
    func load() -> HCPStoredSelection?
    func save(_ selection: HCPStoredSelection)
}

struct UserDefaultsHCPSelectionStore: HCPSelectionStore {
    private let key = "HCPWorkspaceViewer.selection.v1"
    func load() -> HCPStoredSelection? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HCPStoredSelection.self, from: data)
    }
    func save(_ selection: HCPStoredSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct HCPAPIClient: Sendable {
    let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration, delegate: HCPRedirectPolicy(), delegateQueue: nil)
    }

    private static let apiResponseLimit = 8 * 1024 * 1024
    private static let artifactResponseLimit = 2 * 1024 * 1024

    func organizations(hostname: String, token: String, page: Int) async throws -> HCPPage<HCPOrganization> {
        let object = try await get(path: "/api/v2/organizations", hostname: hostname, token: token, query: pagination(page))
        let data = array(object["data"])
        let items = data.compactMap { row -> HCPOrganization? in
            let attributes = row["attributes"] as? [String: Any] ?? [:]
            guard let name = attributes["name"] as? String ?? row["id"] as? String else { return nil }
            return HCPOrganization(name: name, email: attributes["email"] as? String)
        }
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func workspaces(hostname: String, organization: String, token: String, page: Int,
                    search: [URLQueryItem] = []) async throws -> HCPPage<HCPWorkspace> {
        let path = "/api/v2/organizations/\(pathComponent(organization))/workspaces"
        let include = [URLQueryItem(name: "include", value: "project,current_run")]
        let object = try await get(path: path, hostname: hostname, token: token, query: pagination(page) + search + include)
        let items = decodeWorkspaces(object, hostname: hostname, organization: organization)
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func runs(hostname: String, organization: String, workspace: HCPWorkspace, token: String, page: Int) async throws -> HCPPage<HCPRun> {
        let path = "/api/v2/workspaces/\(pathComponent(workspace.id))/runs"
        // The API omits plan_only runs unless an operation filter is supplied.
        let query = pagination(page) + [URLQueryItem(name: "filter[operation]", value: "plan_only,plan_and_apply,save_plan,refresh_only,destroy,empty_apply,action_only"),
                                        URLQueryItem(name: "include", value: "created_by,configuration_version.ingress_attributes")]
        let object = try await get(path: path, hostname: hostname, token: token, query: query)
        let provenance = RunProvenanceIndex(included: array(object["included"]))
        let items = array(object["data"]).compactMap { row in
            decodeRun(row, hostname: hostname, organization: organization, workspaceID: workspace.id, workspaceName: workspace.name)
                .map { provenance.apply(to: $0, row: row) }
        }
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func workspaceVariables(hostname: String, workspaceID: String, token: String, page: Int) async throws -> HCPPage<HCPWorkspaceVariable> {
        let path = "/api/v2/workspaces/\(pathComponent(workspaceID))/vars"
        let object = try await get(path: path, hostname: hostname, token: token, query: pagination(page))
        let items = array(object["data"]).compactMap(decodeWorkspaceVariable)
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func explorerWorkspaces(hostname: String, organization: String, token: String, page: Int) async throws -> HCPPage<HCPExplorerWorkspace> {
        let path = "/api/v2/organizations/\(pathComponent(organization))/explorer"
        let query = [URLQueryItem(name: "type", value: "workspaces"),
                     URLQueryItem(name: "page[number]", value: String(max(1, page))),
                     URLQueryItem(name: "page[size]", value: "100")]
        let object: [String: Any]
        do { object = try await get(path: path, hostname: hostname, token: token, query: query) }
        catch HCPViewerError.response(let status, _) where [402, 403, 404].contains(status) {
            throw HCPViewerError.featureUnavailable
        }
        return decodeExplorerPage(object, page: page)
    }

    func variableSets(hostname: String, workspaceID: String, token: String) async throws -> [HCPVariableSet] {
        let path = "/api/v2/workspaces/\(pathComponent(workspaceID))/varsets"
        var sets: [HCPVariableSet] = []
        for page in 1...5 {
            let object = try await get(path: path, hostname: hostname, token: token,
                                       query: pagination(page) + [URLQueryItem(name: "include", value: "vars")])
            sets.append(contentsOf: decodeVariableSets(object))
            guard nextPage(object) != nil else { break }
        }
        return sets
    }

    func updateWorkspaceVariable(hostname: String, workspaceID: String, variableID: String, value: String, token: String) async throws {
        guard let host = Self.normalizedHostname(hostname), let base = URL(string: "https://\(host)"),
              let url = URL(string: "/api/v2/workspaces/\(pathComponent(workspaceID))/vars/\(pathComponent(variableID))", relativeTo: base)?.absoluteURL else {
            throw HCPViewerError.invalidHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": ["type": "vars", "id": variableID, "attributes": ["value": value]]])
        do {
            let (data, response) = try await boundedData(for: request, limit: Self.apiResponseLimit)
            guard let http = response as? HTTPURLResponse else { throw HCPViewerError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw variableResponseError(status: http.statusCode) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let row = object["data"] as? [String: Any], row["type"] as? String == "vars",
                  row["id"] as? String == variableID else { throw HCPViewerError.invalidResponse }
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not reach HCP Terraform. Check the connection and try again.") }
    }

    // MARK: Writes for the making-changes flow

    private func writeURL(hostname: String, path: String) throws -> URL {
        guard let host = Self.normalizedHostname(hostname), let base = URL(string: "https://\(host)"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw HCPViewerError.invalidHost }
        return url
    }

    private func writeResponseError(status: Int) -> HCPViewerError {
        let message: String
        switch status {
        case 401: message = "The token was rejected. Reimport a user or team token."
        case 403: message = "This account cannot change that workspace. Check its permissions and entitlements."
        case 404: message = "The workspace or run is unavailable to this account."
        case 409: message = "The run is not in a state that allows this action."
        case 422: message = "HCP Terraform could not accept this change. Check the workspace settings."
        case 429: message = "HCP Terraform is limiting requests. Wait before trying again."
        default: message = "The request could not be completed."
        }
        return .response(status: status, message: message)
    }

    /// Sends a JSON:API write and returns the decoded body (empty object when the body is empty). 2xx is success.
    private func send(method: String, path: String, hostname: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: try writeURL(hostname: hostname, path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await boundedData(for: request, limit: Self.apiResponseLimit)
            guard let http = response as? HTTPURLResponse else { throw HCPViewerError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw writeResponseError(status: http.statusCode) }
            if data.isEmpty { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not reach HCP Terraform. Check the connection and try again.") }
    }

    func createConfigurationVersion(hostname: String, workspaceID: String, speculative: Bool,
                                    token: String) async throws -> (id: String, uploadURL: URL) {
        let body: [String: Any] = ["data": ["type": "configuration-versions",
                                            "attributes": ["auto-queue-runs": false, "speculative": speculative]] as [String: Any]]
        let object = try await send(method: "POST", path: "/api/v2/workspaces/\(pathComponent(workspaceID))/configuration-versions",
                                    hostname: hostname, token: token, body: body)
        guard let row = object["data"] as? [String: Any], let id = row["id"] as? String, !id.isEmpty,
              let attributes = row["attributes"] as? [String: Any],
              let value = attributes["upload-url"] as? String, let url = secureArtifactURL(value) else {
            throw HCPViewerError.invalidResponse
        }
        return (id, url)
    }

    /// The upload URL is signed; the API token is never sent to it.
    func uploadConfiguration(archive: Data, to uploadURL: URL) async throws {
        guard secureArtifactURL(uploadURL.absoluteString) != nil else { throw HCPViewerError.invalidResponse }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        do {
            let (_, response) = try await session.upload(for: request, from: archive)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HCPViewerError.transport("Could not upload the configuration to HCP Terraform. Try again.")
            }
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not upload the configuration to HCP Terraform. Check the connection and try again.") }
    }

    func createRun(hostname: String, organization: String, workspaceID: String, workspaceName: String,
                   configurationVersionID: String, message: String, planOnly: Bool, token: String) async throws -> HCPRun {
        let body = HCPProposal.previewRequestBody(workspaceID: workspaceID, configurationVersionID: configurationVersionID,
                                                  message: message, planOnly: planOnly)
        let object = try await send(method: "POST", path: "/api/v2/runs", hostname: hostname, token: token, body: body)
        guard let row = object["data"] as? [String: Any],
              let run = decodeRun(row, hostname: hostname, organization: organization,
                                  workspaceID: workspaceID, workspaceName: workspaceName) else { throw HCPViewerError.invalidResponse }
        return run
    }

    func run(hostname: String, organization: String, workspaceID: String, workspaceName: String,
             runID: String, token: String) async throws -> HCPRun {
        let object = try await get(path: "/api/v2/runs/\(pathComponent(runID))", hostname: hostname, token: token)
        guard let row = object["data"] as? [String: Any], row["id"] as? String == runID,
              let run = decodeRun(row, hostname: hostname, organization: organization,
                                  workspaceID: workspaceID, workspaceName: workspaceName) else { throw HCPViewerError.invalidResponse }
        return run
    }

    func applyRun(hostname: String, runID: String, comment: String, token: String) async throws {
        _ = try await send(method: "POST", path: "/api/v2/runs/\(pathComponent(runID))/actions/apply",
                           hostname: hostname, token: token, body: ["comment": comment])
    }

    func discardRun(hostname: String, runID: String, comment: String, token: String) async throws {
        _ = try await send(method: "POST", path: "/api/v2/runs/\(pathComponent(runID))/actions/discard",
                           hostname: hostname, token: token, body: ["comment": comment])
    }

    /// The structured plan (`terraform show -json` format). HCP answers 307 to a signed archivist URL,
    /// which `HCPPlanArtifactRedirectPolicy` follows without the API credential.
    func planJSONOutput(hostname: String, planID: String, token: String) async throws -> Data {
        var request = URLRequest(url: try writeURL(hostname: hostname, path: "/api/v2/plans/\(pathComponent(planID))/json-output"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        let failure = HCPViewerError.transport("Could not download the plan. Try again.")
        do {
            let delegate = HCPPlanArtifactRedirectPolicy(apiHost: Self.normalizedHostname(hostname) ?? "")
            let (data, response) = try await boundedData(for: request, limit: 32 * 1024 * 1024, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw HCPViewerError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 404 { throw writeResponseError(status: 404) }
                throw failure
            }
            return data
        } catch let error as HCPViewerError { throw error }
        catch { throw failure }
    }

    func runDetails(hostname: String, organization: String, run: HCPRun, token: String) async throws -> HCPRunDetails {
        let object = try await get(path: "/api/v2/runs/\(pathComponent(run.id))", hostname: hostname, token: token,
                                  query: [URLQueryItem(name: "include", value: "plan,apply")])
        guard let row = object["data"] as? [String: Any],
              var freshRun = decodeRun(row, hostname: hostname, organization: organization,
                                       workspaceID: run.workspaceID, workspaceName: run.workspaceName) else {
            throw HCPViewerError.invalidResponse
        }
        freshRun = HCPRun(id: freshRun.id, workspaceID: freshRun.workspaceID, workspaceName: run.workspaceName,
                          status: freshRun.status, message: freshRun.message, operation: freshRun.operation,
                          createdAt: freshRun.createdAt, hasChanges: freshRun.hasChanges, isDestroy: freshRun.isDestroy,
                          planID: freshRun.planID, applyID: freshRun.applyID, htmlURL: run.htmlURL ?? freshRun.htmlURL)
        let included = array(object["included"])
        let planRow = included.first { ($0["type"] as? String) == "plans" && ($0["id"] as? String) == freshRun.planID }
        let applyRow = included.first { ($0["type"] as? String) == "applies" && ($0["id"] as? String) == freshRun.applyID }
        var planLogs: String?
        var applyLogs: String?
        let planAttributes = planRow?["attributes"] as? [String: Any]
        let applyAttributes = applyRow?["attributes"] as? [String: Any]
        if let urlString = planAttributes?["log-read-url"] as? String,
           let url = secureArtifactURL(urlString) { planLogs = try await fetchArtifact(url) }
        if let urlString = applyAttributes?["log-read-url"] as? String,
           let url = secureArtifactURL(urlString) { applyLogs = try await fetchArtifact(url) }
        let planStatus = planAttributes?["status"] as? String
        let applyStatus = applyAttributes?["status"] as? String
        let planReview = freshRun.planID == nil ? nil : freshRun.htmlURL
        return HCPRunDetails(run: freshRun, planStatus: planStatus, applyStatus: applyStatus,
                             planLogs: Self.redactLogs(planLogs), applyLogs: Self.redactLogs(applyLogs),
                             planReviewURL: planReview, runURL: freshRun.htmlURL)
    }

    /// Both artifacts belong to the same immutable state version. Signed storage
    /// requests never inherit the API credential; Enterprise API paths may need it.
    func currentMap(hostname: String, workspaceID: String, token: String) async throws -> HCPMapSnapshot {
        let object = try await get(path: "/api/v2/workspaces/\(pathComponent(workspaceID))/current-state-version",
                                   hostname: hostname, token: token)
        return try await mapSnapshot(from: object, expectedWorkspaceID: workspaceID, hostname: hostname, token: token)
    }

    /// The map as of one recorded state version (state is authoritative; this is that version's state, not a reconstruction).
    func map(hostname: String, stateVersionID: String, token: String) async throws -> HCPMapSnapshot {
        let object = try await get(path: "/api/v2/state-versions/\(pathComponent(stateVersionID))",
                                   hostname: hostname, token: token)
        guard let row = object["data"] as? [String: Any], row["id"] as? String == stateVersionID else {
            throw HCPViewerError.invalidResponse
        }
        return try await mapSnapshot(from: object, expectedWorkspaceID: nil, hostname: hostname, token: token)
    }

    func stateVersions(hostname: String, organization: String, workspaceName: String, token: String,
                       page: Int) async throws -> HCPPage<HCPStateVersionSummary> {
        let query = [URLQueryItem(name: "filter[workspace][name]", value: workspaceName),
                     URLQueryItem(name: "filter[organization][name]", value: organization),
                     URLQueryItem(name: "page[number]", value: String(max(1, page))),
                     URLQueryItem(name: "page[size]", value: "100")]
        let object = try await get(path: "/api/v2/state-versions", hostname: hostname, token: token, query: query)
        let items = array(object["data"]).compactMap { row -> HCPStateVersionSummary? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let attributes = row["attributes"] as? [String: Any] ?? [:]
            let relationships = row["relationships"] as? [String: Any] ?? [:]
            return HCPStateVersionSummary(
                id: id, serial: attributes["serial"] as? Int,
                createdAt: (attributes["created-at"] as? String).flatMap(isoDate),
                runID: relationshipID(relationships["run"]),
                resourceCount: attributes["resource-count"] as? Int)
        }
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    private func mapSnapshot(from object: [String: Any], expectedWorkspaceID workspaceID: String?,
                             hostname: String, token: String) async throws -> HCPMapSnapshot {
        guard let row = object["data"] as? [String: Any], let id = row["id"] as? String,
              row["type"] as? String == "state-versions",
              let attributes = row["attributes"] as? [String: Any],
              let rawURLString = attributes["hosted-state-download-url"] as? String,
              let rawURL = secureArtifactURL(rawURLString) else { throw HCPViewerError.invalidResponse }
        if let relationships = row["relationships"] as? [String: Any],
           let related = relationshipID(relationships["workspace"]), let workspaceID, related != workspaceID {
            throw HCPViewerError.invalidResponse
        }
        let raw = try await fetchStateArtifact(rawURL, hostname: hostname, token: token)
        var shown: Data?
        if let value = attributes["hosted-json-state-download-url"] as? String {
            guard let url = secureArtifactURL(value) else { throw HCPViewerError.invalidResponse }
            shown = try await fetchStateArtifact(url, hostname: hostname, token: token)
        }
        let stateCreatedAt = (attributes["created-at"] as? String).flatMap(isoDate)
        let stateSerial = attributes["serial"] as? Int
        do {
            return try HCPMapSnapshot.decode(versionID: id, raw: raw, shown: shown,
                                             stateCreatedAt: stateCreatedAt, stateSerial: stateSerial)
        }
        catch { throw HCPViewerError.invalidResponse }
    }

    /// The current state version id without downloading the state; nil when the
    /// workspace has no current state version (404).
    func currentStateVersionID(hostname: String, workspaceID: String, token: String) async throws -> String? {
        let object: [String: Any]
        do {
            object = try await get(path: "/api/v2/workspaces/\(pathComponent(workspaceID))/current-state-version",
                                   hostname: hostname, token: token)
        } catch HCPViewerError.response(status: 404, message: _) { return nil }
        guard let row = object["data"] as? [String: Any], let id = row["id"] as? String, !id.isEmpty else {
            throw HCPViewerError.invalidResponse
        }
        return id
    }

    private func fetchStateArtifact(_ url: URL, hostname: String, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        if url.host?.lowercased() == Self.normalizedHostname(hostname), (url.port ?? 443) == 443,
           url.path.hasPrefix("/api/state-versions/") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let delegate: (any URLSessionTaskDelegate)? =
                Self.normalizedHostname(hostname) == "app.terraform.io" && url.host == "app.terraform.io"
                && url.path.hasPrefix("/api/state-versions/") ? HCPStateArtifactRedirectPolicy() : nil
            let (data, response) = try await boundedData(for: request, limit: 32 * 1024 * 1024, delegate: delegate)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HCPViewerError.transport("Could not download the selected state version. Refresh to try again.")
            }
            return data
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not download the selected state version. Refresh to try again.") }
    }

    private func get(path: String, hostname: String, token: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let host = Self.normalizedHostname(hostname), let base = URL(string: "https://\(host)"),
              var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw HCPViewerError.invalidHost
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw HCPViewerError.invalidHost }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        do {
            let (data, response) = try await boundedData(for: request, limit: Self.apiResponseLimit)
            guard let http = response as? HTTPURLResponse else { throw HCPViewerError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw responseError(data, status: http.statusCode) }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HCPViewerError.invalidResponse }
            return result
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not reach HCP Terraform. Check the connection and try again.") }
    }

    private func fetchArtifact(_ url: URL) async throws -> String? {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        // Signed artifact URLs carry their own authorization. Never forward the API token.
        do {
            let (data, response) = try await boundedData(for: request, limit: Self.artifactResponseLimit)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch HCPViewerError.responseTooLarge {
            return "Log output exceeded the 2 MB display limit."
        } catch { return nil }
    }

    private func secureArtifactURL(_ value: String) -> URL? {
        guard value.utf8.count <= 4096, let url = URL(string: value), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func boundedData(for request: URLRequest, limit: Int, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= Int64(limit) else {
            bytes.task.cancel()
            throw HCPViewerError.responseTooLarge
        }
        var body = Data()
        body.reserveCapacity(expected > 0 ? min(Int(expected), limit) : min(limit, 64 * 1024))
        do {
            for try await byte in bytes {
                guard body.count < limit else {
                    bytes.task.cancel()
                    throw HCPViewerError.responseTooLarge
                }
                body.append(byte)
            }
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not reach HCP Terraform. Check the connection and try again.") }
        return (body, response)
    }

    /// Decodes a workspaces list page, resolving `included` projects and current runs.
    func decodeWorkspaces(_ object: [String: Any], hostname: String, organization: String) -> [HCPWorkspace] {
        var projects: [String: [String: Any]] = [:], runs: [String: [String: Any]] = [:]
        for row in array(object["included"]) {
            guard let id = row["id"] as? String else { continue }
            switch row["type"] as? String {
            case "projects": projects[id] = row["attributes"] as? [String: Any] ?? [:]
            case "runs": runs[id] = row["attributes"] as? [String: Any] ?? [:]
            default: break
            }
        }
        return array(object["data"]).compactMap { row in
            guard let base = decodeWorkspace(row, hostname: hostname, organization: organization) else { return nil }
            let attributes = row["attributes"] as? [String: Any] ?? [:]
            let relationships = row["relationships"] as? [String: Any] ?? [:]
            let projectID = relationshipID(relationships["project"])
            let run = relationshipID(relationships["current-run"]).flatMap { runs[$0] }
            return HCPWorkspace(id: base.id, name: base.name, terraformVersion: base.terraformVersion,
                                executionMode: base.executionMode, locked: base.locked, htmlURL: base.htmlURL,
                                tagNames: base.tagNames, vcs: base.vcs,
                                projectID: projectID,
                                projectName: projectID.flatMap { projects[$0]?["name"] as? String },
                                currentRunStatus: run?["status"] as? String,
                                currentRunCreatedAt: (run?["created-at"] as? String).flatMap(isoDate),
                                updatedAt: (attributes["updated-at"] as? String).flatMap(isoDate),
                                resourceCount: attributes["resource-count"] as? Int,
                                description: base.description,
                                autoApply: base.autoApply, workingDirectory: base.workingDirectory)
        }
    }

    func decodeExplorerPage(_ object: [String: Any], page: Int) -> HCPPage<HCPExplorerWorkspace> {
        func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap(Int.init) }
        func bool(_ value: Any?) -> Bool? { (value as? Bool) ?? (value as? String).flatMap { Bool($0) } }
        func date(_ value: Any?) -> Date? { (value as? String).flatMap(isoDate) }
        let items = array(object["data"]).compactMap { row -> HCPExplorerWorkspace? in
            let a = row["attributes"] as? [String: Any] ?? [:]
            guard let name = a["workspace_name"] as? String else { return nil }
            let tags: [String]
            if let list = a["tags"] as? [String] { tags = list }
            else if let text = a["tags"] as? String { tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            else { tags = [] }
            return HCPExplorerWorkspace(
                workspaceID: a["external_id"] as? String, workspaceName: name,
                projectName: a["project_name"] as? String,
                currentRunStatus: a["current_run_status"] as? String,
                currentRunAppliedAt: date(a["current_run_applied_at"]),
                drifted: bool(a["drifted"]), resourcesDrifted: int(a["resources_drifted"]),
                resourcesUndrifted: int(a["resources_undrifted"]), resourceCount: int(a["resource_count"]),
                terraformVersion: a["workspace_terraform_version"] as? String,
                vcsRepoIdentifier: a["vcs_repo_identifier"] as? String, tags: tags,
                checksFailed: int(a["checks_failed"]), checksErrored: int(a["checks_errored"]),
                updatedAt: date(a["workspace_updated_at"]))
        }
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func decodeVariableSets(_ object: [String: Any]) -> [HCPVariableSet] {
        var vars: [String: HCPWorkspaceVariable] = [:]
        for row in array(object["included"]) {
            if let variable = decodeWorkspaceVariable(row) { vars[variable.id] = variable }
        }
        return array(object["data"]).compactMap { row in
            guard let id = row["id"] as? String, let a = row["attributes"] as? [String: Any],
                  let name = a["name"] as? String else { return nil }
            let refs = (((row["relationships"] as? [String: Any])?["vars"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            return HCPVariableSet(id: id, name: name, description: a["description"] as? String ?? "",
                                  isGlobal: a["global"] as? Bool ?? false, priority: a["priority"] as? Bool ?? false,
                                  variables: refs.compactMap { ($0["id"] as? String).flatMap { vars[$0] } })
        }
    }

    private func decodeWorkspace(_ row: [String: Any], hostname: String, organization: String) -> HCPWorkspace? {
        guard let id = row["id"] as? String, let attributes = row["attributes"] as? [String: Any],
              let name = attributes["name"] as? String else { return nil }
        let url = URL(string: "https://\(hostname)/app/\(pathComponent(organization))/workspaces/\(pathComponent(name))")
        return HCPWorkspace(id: id, name: name, terraformVersion: attributes["terraform-version"] as? String,
                            executionMode: attributes["execution-mode"] as? String,
                            locked: attributes["locked"] as? Bool ?? false, htmlURL: url,
                            tagNames: attributes["tag-names"] as? [String] ?? [],
                            vcs: HCPVCSRepository.decode(attributes: attributes),
                            description: (attributes["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            autoApply: attributes["auto-apply"] as? Bool ?? false,
                            workingDirectory: (attributes["working-directory"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Changes workspace settings (`terraform-version`, `auto-apply`, `execution-mode`,
    /// `working-directory`, `description`) and returns the workspace as HCP now has it.
    func updateWorkspace(hostname: String, organization: String, workspaceID: String,
                         settings: HCPWorkspaceSettingsChange, token: String) async throws -> HCPWorkspace {
        let attributes = settings.attributes
        guard let host = Self.normalizedHostname(hostname), let base = URL(string: "https://\(host)"),
              let url = URL(string: "/api/v2/workspaces/\(pathComponent(workspaceID))", relativeTo: base)?.absoluteURL else {
            throw HCPViewerError.invalidHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": ["type": "workspaces", "id": workspaceID, "attributes": attributes]])
        do {
            let (data, response) = try await boundedData(for: request, limit: Self.apiResponseLimit)
            guard let http = response as? HTTPURLResponse else { throw HCPViewerError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw HCPViewerError.response(status: http.statusCode, message: "HCP Terraform did not accept the change.")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let row = object["data"] as? [String: Any], row["id"] as? String == workspaceID,
                  let workspace = decodeWorkspace(row, hostname: hostname, organization: organization) else { throw HCPViewerError.invalidResponse }
            return workspace
        } catch let error as HCPViewerError { throw error }
        catch { throw HCPViewerError.transport("Could not reach HCP Terraform. Check the connection and try again.") }
    }

    private func decodeWorkspaceVariable(_ row: [String: Any]) -> HCPWorkspaceVariable? {
        guard row["type"] as? String == "vars", let id = row["id"] as? String,
              let attributes = row["attributes"] as? [String: Any], let key = attributes["key"] as? String else { return nil }
        let sensitive = attributes["sensitive"] as? Bool ?? false
        return HCPWorkspaceVariable(id: id, key: key, value: sensitive ? nil : attributes["value"] as? String,
                                    category: attributes["category"] as? String,
                                    description: attributes["description"] as? String ?? "",
                                    isSensitive: sensitive, isHCL: attributes["hcl"] as? Bool ?? false)
    }

    private func decodeRun(_ row: [String: Any], hostname: String, organization: String,
                           workspaceID: String, workspaceName: String) -> HCPRun? {
        guard let id = row["id"] as? String, let attributes = row["attributes"] as? [String: Any],
              let status = attributes["status"] as? String else { return nil }
        let relationships = row["relationships"] as? [String: Any] ?? [:]
        let planID = relationshipID(relationships["plan"])
        let applyID = relationshipID(relationships["apply"])
        let date = (attributes["created-at"] as? String).flatMap(isoDate)
        let url = URL(string: "https://\(hostname)/app/\(pathComponent(organization))/workspaces/\(pathComponent(workspaceName))/runs/\(pathComponent(id))")
        var run = HCPRun(id: id, workspaceID: workspaceID, workspaceName: workspaceName, status: status,
                         message: attributes["message"] as? String, operation: attributes["operation"] as? String,
                         createdAt: date, hasChanges: attributes["has-changes"] as? Bool,
                         isDestroy: attributes["is-destroy"] as? Bool ?? false,
                         planID: planID, applyID: applyID, htmlURL: url)
        run.source = attributes["source"] as? String
        return run
    }

    /// The `included` rows of a runs page: users, configuration versions and their
    /// ingress attributes, joined back onto each run.
    struct RunProvenanceIndex {
        private var users: [String: String] = [:]
        private var ingressByConfiguration: [String: String] = [:]
        private var ingress: [String: [String: Any]] = [:]

        init(included: [[String: Any]]) {
            for row in included {
                guard let id = row["id"] as? String else { continue }
                let attributes = row["attributes"] as? [String: Any] ?? [:]
                let relationships = row["relationships"] as? [String: Any] ?? [:]
                switch row["type"] as? String {
                case "users": if let name = attributes["username"] as? String { users[id] = name }
                case "configuration-versions":
                    if let data = relationships["ingress-attributes"] as? [String: Any],
                       let ref = data["data"] as? [String: Any], let ingressID = ref["id"] as? String {
                        ingressByConfiguration[id] = ingressID
                    }
                case "ingress-attributes": ingress[id] = attributes
                default: break
                }
            }
        }

        func apply(to run: HCPRun, row: [String: Any]) -> HCPRun {
            var run = run
            let relationships = row["relationships"] as? [String: Any] ?? [:]
            func relationshipID(_ value: Any?) -> String? {
                ((value as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
            }
            if let userID = relationshipID(relationships["created-by"]) { run.createdBy = users[userID] }
            if let configurationID = relationshipID(relationships["configuration-version"]),
               let ingressID = ingressByConfiguration[configurationID], let attributes = ingress[ingressID] {
                run.branch = (attributes["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                run.commitSHA = (attributes["commit-sha"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                run.sender = (attributes["sender-username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                run.pullRequestNumber = (attributes["pull-request-number"] as? NSNumber)?.intValue
                if let text = attributes["commit-url"] as? String, let url = URL(string: text), url.scheme == "https" { run.commitURL = url }
            }
            return run
        }
    }

    private func responseError(_ data: Data, status: Int) -> HCPViewerError {
        let fallback: String
        switch status {
        case 401: fallback = "The token was rejected. Reimport a user or team token."
        case 403: fallback = "This account cannot view that organization, workspace, or run. Check its permissions and entitlements."
        case 404: fallback = "The organization, workspace, or run is unavailable to this account."
        case 429: fallback = "HCP Terraform is limiting requests. Wait before refreshing."
        default: fallback = "The request could not be completed."
        }
        _ = data // API error details are intentionally omitted because they can echo secrets.
        return .response(status: status, message: fallback)
    }

    private func variableResponseError(status: Int) -> HCPViewerError {
        let message: String
        switch status {
        case 401: message = "The token was rejected. Reimport a user or team token."
        case 403: message = "This account cannot edit that workspace variable. Check its permissions and entitlements."
        case 404: message = "The workspace variable is unavailable to this account."
        case 429: message = "HCP Terraform is limiting requests. Wait before trying again."
        default: message = "The request could not be completed."
        }
        return .response(status: status, message: message)
    }

    private func pagination(_ page: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page[number]", value: String(max(1, page))), URLQueryItem(name: "page[size]", value: "50")]
    }
    private func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    private func nextPage(_ object: [String: Any]) -> String? { (object["links"] as? [String: Any])?["next"] as? String }
    private func paginationCount(_ object: [String: Any]) -> Int? {
        ((object["meta"] as? [String: Any])?["pagination"] as? [String: Any])?["total-count"] as? Int
    }
    private func relationshipID(_ value: Any?) -> String? { (value as? [String: Any])?["data"].flatMap { ($0 as? [String: Any])?["id"] as? String } }
    private func pathComponent(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? value }
    private func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func normalizedHostname(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty, !value.contains("/"), !value.contains("@"), !value.contains(":") else { return nil }
        let labels = value.split(separator: ".")
        guard !value.contains(".."), labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-" && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        return value
    }
    /// The last meaningful lines of a log, for an error summary.
    static func logTail(_ log: String?, lines: Int = 30) -> String? {
        guard let log else { return nil }
        let kept = stripANSI(log).split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !kept.isEmpty else { return nil }
        return kept.suffix(lines).joined(separator: "\n")
    }

    /// Removes terminal color and style sequences, including ones whose escape
    /// byte was already lost in transit (`[31m` on its own).
    static func stripANSI(_ text: String) -> String {
        let patterns = [#"\u{1B}\[[0-9;?]*[A-Za-z]"#, #"(?<![\w\]])\[[0-9;]*m"#]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    static func redactLogs(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var output = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            redactStructuredLog(String(line))
        }.joined(separator: "\n")
        let patterns: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*bearer\s+)\S+"#, "$1[redacted]"),
            (#"(?i)([\"']?[A-Za-z0-9_-]*(?:token|password|secret|private[_-]?key|access[_-]?key|client[_-]?secret|credential)[A-Za-z0-9_-]*[\"']?\s*[:=]\s*)(\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;]+)"#, "$1[redacted]"),
            (#"(?i)(TF_VAR_[A-Za-z0-9_]+\s*=\s*)([^\s]+)"#, "$1[redacted]")
        ]
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(output.prefix(100_000))
    }

    private static func redactStructuredLog(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return line }
        func scrub(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                let sensitive = dictionary["sensitive"] as? Bool == true
                var result: [String: Any] = [:]
                for (key, item) in dictionary {
                    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                    let secretKey = ["password", "token", "secret", "private_key", "access_key", "client_secret", "credential"]
                        .contains(where: normalized.contains)
                    if secretKey || (sensitive && ["value", "values", "before", "after", "raw"].contains(key)) {
                        result[key] = "[redacted]"
                    } else {
                        result[key] = scrub(item)
                    }
                }
                return result
            }
            if let array = value as? [Any] { return array.map(scrub) }
            return value
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: scrub(value), options: [.fragmentsAllowed, .sortedKeys]),
              let sanitized = String(data: encoded, encoding: .utf8) else { return line }
        return sanitized
    }
}

/// HCP's authenticated state endpoint redirects to its Archivist service.
/// Scope this exception to that exact endpoint and destination; never forward
/// API credentials, cookies, or a request body to the artifact service.
final class HCPStateArtifactRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = task.originalRequest?.url,
              source.scheme == "https", source.host == "app.terraform.io", (source.port ?? 443) == 443,
              source.path.hasPrefix("/api/state-versions/"), source.user == nil, source.password == nil,
              task.originalRequest?.httpMethod == "GET",
              let target = request.url, target.scheme == "https",
              target.host == "archivist.terraform.io", (target.port ?? 443) == 443,
              target.user == nil, target.password == nil else {
            completionHandler(nil)
            return
        }
        var sanitized = URLRequest(url: target)
        sanitized.httpMethod = "GET"
        sanitized.timeoutInterval = request.timeoutInterval
        sanitized.httpShouldHandleCookies = false
        completionHandler(sanitized)
    }
}

/// The plan JSON endpoint redirects to a signed archivist URL. Follow only that hop (or a same-origin
/// Enterprise redirect), and never forward the API credential to another host.
final class HCPPlanArtifactRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let apiHost: String
    init(apiHost: String) { self.apiHost = apiHost }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = task.originalRequest?.url,
              source.scheme == "https", source.host?.lowercased() == apiHost, (source.port ?? 443) == 443,
              source.path.hasPrefix("/api/v2/plans/"), task.originalRequest?.httpMethod == "GET",
              let target = request.url, target.scheme == "https", (target.port ?? 443) == 443,
              target.user == nil, target.password == nil, let targetHost = target.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        if targetHost == apiHost {
            completionHandler(request)
        } else if apiHost == "app.terraform.io", targetHost == "archivist.terraform.io" {
            var sanitized = URLRequest(url: target)
            sanitized.httpMethod = "GET"
            sanitized.timeoutInterval = request.timeoutInterval
            sanitized.httpShouldHandleCookies = false
            completionHandler(sanitized)
        } else {
            completionHandler(nil)
        }
    }
}

/// Credentialed API requests may only follow redirects within their original HTTPS origin.
/// Signed artifact requests have no API bearer and are allowed to follow HTTPS storage redirects.
final class HCPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, target.scheme?.lowercased() == "https",
              target.user == nil, target.password == nil else {
            completionHandler(nil)
            return
        }
        if task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil {
            guard let source = task.originalRequest?.url, Self.sameOrigin(source, target) else {
                completionHandler(nil)
                return
            }
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return left.scheme?.lowercased() == "https" && right.scheme?.lowercased() == "https"
            && left.host?.lowercased() == right.host?.lowercased()
            && (left.port ?? 443) == (right.port ?? 443)
    }
}

@MainActor
final class HCPWorkspaceViewerModel: ObservableObject {
    let isSample: Bool
    @Published private(set) var identity: HCPConnectionIdentity
    @Published private(set) var organizations: [HCPOrganization] = []
    @Published private(set) var workspaces: [HCPWorkspace] = []
    @Published private(set) var runs: [HCPRun] = []
    @Published private(set) var selectedRunDetails: HCPRunDetails?
    @Published private(set) var mapSnapshot: HCPMapSnapshot?
    @Published private(set) var isLoadingMap = false
    @Published private(set) var mapError: String?
    private var mapOperation = UUID()
    @Published private(set) var stateVersions: [HCPStateVersionSummary] = []
    @Published private(set) var viewingStateVersion: HCPStateVersionSummary?
    @Published private(set) var historicalSnapshot: HCPMapSnapshot?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyError: String?
    private var historyOperation = UUID()
    @Published private(set) var workspaceVariables: [HCPWorkspaceVariable] = []
    @Published private(set) var isLoadingVariables = false
    @Published private(set) var variablesError: String?
    @Published private(set) var savingVariableID: String?
    @Published private(set) var variableSets: [HCPVariableSet] = []
    @Published private(set) var variableSetsError: String?
    @Published private(set) var explorerRows: [String: HCPExplorerWorkspace] = [:]
    @Published private(set) var explorerUnavailable = false
    private var variablesOperation = UUID()

    var mapRequestKey: String {
        "\(isConnected)|\(hostname)|\(selectedOrganization)|\(selectedWorkspaceID ?? "")"
    }

    private func invalidateMap() {
        mapOperation = UUID()
        mapSnapshot = nil
        mapError = nil
        isLoadingMap = false
        invalidateHistory()
        invalidateVariables()
        invalidateProposal()
    }

    private func invalidateHistory() {
        historyOperation = UUID()
        stateVersions = []
        viewingStateVersion = nil
        historicalSnapshot = nil
        historyError = nil
        isLoadingHistory = false
    }

    func returnToCurrentState() {
        historyOperation = UUID()
        viewingStateVersion = nil
        historicalSnapshot = nil
        historyError = nil
        isLoadingHistory = false
    }

    func refreshStateVersions() async {
        guard !isSample, isConnected, let workspace = selectedWorkspace,
              let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else { return }
        let operation = historyOperation
        let host = hostname, organization = selectedOrganization
        func current() -> Bool {
            !Task.isCancelled && historyOperation == operation && isConnected && hostname == host
                && selectedOrganization == organization && selectedWorkspaceID == workspace.id
        }
        var collected: [HCPStateVersionSummary] = []
        do {
            for page in 1...2 {
                let result = try await client.stateVersions(hostname: host, organization: organization,
                                                            workspaceName: workspace.name, token: token, page: page)
                guard current() else { return }
                collected += result.items
                if !result.hasNextPage { break }
            }
            stateVersions = collected.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        } catch {
            guard current() else { return }
            historyError = "Couldn’t load this workspace’s state versions."
        }
    }

    func showStateVersion(_ version: HCPStateVersionSummary) async {
        guard !isSample, isConnected, let workspace = selectedWorkspace else { return }
        let operation = UUID()
        historyOperation = operation
        let host = hostname, organization = selectedOrganization
        viewingStateVersion = version
        historicalSnapshot = nil
        historyError = nil
        guard let token = try? tokenStore.read(hostname: host), !token.isEmpty else {
            historyError = "Your HCP credential is unavailable. Reconnect to load that state version."
            return
        }
        isLoadingHistory = true
        defer { if historyOperation == operation { isLoadingHistory = false } }
        do {
            let snapshot = try await client.map(hostname: host, stateVersionID: version.id, token: token)
            guard !Task.isCancelled, historyOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspace.id else { return }
            historicalSnapshot = snapshot
        } catch {
            guard !Task.isCancelled, historyOperation == operation, isConnected else { return }
            historyError = "Couldn’t load that state version."
        }
    }

    /// Finds the state version produced by a run (refreshing the list if needed) and shows it; false when the run produced none (plan-only, errored).
    func showStateVersion(forRunID runID: String) async -> Bool {
        if !stateVersions.contains(where: { $0.runID == runID }) { await refreshStateVersions() }
        guard let version = stateVersions.first(where: { $0.runID == runID }) else { return false }
        await showStateVersion(version)
        return true
    }

    // MARK: Making changes (API-driven runs)

    @Published private(set) var proposal: HCPProposal?
    @Published private(set) var proposalError: String?
    /// A pull request merged from Habitable; the face follows the run it starts.
    @Published private(set) var recentMerge: HCPMergedPullRequest?

    func noteMerge(_ merge: HCPMergedPullRequest) { recentMerge = merge }
    func clearMerge() { recentMerge = nil }

    /// The run HCP started for a merge: a run in the same workspace, created
    /// since the merge, whose message names the pull request by number
    /// ("Title (#12)" for a squash, "Merge pull request #12 …" otherwise). A
    /// title match alone is not enough to offer Confirm Apply on a run.
    func run(for merge: HCPMergedPullRequest) -> HCPRun? {
        guard merge.workspaceID == selectedWorkspaceID else { return nil }
        let since = merge.mergedAt.addingTimeInterval(-90)
        return runs
            .filter { $0.workspaceID == merge.workspaceID && ($0.createdAt ?? .distantPast) >= since }
            .first { Self.message($0.message, namesPullRequest: merge.number) }
    }

    nonisolated static func message(_ message: String?, namesPullRequest number: Int) -> Bool {
        guard let message else { return false }
        let pattern = "(^|[^0-9])#\(number)([^0-9]|$)"
        return message.range(of: pattern, options: .regularExpression) != nil
    }
    /// The tail of the failed run's plan log, redacted, so the reason is readable here.
    @Published private(set) var proposalLog: String?
    /// A face another window asks the cloud window to show (e.g. a checkout's
    /// "Make a change" opens Proposal). The page consumes and clears it.
    @Published var requestedFace: String?
    @Published private(set) var proposalPreview: MapChangePreview?
    @Published private(set) var isProposing = false
    @Published private(set) var previewedRunID: String?
    private var proposalOperation = UUID()
    private var proposalTask: Task<Void, Never>?
    private var proposalPlanAttempted = false

    private func invalidateProposal() {
        recentMerge = nil
        proposalLog = nil
        proposalOperation = UUID()
        proposalTask?.cancel()
        proposalTask = nil
        proposal = nil
        proposalError = nil
        proposalPreview = nil
        previewedRunID = nil
        isProposing = false
        proposalPlanAttempted = false
    }

    func dismissProposal() { invalidateProposal() }

    private func proposalFailureMessage(_ error: Error, fallback: String) -> String {
        if let viewer = error as? HCPViewerError, case .response(_, let message) = viewer { return message }
        if let viewer = error as? HCPViewerError, case .transport(let message) = viewer { return message }
        if let archive = error as? ConfigurationArchive.ArchiveError { return archive.errorDescription ?? fallback }
        return fallback
    }

    /// Downloads and parses a plan's JSON output against the current map; nil when unavailable.
    private func loadPlanPreview(hostname host: String, planID: String, token: String) async -> MapChangePreview? {
        guard let data = try? await client.planJSONOutput(hostname: host, planID: planID, token: token),
              let text = String(data: data, encoding: .utf8), let plan = parseTerraformPlan(text) else { return nil }
        let map = mapSnapshot?.map ?? ResourceMap(tiles: [], connections: [], dataSources: [])
        return try? MapChangePreview.build(plan: plan, currentMap: map)
    }

    /// Shows the planned changes for any run (for example one HCP created from a pull request).
    func showPlanPreview(for run: HCPRun) async {
        guard !isSample, isConnected, let workspace = selectedWorkspace,
              let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else { return }
        let host = hostname, organization = selectedOrganization
        let operation = proposalOperation
        do {
            var planID = run.planID
            if planID == nil {
                let fresh = try await client.run(hostname: host, organization: organization, workspaceID: workspace.id,
                                                 workspaceName: workspace.name, runID: run.id, token: token)
                planID = fresh.planID
            }
            guard let planID else { proposalError = "This run has no plan to preview yet."; return }
            let preview = await loadPlanPreview(hostname: host, planID: planID, token: token)
            guard proposalOperation == operation, selectedWorkspaceID == workspace.id else { return }
            guard let preview else { proposalError = "Couldn’t read this run’s plan. Open it in HCP Terraform instead."; return }
            proposalPreview = preview
            previewedRunID = run.id
            proposalError = nil
        } catch {
            guard proposalOperation == operation else { return }
            proposalError = proposalFailureMessage(error, fallback: "Couldn’t load this run’s plan. Try again.")
        }
    }

    func confirmApply(run: HCPRun) async {
        if await applyRunAction(runID: run.id, discard: false) { await refreshRuns(force: true) }
    }

    func discard(run: HCPRun) async {
        if await applyRunAction(runID: run.id, discard: true) { await refreshRuns(force: true) }
    }

    /// Shared apply/discard call; sets `proposalError` and returns false on failure.
    private func applyRunAction(runID: String, discard: Bool) async -> Bool {
        guard !isSample, isConnected, let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else { return false }
        let operation = proposalOperation
        do {
            if discard {
                try await client.discardRun(hostname: hostname, runID: runID, comment: "Discarded in Habitable", token: token)
            } else {
                try await client.applyRun(hostname: hostname, runID: runID, comment: "Approved in Habitable", token: token)
            }
            guard proposalOperation == operation else { return false }
            proposalError = nil
            return true
        } catch {
            guard proposalOperation == operation else { return false }
            proposalError = proposalFailureMessage(error, fallback: discard ? "Couldn’t discard this run. Try again." : "Couldn’t apply this run. Try again.")
            return false
        }
    }

    /// Uploads the folder as a configuration version and starts a run that waits for confirmation.
    func propose(folder: URL, message: String) async {
        guard !isSample, isConnected, let workspace = selectedWorkspace else { return }
        guard let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else {
            proposalError = "Your HCP credential is unavailable. Reconnect to propose a change."
            return
        }
        invalidateProposal()
        let operation = UUID()
        proposalOperation = operation
        let host = hostname, organization = selectedOrganization
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let runMessage = trimmed.isEmpty ? "Proposed from Habitable" : String(trimmed.prefix(500))
        isProposing = true
        defer { if proposalOperation == operation { isProposing = false } }
        do {
            let archive = try await Task.detached { try ConfigurationArchive.make(folder: folder) }.value
            let version = try await client.createConfigurationVersion(hostname: host, workspaceID: workspace.id,
                                                                       speculative: false, token: token)
            guard proposalOperation == operation else { return }
            try await client.uploadConfiguration(archive: archive, to: version.uploadURL)
            guard proposalOperation == operation else { return }
            let run = try await client.createRun(hostname: host, organization: organization, workspaceID: workspace.id,
                                                 workspaceName: workspace.name, configurationVersionID: version.id,
                                                 message: runMessage, planOnly: false, token: token)
            guard proposalOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspace.id else { return }
            proposal = HCPProposal(runID: run.id, workspaceID: workspace.id, message: runMessage,
                                   createdAt: run.createdAt ?? Date(), status: run.status, planID: run.planID, folder: folder)
            proposalError = nil
            await refreshRuns(force: true)
            guard proposalOperation == operation else { return }
            pollProposal()
        } catch {
            guard proposalOperation == operation else { return }
            proposalError = proposalFailureMessage(error, fallback: "Couldn’t start the run. Check access and try again.")
        }
    }

    /// Polls the proposal's run every 4 seconds until it needs confirmation or finishes.
    func pollProposal() {
        proposalTask?.cancel()
        guard proposal != nil else { return }
        let operation = proposalOperation
        proposalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.proposalOperation == operation else { return }
                if await self.pollProposalOnce(operation: operation) { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    /// One poll step. Returns true when polling should stop.
    private func pollProposalOnce(operation: UUID) async -> Bool {
        guard let current = proposal, isConnected, let workspace = selectedWorkspace, workspace.id == current.workspaceID,
              let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else { return true }
        let host = hostname, organization = selectedOrganization
        do {
            let run = try await client.run(hostname: host, organization: organization, workspaceID: workspace.id,
                                           workspaceName: workspace.name, runID: current.runID, token: token)
            guard proposalOperation == operation, proposal?.runID == current.runID else { return true }
            proposal?.status = run.status
            proposal?.planID = run.planID ?? proposal?.planID
            proposalError = nil
            let planReady = ["planned", "cost_estimated", "policy_checked", "applied", "confirmed", "apply_queued", "applying"].contains(run.status)
            if planReady, let planID = run.planID, !proposalPlanAttempted {
                proposalPlanAttempted = true
                if let preview = await loadPlanPreview(hostname: host, planID: planID, token: token), proposalOperation == operation {
                    proposalPreview = preview
                    previewedRunID = current.runID
                }
            }
            switch HCPProposal.step(forStatus: run.status) {
            case .planning, .applying:
                return false
            case .applied:
                await finishProposalRefresh(operation: operation)
                return true
            case .errored:
                // Bring the log here; the failure's cause is usually in its last lines.
                if let details = try? await client.runDetails(hostname: host, organization: organization, run: run, token: token),
                   proposalOperation == operation {
                    proposalLog = HCPAPIClient.logTail(details.planLogs ?? details.applyLogs)
                }
                return true
            case .needsConfirmation, .discarded, .uploading:
                return true
            }
        } catch {
            guard proposalOperation == operation else { return true }
            proposalError = proposalFailureMessage(error, fallback: "Couldn’t check the run. Retrying.")
            // A rejected credential or missing run will not recover by polling.
            if case HCPViewerError.response(let status, _) = error, [401, 403, 404].contains(status) { return true }
            return false
        }
    }

    private func finishProposalRefresh(operation: UUID) async {
        await refreshRuns(force: true)
        guard proposalOperation == operation else { return }
        await refreshMap()
    }

    func confirmProposalApply() async {
        guard let current = proposal else { return }
        let operation = proposalOperation
        guard await applyRunAction(runID: current.runID, discard: false), proposalOperation == operation else { return }
        proposal?.status = "confirmed"
        pollProposal()
    }

    func discardProposal() async {
        guard let current = proposal else { return }
        let operation = proposalOperation
        guard await applyRunAction(runID: current.runID, discard: true), proposalOperation == operation else { return }
        proposalTask?.cancel()
        proposal?.status = "discarded"
        await refreshRuns(force: true)
    }

    private func invalidateVariables() {
        variablesOperation = UUID()
        workspaceVariables = []
        variablesError = nil
        variableSets = []
        variableSetsError = nil
        isLoadingVariables = false
        savingVariableID = nil
    }

    func refreshVariables() async {
        guard !isSample, isConnected, let workspace = selectedWorkspace,
              let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else {
            invalidateVariables()
            return
        }
        let operation = UUID()
        variablesOperation = operation
        let host = hostname, organization = selectedOrganization, workspaceID = workspace.id
        workspaceVariables = []
        variablesError = nil
        variableSets = []
        variableSetsError = nil
        isLoadingVariables = true
        defer { if variablesOperation == operation { isLoadingVariables = false } }
        do {
            var page = 1
            var loaded: [HCPWorkspaceVariable] = []
            while true {
                let result = try await client.workspaceVariables(hostname: host, workspaceID: workspaceID, token: token, page: page)
                guard !Task.isCancelled, variablesOperation == operation, isConnected, hostname == host,
                      selectedOrganization == organization, selectedWorkspaceID == workspaceID else { return }
                loaded.append(contentsOf: result.items)
                guard result.hasNextPage, page < 100 else { break }
                page += 1
            }
            workspaceVariables = loaded
        } catch {
            guard variablesOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspaceID else { return }
            variablesError = "Couldn’t load workspace variables. Check access and refresh to try again."
            return
        }
        do {
            let sets = try await client.variableSets(hostname: host, workspaceID: workspaceID, token: token)
            guard !Task.isCancelled, variablesOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspaceID else { return }
            variableSets = sets
        } catch {
            guard variablesOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspaceID else { return }
            variableSetsError = "Couldn’t load variable sets. Check access and refresh to try again."
        }
    }

    /// Loads the Explorer view of the organization (drift, resource counts, checks).
    /// Silent fallback: an unavailable plan sets `explorerUnavailable`; other errors keep current rows.
    func refreshExplorer() async {
        guard !isSample, isConnected, let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else { return }
        let host = hostname, organization = selectedOrganization, operation = currentOperation
        func current() -> Bool { currentOperation == operation && isConnected && hostname == host && selectedOrganization == organization }
        do {
            var rows: [String: HCPExplorerWorkspace] = [:]
            var page = 1
            while true {
                let result = try await client.explorerWorkspaces(hostname: host, organization: organization, token: token, page: page)
                guard !Task.isCancelled, current() else { return }
                for item in result.items { rows[item.workspaceName] = item }
                guard result.hasNextPage, page < 10 else { break }
                page += 1
            }
            explorerRows = rows
            explorerUnavailable = false
        } catch HCPViewerError.featureUnavailable {
            guard current() else { return }
            explorerRows = [:]
            explorerUnavailable = true
        } catch {}
    }

    @Published private(set) var workspaceSettingsError: String?
    @Published private(set) var isSavingWorkspaceSettings = false

    /// Saves changed workspace settings. Only the keys passed are sent; the
    /// local workspace record takes HCP's answer for those fields.
    func updateWorkspaceSettings(_ settings: HCPWorkspaceSettingsChange) async -> Bool {
        guard !isSample, isConnected, let workspace = selectedWorkspace, !settings.isEmpty,
              let token = try? tokenStore.read(hostname: hostname), !token.isEmpty, !isSavingWorkspaceSettings else { return false }
        let host = hostname, organization = selectedOrganization
        isSavingWorkspaceSettings = true
        workspaceSettingsError = nil
        defer { isSavingWorkspaceSettings = false }
        do {
            let updated = try await client.updateWorkspace(hostname: host, organization: organization,
                                                           workspaceID: workspace.id, settings: settings, token: token)
            guard isConnected, hostname == host, selectedOrganization == organization,
                  let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return false }
            let old = workspaces[index]
            workspaces[index] = HCPWorkspace(id: old.id, name: updated.name, terraformVersion: updated.terraformVersion,
                                             executionMode: updated.executionMode, locked: updated.locked, htmlURL: old.htmlURL,
                                             tagNames: old.tagNames, vcs: old.vcs, projectID: old.projectID, projectName: old.projectName,
                                             currentRunStatus: old.currentRunStatus, currentRunCreatedAt: old.currentRunCreatedAt,
                                             updatedAt: Date(), resourceCount: old.resourceCount, description: updated.description,
                                             autoApply: updated.autoApply, workingDirectory: updated.workingDirectory)
            return true
        } catch {
            guard isConnected, hostname == host, selectedOrganization == organization else { return false }
            if case HCPViewerError.response(let status, _) = error, status == 403 || status == 401 {
                workspaceSettingsError = "Your credential cannot change this workspace’s settings."
            } else if case HCPViewerError.response(let status, _) = error, status == 422 {
                workspaceSettingsError = "HCP Terraform rejected one of these values. Check the Terraform version and working directory."
            } else {
                workspaceSettingsError = "Couldn’t save the workspace settings. Check access and try again."
            }
            return false
        }
    }

    @discardableResult
    func updateVariable(variableID: String, value: String) async -> Bool {
        guard !isSample, isConnected, let workspace = selectedWorkspace,
              workspaceVariables.contains(where: { $0.id == variableID }),
              let token = try? tokenStore.read(hostname: hostname), !token.isEmpty,
              savingVariableID == nil else { return false }
        let operation = variablesOperation
        let host = hostname, organization = selectedOrganization, workspaceID = workspace.id
        savingVariableID = variableID
        variablesError = nil
        defer { if variablesOperation == operation { savingVariableID = nil } }
        do {
            try await client.updateWorkspaceVariable(hostname: host, workspaceID: workspaceID,
                variableID: variableID, value: value, token: token)
            guard !Task.isCancelled, variablesOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspaceID,
                  workspaceVariables.contains(where: { $0.id == variableID }) else { return false }
            if let index = workspaceVariables.firstIndex(where: { $0.id == variableID }), !workspaceVariables[index].isSensitive {
                let old = workspaceVariables[index]
                workspaceVariables[index] = HCPWorkspaceVariable(id: old.id, key: old.key, value: value,
                    category: old.category, description: old.description, isSensitive: old.isSensitive, isHCL: old.isHCL)
            }
            return true
        } catch {
            guard variablesOperation == operation, isConnected, hostname == host,
                  selectedOrganization == organization, selectedWorkspaceID == workspaceID else { return false }
            variablesError = "Couldn’t save this variable. Check access and try again."
            return false
        }
    }

    func refreshMap() async {
        if isSample {
            mapSnapshot = nil
            mapError = nil
            if selectedWorkspaceID == "sample-unavailable" {
                mapError = "No state is available, or your credential cannot read this workspace’s state."
            } else if selectedWorkspaceID == "sample-empty" {
                mapSnapshot = HCPMapSnapshot(versionID: "sample-empty", map: ResourceMap(tiles: [], connections: [], dataSources: []), resources: [], notice: "Offline sample · empty workspace")
            } else if selectedWorkspaceID == "sample-reference" {
                let raw = try? JSONSerialization.data(withJSONObject: ResourceMapSample.referenceRawState)
                let shown = try? JSONSerialization.data(withJSONObject: ResourceMapSample.referenceShownState)
                if let raw { mapSnapshot = try? HCPMapSnapshot.decode(versionID: "sample-reference", raw: raw, shown: shown) }
            } else {
                let raw = try? JSONSerialization.data(withJSONObject: ResourceMapSample.rawState)
                let shown = try? JSONSerialization.data(withJSONObject: ResourceMapSample.shownState)
                if let raw { mapSnapshot = try? HCPMapSnapshot.decode(versionID: "sample-production", raw: raw, shown: shown) }
            }
            return
        }
        guard isConnected, let workspace = selectedWorkspace else { return }
        let operation = UUID()
        mapOperation = operation
        let host = hostname, organization = selectedOrganization
        mapSnapshot = nil
        mapError = nil
        isLoadingMap = false
        guard let token = try? tokenStore.read(hostname: host), !token.isEmpty else {
            mapError = "Your HCP credential is unavailable. Reconnect to load this workspace’s map."
            return
        }
        isLoadingMap = true
        defer { if mapOperation == operation { isLoadingMap = false } }
        do {
            let snapshot = try await client.currentMap(hostname: host, workspaceID: workspace.id, token: token)
            guard !Task.isCancelled, mapOperation == operation, isConnected,
                  hostname == host, selectedOrganization == organization, selectedWorkspaceID == workspace.id else { return }
            mapSnapshot = snapshot
        } catch {
            guard !Task.isCancelled, mapOperation == operation, isConnected else { return }
            if case HCPViewerError.response(status: 404, message: _) = error {
                // No current state version: the workspace has never applied. That is an
                // empty Map with a truthful notice, not a read error.
                mapSnapshot = HCPMapSnapshot.noStateRecorded
            } else if case HCPViewerError.response(status: 403, message: _) = error {
                mapError = "Your credential cannot read this workspace’s state."
            } else {
                // Error payloads can contain signed URLs or backend data; expose a bounded, fixed message.
                mapError = "Couldn’t load this workspace’s map. Check state access and refresh to try again."
            }
        }
    }
    @Published private(set) var linkedWorkspaceCandidates: [HCPWorkspace]?
    @Published private(set) var linkedWorkspaceNotice: String?
    func clearLinkedWorkspaceCandidates() {
        linkedWorkspaceCandidates = nil
        linkedWorkspaceNotice = nil
    }
    @Published var selectedWorkspaceID: String? {
        didSet {
            guard oldValue != selectedWorkspaceID else { return }
            if selectedWorkspaceID != nil { clearLinkedWorkspaceCandidates() }
            invalidateMap()
            currentOperation = UUID()
            isLoading = false
            runRefreshTime = .distantPast
            cancelPolling()
            runs = []; selectedRunDetails = nil; selectedRunID = nil
            runPage = 1; runHasNextPage = false
            persistSelection()
        }
    }
    @Published var selectedRunID: String? {
        didSet {
            guard oldValue != selectedRunID else { return }
            currentOperation = UUID()
            isLoading = false
            selectedRunDetails = nil
            persistSelection()
        }
    }
    @Published var selectedOrganization: String {
        didSet {
            guard oldValue != selectedOrganization else { return }
            if isSwitchingOrganization {
                invalidateMap()
                cancelPolling(); currentOperation = UUID()
                isLoading = false
                workspaces = []; runs = []; selectedRunDetails = nil
                workspacePage = 1; workspaceHasNextPage = false; runPage = 1; runHasNextPage = false
                identity.organization = selectedOrganization
                selectedWorkspaceID = nil
                persistSelection()
                return
            }
            disconnect()
            identity.organization = selectedOrganization
            selectedWorkspaceID = nil
            persistSelection()
        }
    }
    @Published var hostname: String {
        didSet {
            guard oldValue != hostname else { return }
            disconnect()
            identity.hostname = hostname
            hasStoredCredential = (try? tokenStore.read(hostname: HCPAPIClient.normalizedHostname(hostname) ?? "")) != nil
            persistSelection()
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingWorkspaces = false
    private var isSwitchingOrganization = false
    @Published private(set) var isImporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var hasStoredCredential = false
    @Published private(set) var workspacePage = 1
    @Published private(set) var runPage = 1
    @Published private(set) var workspaceHasNextPage = false
    @Published private(set) var runHasNextPage = false

    private let tokenStore: HCPTokenStore
    private let selectionStore: HCPSelectionStore
    private let client: HCPAPIClient
    private var runRefreshTime = Date.distantPast
    static let runRefreshInterval: TimeInterval = 8
    private var workspaceRefreshTime = Date.distantPast
    private var currentOperation = UUID()
    private var pollTask: Task<Void, Never>?
    private var pollingGeneration = UUID()
    private var isVisible = true

    init(tokenStore: HCPTokenStore = KeychainHCPTokenStore(),
         selectionStore: HCPSelectionStore = UserDefaultsHCPSelectionStore(),
         client: HCPAPIClient = HCPAPIClient(), isSample: Bool = false) {
        self.isSample = isSample
        self.tokenStore = tokenStore
        self.selectionStore = selectionStore
        self.client = client
        let saved = isSample ? nil : selectionStore.load()
        let base = isSample ? HCPConnectionIdentity(hostname: "app.terraform.io", organization: "Example") : (saved?.identity ?? .app)
        identity = base
        hostname = base.hostname
        selectedOrganization = base.organization
        selectedWorkspaceID = saved?.selectedWorkspaceID ?? base.workspaceID
        selectedRunID = saved?.selectedRunID ?? base.runID
        hasStoredCredential = !isSample && (try? tokenStore.read(hostname: base.hostname)) != nil
        if isSample {
            workspaces = [
                HCPWorkspace(id: "sample-production", name: "Acme production · sample", terraformVersion: "1.16.5", executionMode: "remote", locked: false, htmlURL: nil),
                HCPWorkspace(id: "sample-reference", name: "Map reference · sample", terraformVersion: "1.16.5", executionMode: "remote", locked: false, htmlURL: nil),
                HCPWorkspace(id: "sample-empty", name: "Empty workspace · sample", terraformVersion: "1.16.5", executionMode: "remote", locked: false, htmlURL: nil),
                HCPWorkspace(id: "sample-unavailable", name: "Unavailable state · sample", terraformVersion: "1.16.5", executionMode: "remote", locked: false, htmlURL: nil)
            ]
            selectedWorkspaceID = workspaces.first?.id
            isConnected = true
        }
    }

    var connectionSummary: String { "\(selectedOrganization) · \(hostname)" }
    var selectedWorkspace: HCPWorkspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    var selectedRun: HCPRun? { runs.first { $0.id == selectedRunID } }
    var isPolling: Bool { pollTask != nil }

    func importTerraformCredentialFile() async {
        guard !isSample else { return }
        guard HCPAPIClient.normalizedHostname(hostname) == "app.terraform.io" else {
            errorMessage = "The Terraform CLI credentials file is only imported for app.terraform.io."
            return
        }
        isImporting = true
        defer { isImporting = false }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".terraform.d", isDirectory: true)
            .appendingPathComponent("habitable.credentials.tfrc.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else { throw HCPViewerError.credentialTooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 65_536,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credentials = json["credentials"] as? [String: Any],
                  let hostCredentials = credentials["app.terraform.io"] as? [String: Any],
                  let token = hostCredentials["token"] as? String, !token.isEmpty,
                  token.utf8.count <= 8192 else { throw HCPViewerError.invalidCredentialFile }
            try tokenStore.write(token, hostname: "app.terraform.io")
            hasStoredCredential = true
            errorMessage = nil
        } catch let error as HCPViewerError { errorMessage = error.localizedDescription }
        catch { errorMessage = "Could not import the Terraform CLI credential file. Confirm it exists and is readable." }
    }

    func connect() async {
        guard !isSample else { return }
        guard let host = HCPAPIClient.normalizedHostname(hostname) else { errorMessage = HCPViewerError.invalidHost.localizedDescription; return }
        hostname = host
        invalidateMap()
        cancelPolling()
        runRefreshTime = .distantPast
        currentOperation = UUID()
        let operation = currentOperation
        guard let token = try? tokenStore.read(hostname: host), !token.isEmpty else {
            hasStoredCredential = false; isConnected = false; errorMessage = HCPViewerError.noCredential.localizedDescription; return
        }
        hasStoredCredential = true
        isLoading = true
        defer { if currentOperation == operation { isLoading = false } }
        do {
            let organization = selectedOrganization
            var workspaceResult = try await client.workspaces(hostname: host, organization: organization, token: token, page: 1)
            let orgPage = try? await client.organizations(hostname: host, token: token, page: 1)
            guard currentOperation == operation, hostname == host else { return }
            organizations = orgPage?.items ?? []
            var loadedWorkspaces = workspaceResult.items
            if let wantedID = selectedWorkspaceID, !loadedWorkspaces.contains(where: { $0.id == wantedID }) {
                // Restore at most five pages (250 workspaces) during connect; keep the saved ID if
                // it is farther back so loading more can resolve it without selecting another workspace.
                for page in 2...5 where workspaceResult.hasNextPage {
                    workspaceResult = try await client.workspaces(hostname: host, organization: organization, token: token, page: page)
                    guard currentOperation == operation, hostname == host, selectedOrganization == organization else { return }
                    loadedWorkspaces.append(contentsOf: workspaceResult.items)
                    if loadedWorkspaces.contains(where: { $0.id == wantedID }) || !workspaceResult.hasNextPage { break }
                }
            }
            workspaces = loadedWorkspaces
            workspacePage = workspaceResult.page; workspaceHasNextPage = workspaceResult.hasNextPage
            isConnected = true; errorMessage = nil; lastUpdated = Date()
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = workspaces.first?.id
            } else if selectedWorkspace == nil {
                errorMessage = "The saved workspace was not found in the first 250 workspaces. Load more to locate it."
            }
            explorerRows = [:]; explorerUnavailable = false
            Task { await refreshExplorer() }
            if selectedWorkspace != nil { await refreshRuns(force: true) }
        } catch {
            guard currentOperation == operation else { return }
            isConnected = false; errorMessage = error.localizedDescription
        }
    }

    private static func isValidSelector(_ selector: TerraformRemoteWorkspaceLink.Selector) -> Bool {
        switch selector {
        case .name(let name): return !name.isEmpty
        case .tags(let tags): return !tags.isEmpty && !tags.contains(where: \.isEmpty)
        case .prefix(let prefix): return !prefix.isEmpty
        }
    }

    /// Client-side verification of server search results. Never returns a
    /// workspace that does not satisfy the selector.
    private static func linkedCandidates(from loaded: [HCPWorkspace],
                                         selector: TerraformRemoteWorkspaceLink.Selector) -> [HCPWorkspace] {
        switch selector {
        case .name(let name): return loaded.filter { $0.name == name }
        case .prefix(let prefix): return loaded.filter { $0.name.hasPrefix(prefix) }
        case .tags(let tags):
            // If the API omitted tag-names for every item, trust the server-side filter.
            if loaded.allSatisfy({ $0.tagNames.isEmpty }) { return loaded }
            return loaded.filter { workspace in tags.allSatisfy { workspace.tagNames.contains($0) } }
        }
    }

    /// Opens only the exact workspace identified by initialized Terraform
    /// backend metadata. This deliberately avoids `connect()` because its normal
    /// first-workspace selection would be misleading when the named workspace
    /// is inaccessible or outside the bounded search window.
    func openLinkedWorkspace(_ link: TerraformRemoteWorkspaceLink) async {
        guard !isSample,
              let host = HCPAPIClient.normalizedHostname(link.hostname),
              host == link.hostname,
              !link.organization.isEmpty, Self.isValidSelector(link.selector) else {
            errorMessage = "This Terraform backend does not identify a valid HCP workspace."
            return
        }

        hostname = host
        selectedOrganization = link.organization
        clearLinkedWorkspaceCandidates()
        selectedWorkspaceID = nil
        workspaces = []
        runs = []
        cancelPolling()
        runRefreshTime = .distantPast
        workspacePage = 1
        workspaceHasNextPage = false
        isConnected = false
        errorMessage = nil
        let operation = UUID()
        currentOperation = operation
        guard let token = try? tokenStore.read(hostname: host), !token.isEmpty else {
            hasStoredCredential = false
            errorMessage = "No saved HCP credential is available for this Terraform backend."
            return
        }
        hasStoredCredential = true
        isLoading = true
        defer { if currentOperation == operation { isLoading = false } }

        let organization = link.organization
        var search: [URLQueryItem] = []
        switch link.selector {
        case .name: break
        case .tags(let tags): search = [URLQueryItem(name: "search[tags]", value: tags.joined(separator: ","))]
        case .prefix(let prefix): search = [URLQueryItem(name: "search[name]", value: prefix)]
        }
        do {
            var result = try await client.workspaces(hostname: host, organization: organization,
                                                     token: token, page: 1, search: search)
            guard !Task.isCancelled, currentOperation == operation,
                  hostname == host, selectedOrganization == organization else { return }
            var loaded = result.items
            let exactName = link.workspaceName
            var match = exactName.flatMap { name in loaded.first { $0.name == name } }
            while (exactName == nil || match == nil), result.hasNextPage, result.page < 5 {
                result = try await client.workspaces(hostname: host, organization: organization,
                                                     token: token, page: result.page + 1, search: search)
                guard !Task.isCancelled, currentOperation == operation,
                      hostname == host, selectedOrganization == organization else { return }
                loaded.append(contentsOf: result.items)
                if let exactName { match = result.items.first { $0.name == exactName } }
            }
            let organizationPage = try? await client.organizations(hostname: host, token: token, page: 1)
            guard !Task.isCancelled, currentOperation == operation,
                  hostname == host, selectedOrganization == organization else { return }
            organizations = organizationPage?.items ?? []
            workspaces = loaded
            workspacePage = result.page
            workspaceHasNextPage = result.hasNextPage
            isConnected = true
            lastUpdated = Date()
            if exactName == nil {
                let candidates = Self.linkedCandidates(from: loaded, selector: link.selector)
                switch candidates.count {
                case 0:
                    errorMessage = "No accessible workspace matches \(link.selectorDescription) in \(organization)."
                case 1:
                    isLoading = false
                    selectedWorkspaceID = candidates[0].id
                    await refreshRuns(force: true)
                default:
                    linkedWorkspaceCandidates = candidates
                    linkedWorkspaceNotice = "\(candidates.count) workspaces match \(link.selectorDescription). Choose the one this folder uses."
                }
                return
            }
            guard let exactMatch = match else {
                errorMessage = "The configured HCP workspace wasn’t found in the first 250 accessible workspaces."
                return
            }
            // Clear loading before selecting: selectedWorkspaceID changes the
            // operation token by design and starts the normal run refresh.
            isLoading = false
            selectedWorkspaceID = exactMatch.id
            await refreshRuns(force: true)
        } catch {
            guard currentOperation == operation, hostname == host,
                  selectedOrganization == organization else { return }
            isConnected = false
            errorMessage = "Couldn’t open the configured HCP workspace. Check access and try again."
        }
    }

    func refreshWorkspaces(nextPage: Bool = false) async {
        guard !isSample else { return }
        guard isConnected, let token = try? tokenStore.read(hostname: hostname) else { return }
        let page = nextPage ? workspacePage + 1 : 1
        guard Date().timeIntervalSince(workspaceRefreshTime) >= 2 else { return }
        workspaceRefreshTime = Date()
        let host = hostname
        let organization = selectedOrganization
        let operation = currentOperation
        do {
            var result = try await client.workspaces(hostname: host, organization: organization, token: token, page: page)
            guard currentOperation == operation, hostname == host, selectedOrganization == organization, isConnected else { return }
            var pageItems = result.items
            if !nextPage, let wantedID = selectedWorkspaceID, !pageItems.contains(where: { $0.id == wantedID }) {
                for page in 2...5 where result.hasNextPage {
                    result = try await client.workspaces(hostname: host, organization: organization, token: token, page: page)
                    guard currentOperation == operation, hostname == host, selectedOrganization == organization, isConnected else { return }
                    pageItems.append(contentsOf: result.items)
                    if pageItems.contains(where: { $0.id == wantedID }) || !result.hasNextPage { break }
                }
            }
            let hadSelectedWorkspace = selectedWorkspace != nil
            workspaces = nextPage ? workspaces + pageItems : pageItems
            workspacePage = result.page; workspaceHasNextPage = result.hasNextPage; lastUpdated = Date(); errorMessage = nil
            if selectedWorkspaceID != nil, selectedWorkspace == nil {
                invalidateMap()
                errorMessage = "The saved workspace was not found in the first 250 workspaces. Load more to locate it."
            }
            if !hadSelectedWorkspace, selectedWorkspace != nil { await refreshRuns(force: true) }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshRuns(nextPage: Bool = false, force: Bool = false) async {
        guard !isSample else { return }
        guard isConnected, let workspace = selectedWorkspace,
              let token = try? tokenStore.read(hostname: hostname) else { return }
        // One run-list fetch per 8 s. A person pressing Refresh twice sees the
        // cooldown; the app's own refreshes (after an apply, from a poll) wait it
        // out instead of surfacing it as an error.
        let remaining = Self.runRefreshInterval - Date().timeIntervalSince(runRefreshTime)
        if remaining > 0 {
            guard force else { errorMessage = HCPViewerError.rateLimited.localizedDescription; return }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard isConnected, selectedWorkspaceID == workspace.id else { return }
            // Another refresh may have run meanwhile; it already has the latest list.
            if Date().timeIntervalSince(runRefreshTime) < Self.runRefreshInterval { return }
        }
        runRefreshTime = Date()
        let op = UUID(); currentOperation = op
        isLoading = true
        defer { if currentOperation == op { isLoading = false } }
        let page = nextPage ? runPage + 1 : 1
        do {
            let organization = selectedOrganization
            let result = try await client.runs(hostname: hostname, organization: organization, workspace: workspace, token: token, page: page)
            guard currentOperation == op, selectedWorkspaceID == workspace.id,
                  selectedOrganization == organization, hostname == identity.hostname else { return }
            runs = nextPage ? runs + result.items : result.items
            runPage = result.page; runHasNextPage = result.hasNextPage; lastUpdated = Date(); errorMessage = nil
            if self.selectedRunID == nil { self.selectedRunID = runs.first?.id }
            isLoading = false
            if let selected = selectedRun, selectedRunDetails?.run != selected {
                await load(run: selected)
            } else if selectedRun == nil, let runID = selectedRunID, let workspace = selectedWorkspace {
                let remembered = HCPRun(id: runID, workspaceID: workspace.id, workspaceName: workspace.name,
                                        status: "loading", message: nil, operation: nil, createdAt: nil,
                                        hasChanges: nil, isDestroy: false, planID: nil, applyID: nil, htmlURL: nil)
                await load(run: remembered)
            }
            if runs.contains(where: \.isActive) { startPollingIfNeeded() } else { cancelPolling() }
        } catch {
            guard currentOperation == op else { return }
            errorMessage = error.localizedDescription
        }
    }

    func load(run: HCPRun) async {
        guard isConnected, let token = try? tokenStore.read(hostname: hostname) else { return }
        let op = UUID(); currentOperation = op
        let host = hostname
        let organization = selectedOrganization
        do {
            let details = try await client.runDetails(hostname: host, organization: organization, run: run, token: token)
            guard currentOperation == op, hostname == host, selectedOrganization == organization,
                  selectedWorkspaceID == run.workspaceID, selectedRunID == run.id else { return }
            selectedRunDetails = details
            if var current = selectionStore.load() {
                current.identity.hostname = hostname; current.identity.organization = selectedOrganization
                current.identity.workspaceID = run.workspaceID; current.identity.runID = run.id
                current.selectedWorkspaceID = run.workspaceID; current.selectedRunID = run.id
                selectionStore.save(current)
            }
        } catch {
            guard currentOperation == op else { return }
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        invalidateMap()
        cancelPolling(); currentOperation = UUID()
        isLoading = false
        isConnected = false; organizations = []; workspaces = []; runs = []; selectedRunDetails = nil
    }

    func loadNextWorkspacePage() async { await refreshWorkspaces(nextPage: true) }
    func loadNextRunPage() async { await refreshRuns(nextPage: true, force: true) }
    func clearError() { errorMessage = nil }
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            if isConnected && runs.contains(where: \.isActive) { startPollingIfNeeded() }
        } else {
            cancelPolling()
            invalidateMap()
            currentOperation = UUID()
            isLoading = false
        }
    }

    private func persistSelection() {
        guard !isSample else { return }
        guard !hostname.isEmpty else { return }
        identity.hostname = hostname; identity.organization = selectedOrganization
        identity.workspaceID = selectedWorkspaceID; identity.runID = selectedRunID
        selectionStore.save(HCPStoredSelection(identity: identity, selectedWorkspaceID: selectedWorkspaceID, selectedRunID: selectedRunID))
    }
    private func startPollingIfNeeded() {
        guard isVisible, pollTask == nil else { return }
        pollingGeneration = UUID()
        let generation = pollingGeneration
        pollTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.isConnected,
                      self.runs.contains(where: \.isActive) else { break }
                await self.refreshRuns(force: true)
            }
            if self?.pollingGeneration == generation { self?.pollTask = nil }
        }
    }
    private func cancelPolling() {
        pollingGeneration = UUID()
        pollTask?.cancel()
        pollTask = nil
    }

    /// Current state for a Library card: bounded, read-only, no selection change and
    /// no published state touched. Sample models have no real state, so this throws
    /// `HCPViewerError.noCredential` for them rather than inventing a snapshot.
    func librarySnapshot(for workspace: HCPWorkspace) async throws -> HCPMapSnapshot {
        guard !isSample else { throw HCPViewerError.noCredential }
        let host = hostname
        guard HCPAPIClient.normalizedHostname(host) != nil else { throw HCPViewerError.invalidHost }
        guard let token = try? tokenStore.read(hostname: host), !token.isEmpty else {
            throw HCPViewerError.noCredential
        }
        return try await client.currentMap(hostname: host, workspaceID: workspace.id, token: token)
    }

    /// Changes organization while staying connected: no disconnect, no organization
    /// refetch. Loads page 1 of the new organization's workspaces, bypassing the throttle.
    func switchOrganization(_ name: String) async {
        guard !isSample, isConnected, name != selectedOrganization else { return }
        isSwitchingOrganization = true
        selectedOrganization = name
        isSwitchingOrganization = false
        explorerRows = [:]; explorerUnavailable = false
        guard let token = try? tokenStore.read(hostname: hostname), !token.isEmpty else { return }
        workspaceRefreshTime = Date()
        let host = hostname, organization = selectedOrganization, operation = currentOperation
        isLoadingWorkspaces = true
        defer { if currentOperation == operation { isLoadingWorkspaces = false } }
        do {
            let result = try await client.workspaces(hostname: host, organization: organization, token: token, page: 1)
            guard currentOperation == operation, hostname == host, selectedOrganization == organization, isConnected else { return }
            workspaces = result.items
            workspacePage = result.page; workspaceHasNextPage = result.hasNextPage
            lastUpdated = Date(); errorMessage = nil
            Task { await refreshExplorer() }
        } catch {
            guard currentOperation == operation, selectedOrganization == organization else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Current state version id for a Library card, without downloading state.
    /// Same credential handling as `librarySnapshot(for:)`.
    func librarySnapshotVersionID(for workspace: HCPWorkspace) async throws -> String? {
        guard !isSample else { throw HCPViewerError.noCredential }
        let host = hostname
        guard HCPAPIClient.normalizedHostname(host) != nil else { throw HCPViewerError.invalidHost }
        guard let token = try? tokenStore.read(hostname: host), !token.isEmpty else {
            throw HCPViewerError.noCredential
        }
        return try await client.currentStateVersionID(hostname: host, workspaceID: workspace.id, token: token)
    }
}
