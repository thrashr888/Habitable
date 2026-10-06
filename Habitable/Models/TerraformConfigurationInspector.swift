import Foundation
import Darwin
import Combine

struct TerraformDeclaredInput: Identifiable, Equatable, Sendable {
    let name: String
    let type: String?
    let description: String?
    let hasDefault: Bool
    let defaultJSON: Data?
    let required: Bool
    let sensitive: Bool
    let ephemeral: Bool?
    let sourceFile: String
    let sourceLine: Int?

    var id: String { name }
    var sourceLocation: String {
        sourceLine.map { "\(sourceFile):\($0)" } ?? sourceFile
    }
}

struct TerraformInspectedInputs: Sendable {
    var declarations: [TerraformDeclaredInput] = []
    var values: [String: Data] = [:]
    var valueSources: [String: String] = [:]
    var unresolvedValues = Set<String>()
    var unresolvedValueSources: [String: String] = [:]
    var diagnostics: [String] = []
}

struct TerraformProviderAliasMetadata: Equatable, Sendable {
    let name: String
    let alias: String?
}

struct TerraformProviderRequirementMetadata: Identifiable, Equatable, Sendable {
    let name: String
    let source: String?
    let versionConstraints: [String]
    let aliases: [TerraformProviderAliasMetadata]
    var id: String { name }
}

struct TerraformModuleCallMetadata: Identifiable, Equatable, Sendable {
    let name: String
    let source: String
    let version: String?
    let sourceFile: String
    let sourceLine: Int?
    var id: String { name }
}

struct TerraformResourceDeclaration: Identifiable, Equatable, Sendable {
    let address: String
    let sourceFile: String
    let sourceLine: Int?
    var id: String { address }
    var sourceLocation: String { sourceLine.map { "\(sourceFile):\($0)" } ?? sourceFile }
}

struct ConfigurationDeclarationRequest: Identifiable, Equatable {
    let id = UUID()
    let file: String
    let line: Int
}

struct TerraformOutputMetadata: Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let type: String?
    let sensitive: Bool
    let sourceFile: String
    let sourceLine: Int?
    var id: String { name }
}

struct TerraformBackendDeclaration: Equatable, Sendable {
    var type: String
    var hostname: String?
    var organization: String?
    var workspaceName: String?
    var workspaceTags: [String]?
    var workspacePrefix: String?
    var unresolved: [String] = []
    var sourceFile: String
    var sourceLine: Int?
}

struct TerraformConfigurationMetadata: Sendable {
    var inputs: [TerraformDeclaredInput] = []
    var outputs: [TerraformOutputMetadata] = []
    var providers: [TerraformProviderRequirementMetadata] = []
    var modules: [TerraformModuleCallMetadata] = []
    var resources: [TerraformResourceDeclaration] = []
    var requiredCore: [String] = []
    var backend: TerraformBackendDeclaration?
    var diagnostics: [String] = []
}

/// An external Terraform workspace URL derived only from initialized backend
/// metadata, the CLI-selected workspace file, or the declared backend block.
/// No remote lookup or credential access is performed.
struct TerraformRemoteWorkspaceLink: Equatable, Sendable {
    enum Selector: Equatable, Sendable { case name(String), tags([String]), prefix(String) }
    enum Source: Equatable, Sendable {
        case initializedBackend
        case configuration(sourceFile: String)
        /// This folder was cloned by Habitable from that workspace's repository.
        case checkout(workspaceID: String)
    }

    let hostname: String
    let organization: String
    let selector: Selector
    let source: Source
    let url: URL

    init(hostname: String, organization: String, selector: Selector, source: Source, url: URL) {
        self.hostname = hostname
        self.organization = organization
        self.selector = selector
        self.source = source
        self.url = url
    }

    init(hostname: String, organization: String, workspaceName: String, url: URL) {
        self.init(hostname: hostname, organization: organization, selector: .name(workspaceName),
                  source: .initializedBackend, url: url)
    }

    var workspaceName: String? {
        if case .name(let name) = selector { return name }
        return nil
    }

    var isExact: Bool { workspaceName != nil }

