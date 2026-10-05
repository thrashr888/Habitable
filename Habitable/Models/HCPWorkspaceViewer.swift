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

    init(id: String, name: String, terraformVersion: String?, executionMode: String?,
         locked: Bool, htmlURL: URL?, tagNames: [String] = []) {
        self.id = id; self.name = name; self.terraformVersion = terraformVersion
        self.executionMode = executionMode; self.locked = locked; self.htmlURL = htmlURL
        self.tagNames = tagNames
    }
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
        let object = try await get(path: path, hostname: hostname, token: token, query: pagination(page) + search)
        let items = array(object["data"]).compactMap { decodeWorkspace($0, hostname: hostname, organization: organization) }
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func runs(hostname: String, organization: String, workspace: HCPWorkspace, token: String, page: Int) async throws -> HCPPage<HCPRun> {
        let path = "/api/v2/workspaces/\(pathComponent(workspace.id))/runs"
        // The API omits plan_only runs unless an operation filter is supplied.
        let query = pagination(page) + [URLQueryItem(name: "filter[operation]", value: "plan_only,plan_and_apply,save_plan,refresh_only,destroy,empty_apply,action_only")]
        let object = try await get(path: path, hostname: hostname, token: token, query: query)
        let items = array(object["data"]).compactMap {
            decodeRun($0, hostname: hostname, organization: organization, workspaceID: workspace.id, workspaceName: workspace.name)
        }
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
    }

    func workspaceVariables(hostname: String, workspaceID: String, token: String, page: Int) async throws -> HCPPage<HCPWorkspaceVariable> {
        let path = "/api/v2/workspaces/\(pathComponent(workspaceID))/vars"
        let object = try await get(path: path, hostname: hostname, token: token, query: pagination(page))
        let items = array(object["data"]).compactMap(decodeWorkspaceVariable)
        return HCPPage(items: items, page: page, hasNextPage: nextPage(object) != nil, totalCount: paginationCount(object))
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
        guard let row = object["data"] as? [String: Any], let id = row["id"] as? String,
              row["type"] as? String == "state-versions",
              let attributes = row["attributes"] as? [String: Any],
              let rawURLString = attributes["hosted-state-download-url"] as? String,
              let rawURL = secureArtifactURL(rawURLString) else { throw HCPViewerError.invalidResponse }
        if let relationships = row["relationships"] as? [String: Any],
           let related = relationshipID(relationships["workspace"]), related != workspaceID {
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

    private func decodeWorkspace(_ row: [String: Any], hostname: String, organization: String) -> HCPWorkspace? {
        guard let id = row["id"] as? String, let attributes = row["attributes"] as? [String: Any],
              let name = attributes["name"] as? String else { return nil }
        let url = URL(string: "https://\(hostname)/app/\(pathComponent(organization))/workspaces/\(pathComponent(name))")
        return HCPWorkspace(id: id, name: name, terraformVersion: attributes["terraform-version"] as? String,
                            executionMode: attributes["execution-mode"] as? String,
                            locked: attributes["locked"] as? Bool ?? false, htmlURL: url,
                            tagNames: attributes["tag-names"] as? [String] ?? [])
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
        return HCPRun(id: id, workspaceID: workspaceID, workspaceName: workspaceName, status: status,
                      message: attributes["message"] as? String, operation: attributes["operation"] as? String,
                      createdAt: date, hasChanges: attributes["has-changes"] as? Bool,
                      isDestroy: attributes["is-destroy"] as? Bool ?? false,
                      planID: planID, applyID: applyID, htmlURL: url)
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
    @Published private(set) var workspaceVariables: [HCPWorkspaceVariable] = []
    @Published private(set) var isLoadingVariables = false
    @Published private(set) var variablesError: String?
    @Published private(set) var savingVariableID: String?
    private var variablesOperation = UUID()

    var mapRequestKey: String {
        "\(isConnected)|\(hostname)|\(selectedOrganization)|\(selectedWorkspaceID ?? "")"
    }

    private func invalidateMap() {
        mapOperation = UUID()
        mapSnapshot = nil
        mapError = nil
        isLoadingMap = false
        invalidateVariables()
    }

    private func invalidateVariables() {
        variablesOperation = UUID()
        workspaceVariables = []
        variablesError = nil
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
                mapError = "No state is available, or your credential cannot read this workspace’s state."
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
        _ = force
        guard Date().timeIntervalSince(runRefreshTime) >= 3 else { errorMessage = HCPViewerError.rateLimited.localizedDescription; return }
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
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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
}
