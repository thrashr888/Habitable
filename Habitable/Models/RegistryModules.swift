import Combine
import Foundation

/// A module as the public Terraform Registry lists it. Read-only, no credentials.
struct RegistryModuleSummary: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let namespace: String
    let name: String
    let provider: String
    let version: String
    let description: String
    let source: String
    let downloads: Int
    let verified: Bool

    /// "terraform-aws-modules/vpc/aws" without the version.
    var path: String { "\(namespace)/\(name)/\(provider)" }
    var registryURL: URL { URL(string: "https://registry.terraform.io/modules/\(path)/\(version)")! }
    /// Only https links to the stated source; anything else is not a link.
    var sourceURL: URL? { RegistryModules.httpsURL(source) }
}

/// The root module's interface, from the module detail endpoint.
struct RegistryModuleDetail: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        let name: String
        let type: String
        let description: String
        let defaultValue: String?
        let required: Bool
    }
    struct Output: Equatable, Sendable {
        let name: String
        let description: String
    }
    struct Resource: Equatable, Sendable {
        let name: String
        let type: String
    }

    let summary: RegistryModuleSummary
    let inputs: [Input]
    let outputs: [Output]
    let resources: [Resource]

    var requiredInputs: [Input] { inputs.filter(\.required) }
}

enum RegistryModules {
    static let maxResponseBytes = 4 * 1_024 * 1_024

    static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// `GET /v1/modules/search?q=…` or, with no query, `/v1/modules` (verified first).
    static func searchURL(query: String, provider: String?, limit: Int = 50) -> URL {
        var components = URLComponents(string: "https://registry.terraform.io/v1/modules")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items.append(URLQueryItem(name: "verified", value: "true"))
        } else {
            components.path = "/v1/modules/search"
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        if let provider, !provider.isEmpty { items.append(URLQueryItem(name: "provider", value: provider)) }
        components.queryItems = items
        return components.url!
    }

    static func detailURL(path: String) -> URL {
        URL(string: "https://registry.terraform.io/v1/modules/\(path)")!
    }

    private struct SearchResponse: Decodable { let modules: [RegistryModuleSummary] }

    static func parseSearch(_ data: Data) throws -> [RegistryModuleSummary] {
        try JSONDecoder().decode(SearchResponse.self, from: data).modules
            .sorted { $0.downloads > $1.downloads }
    }

    private struct DetailResponse: Decodable {
        struct Root: Decodable {
            struct Input: Decodable {
                let name: String
                let type: String?
                let description: String?
                let `default`: String?
                let required: Bool?
            }
            struct Output: Decodable { let name: String; let description: String? }
            struct Resource: Decodable { let name: String; let type: String }
            let inputs: [Input]?
            let outputs: [Output]?
            let resources: [Resource]?
        }
        let id: String
        let namespace: String
        let name: String
        let provider: String
        let version: String
        let description: String?
        let source: String?
        let downloads: Int?
        let verified: Bool?
        let root: Root?
    }

    static func parseDetail(_ data: Data) throws -> RegistryModuleDetail {
        let response = try JSONDecoder().decode(DetailResponse.self, from: data)
        let summary = RegistryModuleSummary(
            id: response.id, namespace: response.namespace, name: response.name, provider: response.provider,
            version: response.version, description: response.description ?? "", source: response.source ?? "",
            downloads: response.downloads ?? 0, verified: response.verified ?? false)
        let root = response.root
        let inputs = (root?.inputs ?? []).map { input in
            RegistryModuleDetail.Input(
                name: input.name, type: input.type ?? "string", description: input.description ?? "",
                defaultValue: input.default, required: input.required ?? (input.default == nil))
        }
        return RegistryModuleDetail(
            summary: summary,
            inputs: inputs.sorted { ($0.required ? 0 : 1, $0.name) < ($1.required ? 0 : 1, $1.name) },
            outputs: (root?.outputs ?? []).map { .init(name: $0.name, description: $0.description ?? "") },
            resources: (root?.resources ?? []).map { .init(name: $0.name, type: $0.type) })
    }

    // MARK: Turning a module into a template

    /// A folder that calls the module: `main.tf` with one module block, `variables.tf`
    /// for the inputs the module requires, and a README that links back to the
    /// Registry page and the module's source.
    static func template(for detail: RegistryModuleDetail) -> InfrastructureTemplate {
        let summary = detail.summary
        let required = detail.requiredInputs
        let inputs = required.map { input in
            InfrastructureTemplate.Input(
                name: input.name,
                prompt: input.description.isEmpty ? input.type : "\(input.description) (\(input.type))",
                example: exampleValue(for: input.type),
                required: true)
        }
        let resources = detail.resources.map { resource in
            InfrastructureTemplate.PlannedResource(name: "module.\(summary.name).\(resource.name)", type: resource.type, note: nil)
        }
        var files: [String: String] = [
            "main.tf": mainFile(summary: summary, required: required),
            "README.md": readme(detail: detail),
        ]
        if !required.isEmpty { files["variables.tf"] = variablesFile(required) }
        var links = [InfrastructureTemplate.Link(title: "View in Registry", url: summary.registryURL)]
        if let source = summary.sourceURL { links.append(.init(title: "Source", url: source)) }
        return InfrastructureTemplate(
            id: "registry:\(summary.path)",
            title: "\(summary.namespace)/\(summary.name)",
            summary: summary.description.isEmpty ? "A module from the Terraform Registry." : summary.description,
            category: .registry,
            provider: summary.provider,
            resources: resources,
            estimatedMonthlyCost: "cost depends on the inputs",
            inputs: inputs,
            files: files,
            links: links)
    }