    var selectorDescription: String {
        switch selector {
        case .name(let name): return "workspace \(name)"
        case .tags(let tags): return "workspaces tagged \(tags.joined(separator: ", "))"
        case .prefix(let prefix): return "workspaces prefixed \(prefix)"
        }
    }

    var isInitialized: Bool { source == .initializedBackend }

    private static let defaultHostname = "app.terraform.io"
    private static let maximumMetadataBytes = 1_048_576

    /// An initialized backend (`.terraform/terraform.tfstate`) wins and never falls
    /// back to configuration; otherwise the declared backend block is used.
    static func resolve(workingDirectory: URL, helper: URL? = nil) -> TerraformRemoteWorkspaceLink? {
        let metadataURL = workingDirectory.appendingPathComponent(".terraform/terraform.tfstate")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: metadataURL.path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= maximumMetadataBytes,
                  let data = try? Data(contentsOf: metadataURL) else { return nil }
            return resolve(backendMetadata: data,
                           selectedWorkspace: selectedWorkspaceName(workingDirectory: workingDirectory))
        }
        guard let declaration = TerraformConfigurationInspector
            .inspectMetadata(directory: workingDirectory, helper: helper).backend else { return nil }
        return resolve(configuration: declaration)
    }

    /// Terraform's CLI-selected workspace (`.terraform/environment`). Nothing else is read.
    static func selectedWorkspaceName(workingDirectory: URL) -> String? {
        let url = workingDirectory.appendingPathComponent(".terraform/environment")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4_096,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return cleanSegment(text)
    }

    /// Purely resolves an explicit `cloud` or `remote` backend configuration.
    static func resolve(backendMetadata data: Data, selectedWorkspace: String? = nil) -> TerraformRemoteWorkspaceLink? {
        guard data.count <= maximumMetadataBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backend = root["backend"] as? [String: Any],
              let type = backend["type"] as? String,
              ["cloud", "remote"].contains(type),
              let config = backend["config"] as? [String: Any],
              let hostname = Self.backendHostname(config),
              let rawOrganization = config["organization"] as? String,
              let organization = Self.cleanSegment(rawOrganization),
              let workspaces = config["workspaces"] as? [String: Any] else { return nil }

        func present(_ key: String) -> Any? {
            guard let value = workspaces[key], !(value is NSNull) else { return nil }
            return value
        }
        let name = present("name"), tags = present("tags"), prefix = present("prefix")
        let selector: Selector
        if let name {
            guard tags == nil, prefix == nil, let raw = name as? String,
                  let clean = cleanSegment(raw) else { return nil }
            selector = .name(clean)
        } else if let tags {
            guard prefix == nil, let list = tags as? [String], !list.isEmpty,
                  list.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            if let selectedWorkspace { selector = .name(selectedWorkspace) }
            else { selector = .tags(Array(Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()) }
        } else if let prefix {
            guard let value = prefix as? String, !value.isEmpty else { return nil }
            if let selectedWorkspace {
                guard let combined = cleanSegment(value + selectedWorkspace) else { return nil }
                selector = .name(combined)
            } else { selector = .prefix(value) }
        } else { return nil }
        return make(hostname: hostname, organization: organization, selector: selector, source: .initializedBackend)
    }

    /// Resolves a literal `cloud` or `remote` block found in configuration.
    static func resolve(configuration: TerraformBackendDeclaration) -> TerraformRemoteWorkspaceLink? {
        guard ["cloud", "remote"].contains(configuration.type),
              let rawOrganization = configuration.organization,
              let organization = cleanSegment(rawOrganization) else { return nil }
        let unresolved = Set(configuration.unresolved)
        guard unresolved.isDisjoint(with: ["organization", "hostname"]) else { return nil }
        let hostname: String
        if let raw = configuration.hostname {
            guard let normalized = HCPAPIClient.normalizedHostname(raw) else { return nil }
            hostname = normalized
        } else { hostname = defaultHostname }
        func isUnresolved(_ attribute: String) -> Bool {
            unresolved.contains(attribute) || unresolved.contains("workspaces.\(attribute)")
        }
        let selector: Selector
        if let raw = configuration.workspaceName {
            guard !isUnresolved("name"), let name = cleanSegment(raw) else { return nil }
            selector = .name(name)
        } else if let tags = configuration.workspaceTags, !tags.isEmpty {
            guard !isUnresolved("tags") else { return nil }
            selector = .tags(Array(Set(tags)).sorted())
        } else if let prefix = configuration.workspacePrefix, !prefix.isEmpty {
            guard !isUnresolved("prefix") else { return nil }
            selector = .prefix(prefix)
        } else { return nil }
        return make(hostname: hostname, organization: organization, selector: selector,
                    source: .configuration(sourceFile: configuration.sourceFile))
    }

    private static func make(hostname: String, organization: String, selector: Selector,
                             source: Source) -> TerraformRemoteWorkspaceLink? {
        var path = "/app/\(encodePathSegment(organization))/workspaces"
        if case .name(let name) = selector { path += "/\(encodePathSegment(name))" }
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostname
        components.percentEncodedPath = path
        guard let url = components.url else { return nil }
        return TerraformRemoteWorkspaceLink(hostname: hostname, organization: organization,
                                           selector: selector, source: source, url: url)
    }

    private static func backendHostname(_ config: [String: Any]) -> String? {
        guard let raw = config["hostname"] else { return defaultHostname }
        if raw is NSNull { return defaultHostname }
        guard let hostname = raw as? String else { return nil }
        return HCPAPIClient.normalizedHostname(hostname)
    }

    private static func cleanSegment(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"),
              !value.contains("?"), !value.contains("#") else { return nil }
        return value
    }

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.subtract(CharacterSet(charactersIn: "/?#%"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Finds known local folders linked to a remote workspace. Only exact `.name`
/// links are matched.
@MainActor
final class LocalWorkspaceLinkIndex: ObservableObject {
    struct Entry: Equatable, Sendable { let folder: URL; let link: TerraformRemoteWorkspaceLink }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRefreshing = false
    private static let maximumFolders = 10

    func refresh(folders: [URL], helper: URL? = nil) async {
        var seen = Set<String>()
        let candidates = folders.filter { seen.insert(RecentWorkspaceStore.canonicalPath($0)).inserted }
            .prefix(Self.maximumFolders).map { $0 }
        isRefreshing = true
        defer { isRefreshing = false }
        let task = Task.detached(priority: .utility) { () -> [Entry] in
            var result: [Entry] = []
            for folder in candidates {
                if Task.isCancelled { break }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let link = TerraformRemoteWorkspaceLink.resolve(workingDirectory: folder, helper: helper)
                else { continue }
                result.append(Entry(folder: folder, link: link))
            }
            return result
        }
        let resolved = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return }
        entries = resolved
    }

    func folders(hostname: String, organization: String, workspaceName: String) -> [URL] {
        guard let host = HCPAPIClient.normalizedHostname(hostname) else { return [] }
        return entries.compactMap { entry in
            guard entry.link.workspaceName == workspaceName, entry.link.organization == organization,
                  HCPAPIClient.normalizedHostname(entry.link.hostname) == host else { return nil }
            return entry.folder
        }
    }
}

enum TerraformConfigurationInspector {
    private static let maximumOutputBytes = 8 * 1_024 * 1_024
    private static let maximumRuntime: TimeInterval = 5

    private struct ModuleResponse: Decodable {
        var variables: [String: Variable]?
        var diagnostics: [Diagnostic]?
    }
    private struct Variable: Decodable {
        var name: String
        var type: String?
        var description: String?
        var `default`: JSONValue?
        var required: Bool?
        var sensitive: Bool?
        var hasDefault: Bool
        var pos: Position?
        var ephemeral: Bool?
        enum CodingKeys: String, CodingKey { case name, type, description, `default`, required, sensitive, pos, ephemeral; case hasDefault = "has_default" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            `default` = try c.decodeIfPresent(JSONValue.self, forKey: .default)
            required = try c.decodeIfPresent(Bool.self, forKey: .required)
            sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive)
            hasDefault = try c.decodeIfPresent(Bool.self, forKey: .hasDefault) ?? false
            pos = try c.decodeIfPresent(Position.self, forKey: .pos)
            ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral)
        }
    }
    private struct Position: Decodable { var filename: String; var line: Int? }
    private struct Diagnostic: Decodable { var severity: String?; var summary: String; var detail: String? }
    private struct ValuesResponse: Decodable { var values: [String: JSONValue]; var unresolved: [String]?; var diagnostics: [String]? }
    private struct MetadataResponse: Decodable {
        var variables: [String: MetadataVariable]?
        var outputs: [String: MetadataOutput]?
        var requiredProviders: [String: MetadataProvider]?
        var moduleCalls: [String: MetadataModuleCall]?
        var resources: [String: MetadataResource]?
        var requiredCore: [String]?
        var backend: MetadataBackend?
        var diagnostics: [Diagnostic]?
        enum CodingKeys: String, CodingKey {
            case variables, outputs, diagnostics, backend
            case requiredProviders = "required_providers"
            case moduleCalls = "module_calls", resources
            case requiredCore = "required_core"
        }
    }
    private struct MetadataVariable: Decodable {
        var name: String; var type: String?; var description: String?; var required: Bool
        var hasDefault: Bool; var sensitive: Bool?; var ephemeral: Bool?; var pos: Position?
        enum CodingKeys: String, CodingKey { case name, type, description, required, sensitive, ephemeral, pos; case hasDefault = "has_default" }
    }
    private struct MetadataOutput: Decodable {
        var name: String; var description: String?; var sensitive: Bool?; var type: String?; var pos: Position?
    }
    private struct MetadataProvider: Decodable {
        var name: String; var source: String?; var versionConstraints: [String]?; var aliases: [MetadataAlias]?
        enum CodingKeys: String, CodingKey { case name, source, aliases; case versionConstraints = "version_constraints" }
    }
    private struct MetadataAlias: Decodable { var name: String; var alias: String? }
    private struct MetadataModuleCall: Decodable { var name: String; var source: String; var version: String?; var pos: Position? }
    private struct MetadataResource: Decodable { var address: String; var pos: Position? }
    private struct MetadataBackend: Decodable {
        struct Workspaces: Decodable { var name: String?; var tags: [String]?; var prefix: String?; var project: String? }
        var type: String; var hostname: String?; var organization: String?
        var workspaces: Workspaces?; var unresolved: [String]?; var pos: Position?
    }

    /// Resolves declarations represented by config-inspect metadata for the current module.
    static func declaration(for address: String, in metadata: TerraformConfigurationMetadata) -> TerraformResourceDeclaration? {
        guard let declarationKey = rootDeclarationKey(for: address) else { return nil }
        return metadata.resources.first { $0.address == declarationKey && $0.sourceLine != nil }
    }

    /// Resolves addresses through config-inspect metadata at each module boundary. The
    /// helper sees configuration only; no variable values or environment are read.
    static func declarations(for addresses: [String], directory: URL,
                             helper: URL? = nil) -> [String: TerraformResourceDeclaration] {
        let maximumAddressLength = 16_384
        let maximumModuleDepth = 7
        let maximumInspectedDirectories = 12
        let resolutionDeadline = ProcessInfo.processInfo.systemUptime + 20
        let isCanceledOrExpired: @Sendable () -> Bool = {
            Task.isCancelled || ProcessInfo.processInfo.systemUptime >= resolutionDeadline
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var metadataByDirectory: [String: TerraformConfigurationMetadata] = [:]
        func metadata(at directory: URL) -> TerraformConfigurationMetadata {
            let key = directory.path
            if let cached = metadataByDirectory[key] { return cached }
            guard metadataByDirectory.count < maximumInspectedDirectories, !isCanceledOrExpired() else { return TerraformConfigurationMetadata() }
            let value = inspectMetadata(directory: directory, helper: helper, shouldCancel: isCanceledOrExpired)
            metadataByDirectory[key] = value
            return value
        }

        var resolved: [String: TerraformResourceDeclaration] = [:]
        for address in Set(addresses) {
            guard !isCanceledOrExpired() else { break }
            guard address.utf8.count <= maximumAddressLength else { continue }
            guard let segments = addressSegments(address) else { continue }
            var currentDirectory = root
            var moduleIndex = 0
            var pathIsSafe = true
            var moduleDepth = 0
            while moduleIndex < segments.count, segments[moduleIndex].name == "module" {
                guard moduleIndex + 1 < segments.count else { pathIsSafe = false; break }
                moduleDepth += 1
                guard moduleDepth <= maximumModuleDepth else { pathIsSafe = false; break }
                let call = segments[moduleIndex + 1]
                let currentMetadata = metadata(at: currentDirectory)
                guard let source = currentMetadata.modules.first(where: { $0.name == call.name })?.source,
                      let child = localModuleDirectory(source: source, relativeTo: currentDirectory, workspace: root) else {
                    pathIsSafe = false
                    break
                }
                currentDirectory = child
                moduleIndex += 2
            }
            guard pathIsSafe, moduleIndex < segments.count else { continue }
            let resourceAddress = segments[moduleIndex...].map(\.raw).joined(separator: ".")
            guard let key = rootDeclarationKey(for: resourceAddress),
                  let declaration = metadata(at: currentDirectory).resources.first(where: { $0.address == key }),
                  let line = declaration.sourceLine,
                  let relativeFile = safeRelativeSourceFile(declaration.sourceFile, moduleDirectory: currentDirectory, workspace: root) else { continue }
            resolved[address] = TerraformResourceDeclaration(address: declaration.address,
                sourceFile: relativeFile, sourceLine: line)
        }
        return resolved
    }

    private struct AddressSegment { let raw: String; let name: String }

    /// Splits Terraform addresses only at dots outside quoted instance keys. This
    /// preserves dotted and Unicode keys while avoiding assumptions about key text.
    private static func addressSegments(_ address: String) -> [AddressSegment]? {
        var rawSegments: [String] = [], current = ""
        var depth = 0, quoted = false, escaped = false
        for character in address {
            if quoted {
                current.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true; current.append(character) }
            else if character == "[" { depth += 1; current.append(character) }
            else if character == "]" { depth -= 1; guard depth >= 0 else { return nil }; current.append(character) }
            else if character == "." && depth == 0 { rawSegments.append(current); current = "" }
            else { current.append(character) }
        }
        guard depth == 0, !quoted else { return nil }
        rawSegments.append(current)
        guard rawSegments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return rawSegments.map { raw in AddressSegment(raw: raw, name: String(raw.prefix { $0 != "[" })) }
    }

    private static func localModuleDirectory(source: String, relativeTo parent: URL, workspace: URL) -> URL? {
        guard source.hasPrefix("./") || source.hasPrefix("../"),
              !source.contains("\\"), !source.contains(":") else { return nil }
        let parts = source.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) else { return nil }
        let candidate = parent.appendingPathComponent(source).standardizedFileURL
        let canonical = candidate.resolvingSymlinksInPath()
        guard isInside(canonical, root: workspace), canonical != workspace,
              !containsSymlink(from: workspace, to: candidate),
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return canonical
    }

    private static func safeRelativeSourceFile(_ filename: String, moduleDirectory: URL, workspace: URL) -> String? {
        let candidate = filename.hasPrefix("/")
            ? URL(fileURLWithPath: filename)
            : moduleDirectory.appendingPathComponent(filename)
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(canonical, root: workspace), !containsSymlink(from: workspace, to: candidate),
              (canonical.pathExtension == "tf" || canonical.lastPathComponent.hasSuffix(".tf.json")),
              FileManager.default.fileExists(atPath: canonical.path),
              !canonical.lastPathComponent.hasPrefix("."),
              let relative = relativePath(canonical, from: workspace),
              relative.split(separator: "/").count <= 8,
              !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "vendor" }),
              let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576 else { return nil }
        return relative
    }

    private static func isInside(_ path: URL, root: URL) -> Bool {
        path.path == root.path || path.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func relativePath(_ path: URL, from root: URL) -> String? {
        guard isInside(path, root: root), path.path != root.path else { return nil }
        return String(path.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
    }

    private static func containsSymlink(from root: URL, to target: URL) -> Bool {
        guard isInside(target.standardizedFileURL, root: root) else { return true }
        let relative = relativePath(target.standardizedFileURL, from: root) ?? ""
        var cursor = root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return true }
        }
        return false
    }

    private static func rootDeclarationKey(for address: String) -> String? {
        var components: [String] = []
        var component = ""
        var bracketDepth = 0
        var quoted = false
        var escaped = false
        for character in address {
            if quoted {
                component.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
                component.append(character)
            } else if character == "[" {
                bracketDepth += 1
                component.append(character)
            } else if character == "]" {
                bracketDepth -= 1
                guard bracketDepth >= 0 else { return nil }
                component.append(character)
            } else if character == "." && bracketDepth == 0 {
                components.append(component)
                component = ""
            } else {
                component.append(character)
            }
        }
        guard bracketDepth == 0, !quoted else { return nil }
        components.append(component)
        guard components.count >= 2 else { return nil }
        let typeIndex = components.first == "data" ? 1 : 0
        guard components.count > typeIndex + 1 else { return nil }
        let rawName = String(components[typeIndex + 1])
        let name = String(rawName.prefix { $0 != "[" })
        guard !name.isEmpty else { return nil }
        let key = typeIndex == 1 ? "data.\(components[typeIndex]).\(name)" : "\(components[typeIndex]).\(name)"
        // Reject traversal or malformed suffixes; only instance keys after the resource name are allowed.
        guard components.count == typeIndex + 2,
              rawName == name || rawName.hasPrefix(name + "[") else { return nil }
        return key
    }

    /// JSON values are retained as their original JSON representation so null and
    /// empty strings remain distinct from an absent value.
    private struct JSONValue: Decodable, Sendable {
        let data: Data
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { data = Data("null".utf8); return }
            if let value = try? container.decode(Bool.self) { data = try JSONEncoder().encode(value); return }
            if let value = try? container.decode(Int64.self) { data = try JSONEncoder().encode(value); return }
            if let value = try? container.decode(Double.self) { data = try JSONEncoder().encode(value); return }
            if let value = try? container.decode(String.self) { data = try JSONEncoder().encode(value); return }
            if let value = try? container.decode([JSONValue].self) { data = try JSONSerialization.data(withJSONObject: value.map(\.foundation), options: [.fragmentsAllowed]); return }
            if let value = try? container.decode([String: JSONValue].self) { data = try JSONSerialization.data(withJSONObject: value.mapValues(\.foundation), options: [.fragmentsAllowed]); return }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
        var foundation: Any {
            (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
        }
    }

    static func inspect(directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                        helper overrideHelper: URL? = nil, appEnvironmentKeys: Set<String> = [],
                        shouldCancel: @Sendable () -> Bool = { false }) -> TerraformInspectedInputs {
        var result = TerraformInspectedInputs()
        guard let helper = overrideHelper ?? helperURL else {
            result.diagnostics.append("Terraform input inspection helper is unavailable; declared inputs could not be read.")
            return result
        }
        do {
            guard !shouldCancel() else { return result }
            let output = try run(helper, arguments: ["inspect", directory.path], shouldCancel: shouldCancel)
            let module = try JSONDecoder().decode(ModuleResponse.self, from: output)
            result.declarations = (module.variables ?? [:]).values.map { variable in
                let position = variable.pos
                let file = position?.filename ?? "(unknown source)"
                let path = URL(fileURLWithPath: file).lastPathComponent
                return TerraformDeclaredInput(name: variable.name, type: variable.type,
                    description: variable.description, hasDefault: variable.hasDefault || !(variable.required ?? true),
                    defaultJSON: variable.hasDefault ? (variable.default?.data ?? Data("null".utf8)) : nil, required: variable.required ?? true,
                    sensitive: variable.sensitive ?? false, ephemeral: variable.ephemeral,
                    sourceFile: path, sourceLine: position?.line)
            }.sorted { $0.name < $1.name }
            for diagnostic in module.diagnostics ?? [] {
                result.diagnostics.append(diagnostic.summary)
            }
        } catch { result.diagnostics.append("Could not inspect Terraform declarations: \(error.localizedDescription)") }

        var files: [(URL, String)] = []
        let root = directory
        let conventional = ["terraform.tfvars", "terraform.tfvars.json"]
        for name in conventional {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { files.append((url, name)) }
        }
        let autoFiles = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".auto.tfvars") || $0.lastPathComponent.hasSuffix(".auto.tfvars.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        files += autoFiles.map { ($0, $0.lastPathComponent) }
        for (file, source) in files {
            guard !shouldCancel() else { return result }
            do {
                let output = try run(helper, arguments: ["tfvars", file.path], shouldCancel: shouldCancel)
                let decoded = try JSONDecoder().decode(ValuesResponse.self, from: output)
                for key in decoded.unresolved ?? [] {
                    result.values.removeValue(forKey: key); result.valueSources.removeValue(forKey: key)
                    result.unresolvedValues.insert(key); result.unresolvedValueSources[key] = source
                }
                for (key, value) in decoded.values {
                    result.values[key] = value.data; result.valueSources[key] = source
                    result.unresolvedValues.remove(key); result.unresolvedValueSources.removeValue(forKey: key)
                }
                result.diagnostics += decoded.diagnostics ?? []
            } catch {
                if shouldCancel() { return result }
                for declaration in result.declarations {
                    result.values.removeValue(forKey: declaration.name); result.valueSources.removeValue(forKey: declaration.name)
                    result.unresolvedValues.insert(declaration.name); result.unresolvedValueSources[declaration.name] = source
                }
                result.diagnostics.append("Could not read \(source): \(error.localizedDescription)")
            }
        }
        // TF_VAR values are lower precedence than every tfvars source.
        for (key, value) in environment where key.hasPrefix("TF_VAR_") {
            guard !shouldCancel() else { return result }
            let name = String(key.dropFirst("TF_VAR_".count))
            if result.values[name] == nil && !result.unresolvedValues.contains(name) {
                do {
                    let output = try run(helper, arguments: ["tfvar", name], standardInput: value, shouldCancel: shouldCancel)
                    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: output)
                    result.values[name] = decoded[name]?.data
                    result.valueSources[name] = appEnvironmentKeys.contains(key) ? "Habitable environment override" : "TF_VAR_ environment"
                } catch {
                    if shouldCancel() { return result }
                    result.diagnostics.append("Could not resolve TF_VAR_\(name): \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// Reads declaration-only module context. Call from a detached task; the same
    /// bounded helper runner is used, and this operation never reads tfvars or env values.
    static func inspectMetadata(directory: URL, helper overrideHelper: URL? = nil,
                                shouldCancel: @Sendable () -> Bool = { false }) -> TerraformConfigurationMetadata {
        var result = TerraformConfigurationMetadata()
        guard let helper = overrideHelper ?? helperURL else {
            result.diagnostics.append("Terraform configuration inspection helper is unavailable.")
            return result
        }
        do {
            let data = try run(helper, arguments: ["metadata", directory.path], shouldCancel: shouldCancel)
            let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data)
            result.inputs = (metadata.variables ?? [:]).values.map { item in
                let path = item.pos?.filename ?? "(unknown source)"
                return TerraformDeclaredInput(name: item.name, type: item.type, description: item.description,
                    hasDefault: item.hasDefault, defaultJSON: nil, required: item.required,
                    sensitive: item.sensitive ?? false, ephemeral: item.ephemeral,
                    sourceFile: URL(fileURLWithPath: path).lastPathComponent, sourceLine: item.pos?.line)
            }.sorted { $0.name < $1.name }
            result.outputs = (metadata.outputs ?? [:]).values.map { item in
                let path = item.pos?.filename ?? "(unknown source)"
                return TerraformOutputMetadata(name: item.name, description: item.description,
                    type: item.type, sensitive: item.sensitive ?? false,
                    sourceFile: URL(fileURLWithPath: path).lastPathComponent, sourceLine: item.pos?.line)
            }.sorted { $0.name < $1.name }
            result.providers = (metadata.requiredProviders ?? [:]).values.map { item in
                TerraformProviderRequirementMetadata(name: item.name, source: item.source,
                    versionConstraints: item.versionConstraints ?? [],
                    aliases: (item.aliases ?? []).map { TerraformProviderAliasMetadata(name: $0.name, alias: $0.alias) })
            }.sorted { $0.name < $1.name }
            result.modules = (metadata.moduleCalls ?? [:]).values.map { item in
                let path = item.pos?.filename ?? "(unknown source)"
                return TerraformModuleCallMetadata(name: item.name, source: item.source, version: item.version,
                    sourceFile: URL(fileURLWithPath: path).lastPathComponent, sourceLine: item.pos?.line)
            }.sorted { $0.name < $1.name }
            result.resources = (metadata.resources ?? [:]).values.map { item in
                let path = item.pos?.filename ?? "(unknown source)"
                return TerraformResourceDeclaration(address: item.address,
                    sourceFile: URL(fileURLWithPath: path).lastPathComponent, sourceLine: item.pos?.line)
            }.sorted { $0.address < $1.address }
            result.requiredCore = metadata.requiredCore ?? []
            result.backend = metadata.backend.map { item in
                TerraformBackendDeclaration(type: item.type, hostname: item.hostname,
                    organization: item.organization, workspaceName: item.workspaces?.name,
                    workspaceTags: item.workspaces?.tags, workspacePrefix: item.workspaces?.prefix,
                    unresolved: item.unresolved ?? [],
                    sourceFile: URL(fileURLWithPath: item.pos?.filename ?? "(unknown source)").lastPathComponent,
                    sourceLine: item.pos?.line)
            }
            result.diagnostics = (metadata.diagnostics ?? []).map(\.summary)
        } catch {
            result.diagnostics.append("Could not inspect Terraform module metadata: \(error.localizedDescription)")
        }
        return result
    }

    private static var helperURL: URL? {
#if DEBUG
        // Development and package tests can inject the exact pinned helper binary.
        if let path = ProcessInfo.processInfo.environment["HABITABLE_CONFIG_INSPECT_PATH"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
#endif
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/habitable-config-inspect")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    private static func run(_ executable: URL, arguments: [String], standardInput input: String? = nil,
                            shouldCancel: @Sendable () -> Bool = { false }) throws -> Data {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let output = Pipe(); let errorPipe = Pipe(); process.standardOutput = output; process.standardError = errorPipe
        let inputPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        let stdout = BoundedPipeCapture(limit: maximumOutputBytes)
        let stderr = BoundedPipeCapture(limit: 256 * 1_024)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.drain(output.fileHandleForReading)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.drain(errorPipe.fileHandleForReading)
            readers.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            _ = readers.wait(timeout: .now() + 1)
            throw error
        }
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            inputPipe.fileHandleForWriting.closeFile()
        }
        let deadline = Date().addingTimeInterval(maximumRuntime)
        while true {
            if exited.wait(timeout: .now() + 0.05) == .success { break }
            if shouldCancel() || Date() >= deadline {
                process.terminate()
                if exited.wait(timeout: .now() + 0.5) == .timedOut {
                    _ = kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
                _ = readers.wait(timeout: .now() + 1)
                let message = shouldCancel() ? "Terraform configuration inspection was canceled." : "Terraform configuration inspection exceeded its time limit."
                throw NSError(domain: "TerraformConfigurationInspector", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 1)
        guard !stdout.exceededLimit && !stderr.exceededLimit else {
            throw NSError(domain: "TerraformConfigurationInspector", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Terraform configuration inspection returned too much data."])
        }
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TerraformConfigurationInspector", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Terraform configuration inspection could not read the selected workspace files."])
        }
        guard stdout.finished, stderr.finished else {
            throw NSError(domain: "TerraformConfigurationInspector", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Terraform configuration inspection did not finish cleanly."])
        }
        return stdout.data
    }

    private final class BoundedPipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var captured = Data()
        private var didExceedLimit = false
        private var didFinish = false

        init(limit: Int) { self.limit = limit }
        var data: Data { lock.lock(); defer { lock.unlock() }; return captured }
        var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return didExceedLimit }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }

        func drain(_ handle: FileHandle) {
            defer {
                try? handle.close()
                lock.lock(); didFinish = true; lock.unlock()
            }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    lock.lock()
                    let remaining = max(0, limit - captured.count)
                    if chunk.count > remaining { didExceedLimit = true }
                    if remaining > 0 { captured.append(chunk.prefix(remaining)) }
                    lock.unlock()
                }
            } catch {
                lock.lock(); didExceedLimit = true; lock.unlock()
            }
        }
    }
}
