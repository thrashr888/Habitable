import Combine
import Foundation

/// One provider documentation page from the public Terraform Registry.
struct TerraformRegistryDocument: Equatable, Sendable {
    let providerIdentity: String
    let version: String
    let title: String
    let url: URL
    let markdown: String
}

/// Reads resource and data source documentation from the public Registry v2 API.
/// Read-only, no credentials. The markdown is data and is never interpreted.
@MainActor
final class TerraformRegistryDocsModel: ObservableObject {
    @Published private(set) var document: TerraformRegistryDocument?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    static let maxResponseBytes = 2 * 1_024 * 1_024
    static let maxMarkdownBytes = 512 * 1_024
    static let maxCacheEntries = 24
    private static var cache: [String: TerraformRegistryDocument] = [:]
    private static var cacheOrder: [String] = []

    private let session: URLSession
    private var requestID = UUID()

    init(session: URLSession = .shared) { self.session = session }

    func reset() {
        requestID = UUID()
        document = nil
        isLoading = false
        message = nil
    }

    static func clearCache() { cache = [:]; cacheOrder = [] }

    func load(providerIdentity: String?, resourceType: String?, mode: String?, preferredVersion: String?) async {
        requestID = UUID()
        let request = requestID
        document = nil
        message = nil
        guard let providerIdentity, let resourceType,
              let parts = Self.registryParts(providerIdentity),
              let slug = Self.slug(resourceType: resourceType, providerName: parts.name) else {
            message = Self.unavailable(resourceType)
            return
        }
        let category = mode == "data" ? "data-sources" : "resources"
        let key = [providerIdentity, preferredVersion ?? "", category, resourceType].joined(separator: "|")
        if let cached = Self.cache[key] { document = cached; return }
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            let loaded = try await fetch(parts: parts, identity: providerIdentity, category: category,
                                         slug: slug, resourceType: resourceType, preferredVersion: preferredVersion)
            guard requestID == request else { return }
            Self.cache[key] = loaded
            Self.cacheOrder.removeAll { $0 == key }
            Self.cacheOrder.append(key)
            while Self.cacheOrder.count > Self.maxCacheEntries {
                Self.cache.removeValue(forKey: Self.cacheOrder.removeFirst())
            }
            document = loaded
        } catch let error as FetchError {
            guard requestID == request else { return }
            message = error == .unreachable ? "Couldn't reach the Terraform Registry." : Self.unavailable(resourceType)
        } catch {
            guard requestID == request else { return }
            message = "Couldn't reach the Terraform Registry."
        }
    }

    // MARK: Fetching

    private enum FetchError: Error { case unreachable, notFound }

    private func fetch(parts: (namespace: String, name: String), identity: String, category: String,
                       slug: String, resourceType: String, preferredVersion: String?) async throws -> TerraformRegistryDocument {
        let base = "https://registry.terraform.io/v2"
        let providerJSON = try await json("\(base)/providers/\(parts.namespace)/\(parts.name)",
                                          query: [("include", "provider-versions")])
        let versions = (providerJSON["included"] as? [[String: Any]] ?? []).compactMap { item -> (id: String, version: String)? in
            guard item["type"] as? String == "provider-versions", let id = item["id"] as? String,
                  let version = (item["attributes"] as? [String: Any])?["version"] as? String else { return nil }
            return (id, version)
        }
        guard let chosen = Self.chooseVersion(versions, preferred: preferredVersion) else { throw FetchError.notFound }

        let listJSON = try await json("\(base)/provider-docs", query: [
            ("filter[provider-version]", chosen.id), ("filter[category]", category),
            ("filter[slug]", slug), ("filter[language]", "hcl")])
        guard let docID = (listJSON["data"] as? [[String: Any]])?.first?["id"] as? String,
              docID.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else { throw FetchError.notFound }

        let docJSON = try await json("\(base)/provider-docs/\(docID)", query: [])
        guard let attributes = (docJSON["data"] as? [String: Any])?["attributes"] as? [String: Any],
              let content = attributes["content"] as? String else { throw FetchError.notFound }
        let markdown = Self.bounded(Self.stripFrontMatter(content))
        guard let url = URL(string: "https://registry.terraform.io/providers/\(parts.namespace)/\(parts.name)/\(chosen.version)/docs/\(category)/\(slug)") else {
            throw FetchError.notFound
        }
        return TerraformRegistryDocument(providerIdentity: identity, version: chosen.version,
                                         title: resourceType, url: url, markdown: markdown)
    }

    private func json(_ string: String, query: [(String, String)]) async throws -> [String: Any] {
        guard var components = URLComponents(string: string) else { throw FetchError.unreachable }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw FetchError.unreachable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FetchError.unreachable }
            guard (200..<300).contains(http.statusCode) else {
                throw http.statusCode == 404 ? FetchError.notFound : FetchError.unreachable
            }
            guard body.count <= Self.maxResponseBytes else { throw FetchError.notFound }
            data = body
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.unreachable
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.notFound }
        return object
    }

    // MARK: Pure helpers

    private static func unavailable(_ type: String?) -> String {
        "Registry documentation isn't available for \(type ?? "this resource")."
    }

    static func registryParts(_ identity: String) -> (namespace: String, name: String)? {
        let parts = identity.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "registry.terraform.io",
              parts.dropFirst().allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil })
        else { return nil }
        return (parts[1], parts[2])
    }

    /// Resource type with the provider's `name_` prefix removed (`aws_db_instance` -> `db_instance`).
    static func slug(resourceType: String, providerName: String) -> String? {
        guard resourceType.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        let prefix = providerName + "_"
        let slug = resourceType.hasPrefix(prefix) ? String(resourceType.dropFirst(prefix.count)) : resourceType
        return slug.isEmpty ? nil : slug
    }

    static func chooseVersion(_ versions: [(id: String, version: String)], preferred: String?) -> (id: String, version: String)? {
        if let preferred, let match = versions.first(where: { $0.version == preferred }) { return match }
        return versions.max { compare($0.version, $1.version) }
    }

    /// True when `lhs` sorts before `rhs`; a prerelease sorts before its release.
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        func parse(_ value: String) -> (core: [Int], pre: String?) {
            let noBuild = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
            let halves = noBuild.split(separator: "-", maxSplits: 1).map(String.init)
            let core = halves[0].split(separator: ".").map { Int($0) ?? 0 }
            return (core, halves.count > 1 ? halves[1] : nil)
        }
        let a = parse(lhs), b = parse(rhs)
        for index in 0..<max(a.core.count, b.core.count) {
            let x = index < a.core.count ? a.core[index] : 0
            let y = index < b.core.count ? b.core[index] : 0
            if x != y { return x < y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
        }
    }

    private static func bounded(_ text: String) -> String {
        guard text.utf8.count > maxMarkdownBytes else { return text }
        var data = Data(text.utf8.prefix(maxMarkdownBytes))
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes a leading `---` block.
    static func stripFrontMatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return markdown }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits on `## ` headings outside fenced code. Text before the first heading is "Overview".
    static func sections(from markdown: String) -> [(title: String, body: String)] {
        var result: [(title: String, body: String)] = []
        var title = "Overview"
        var body: [String] = []
        var inFence = false
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || title != "Overview" { result.append((title, text)) }
            body = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()
        return result
    }
}