    /// A value the variables file can hold for a required input left blank:
    /// an empty string, list or map by type, so `terraform validate` still passes
    /// and Inputs can ask for the real value.
    static func exampleValue(for type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("list") || trimmed.hasPrefix("set") { return "[]" }
        if trimmed.hasPrefix("map") || trimmed.hasPrefix("object") { return "{}" }
        if trimmed == "number" { return "0" }
        if trimmed == "bool" { return "false" }
        return ""
    }

    static func mainFile(summary: RegistryModuleSummary, required: [RegistryModuleDetail.Input]) -> String {
        var lines = [
            "# \(summary.namespace)/\(summary.name) from the Terraform Registry",
            "# \(summary.registryURL.absoluteString)",
            "",
            "module \"\(summary.name)\" {",
            "  source  = \"\(summary.path)\"",
            "  version = \"\(summary.version)\"",
        ]
        if !required.isEmpty {
            lines.append("")
            let width = required.map(\.name.count).max() ?? 0
            for input in required {
                let pad = String(repeating: " ", count: width - input.name.count)
                lines.append("  \(input.name)\(pad) = var.\(input.name)")
            }
        }
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func variablesFile(_ inputs: [RegistryModuleDetail.Input]) -> String {
        inputs.map { input in
            let isString = exampleValue(for: input.type).isEmpty
            let value = isString ? "\"${\(input.name)}\"" : "${\(input.name)}"
            var block = ["variable \"\(input.name)\" {"]
            if !input.description.isEmpty {
                block.append("  description = \"\(input.description.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " "))\"")
            }
            block.append("  type        = \(input.type)")
            block.append("  default     = \(value)")
            block.append("}")
            return block.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    static func readme(detail: RegistryModuleDetail) -> String {
        let summary = detail.summary
        var lines = [
            "# \(summary.namespace)/\(summary.name)",
            "",
            summary.description.isEmpty ? "A module from the Terraform Registry." : summary.description,
            "",
            "- Registry: \(summary.registryURL.absoluteString)",
        ]
        if let source = summary.sourceURL { lines.append("- Source: \(source.absoluteString)") }
        lines.append("- Version: \(summary.version), pinned in main.tf")
        lines.append("")
        lines.append("This folder calls the module once. The module's code is downloaded on the first")
        lines.append("Preview Changes and is not copied here; change inputs in variables.tf or in Inputs.")
        if !detail.requiredInputs.isEmpty {
            lines.append("")
            lines.append("## Needs from you")
            lines.append("")
            for input in detail.requiredInputs {
                lines.append("- `\(input.name)` (\(input.type))" + (input.description.isEmpty ? "" : ": \(input.description)"))
            }
        }
        if !detail.outputs.isEmpty {
            lines.append("")
            lines.append("## Outputs")
            lines.append("")
            for output in detail.outputs.prefix(40) {
                lines.append("- `\(output.name)`" + (output.description.isEmpty ? "" : ": \(output.description)"))
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

/// Searches the public Registry and loads one module's interface.
@MainActor
final class RegistryModulesModel: ObservableObject {
    @Published private(set) var results: [RegistryModuleSummary] = []
    @Published private(set) var detail: RegistryModuleDetail?
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var message: String?

    private let session: URLSession
    private var searchID = UUID()
    private var detailID = UUID()

    init(session: URLSession = .shared) { self.session = session }

    func search(query: String, provider: String?) async {
        let id = UUID()
        searchID = id
        isSearching = true
        message = nil
        defer { if searchID == id { isSearching = false } }
        do {
            let data = try await fetch(RegistryModules.searchURL(query: query, provider: provider))
            guard searchID == id else { return }
            results = try RegistryModules.parseSearch(data)
            if results.isEmpty { message = "No modules match. Try a different word or provider." }
        } catch {
            guard searchID == id else { return }
            results = []
            message = "The Registry could not be reached. Check your connection and try again."
        }
    }

    func load(_ summary: RegistryModuleSummary) async {
        let id = UUID()
        detailID = id
        detail = nil
        isLoadingDetail = true
        defer { if detailID == id { isLoadingDetail = false } }
        do {
            let data = try await fetch(RegistryModules.detailURL(path: summary.path))
            guard detailID == id else { return }
            detail = try RegistryModules.parseDetail(data)
        } catch {
            guard detailID == id else { return }
            message = "The module's details could not be loaded."
        }
    }

    func clearDetail() {
        detailID = UUID()
        detail = nil
        isLoadingDetail = false
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= RegistryModules.maxResponseBytes else { throw URLError(.badServerResponse) }
        return data
    }
}
