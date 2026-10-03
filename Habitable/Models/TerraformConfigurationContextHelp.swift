import Foundation
import Combine

struct TerraformProviderContextHelp: Identifiable, Sendable {
    let name: String
    let source: String
    let lockedVersion: String?
    let constraints: [String]
    let aliases: [String]
    let documentationURL: URL?
    var id: String { "\(name)|\(source)" }
}

struct TerraformModuleContextHelp: Identifiable, Sendable {
    let key: String
    let source: String
    let declaredVersion: String?
    let installedVersion: String?
    let documentationURL: URL?
    let metadata: TerraformConfigurationMetadata?
    var id: String { key }
}

struct TerraformWorkspaceContextHelp: Sendable {
    let providers: [TerraformProviderContextHelp]
    let modules: [TerraformModuleContextHelp]
    let inputs: [TerraformDeclaredInput]
    let outputs: [TerraformOutputMetadata]
    let requiredCore: [String]
    let diagnostics: [String]
    let omittedModuleCount: Int
}

enum TerraformConfigurationContextHelpLoader {
    private struct Manifest: Decodable {
        let Modules: [Module]?
    }
    private struct Module: Decodable {
        let Key: String
        let Source: String
        let Version: String?
        let Dir: String
    }

    private static let maximumManifestBytes = 1_048_576
    private static let maximumModules = 12
    private static let maximumModuleFiles = 256
    private static let maximumModuleBytes = 8 * 1_024 * 1_024

    static func load(directory: URL, helper: URL? = nil) -> TerraformWorkspaceContextHelp {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let rootMetadata = TerraformConfigurationInspector.inspectMetadata(directory: root, helper: helper)
        let providers = rootMetadata.providers.map { requirement -> TerraformProviderContextHelp in
            let source = canonicalProviderSource(requirement)
            let doc = TerraformProviderDocumentation.resolve(providerIdentity: source, resourceType: nil,
                                                              lockFile: root.appendingPathComponent(".terraform.lock.hcl"))
            return TerraformProviderContextHelp(name: requirement.name, source: source,
                lockedVersion: doc?.lockedVersion, constraints: requirement.versionConstraints,
                aliases: requirement.aliases.map { alias in
                    if let aliasName = alias.alias { return "\(alias.name) (\(aliasName))" }
                    return alias.name
                },
                documentationURL: doc?.providerURL)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let manifest = root.appendingPathComponent(".terraform/modules/modules.json")
        let records = readModules(manifest).sorted { $0.Key.localizedStandardCompare($1.Key) == .orderedAscending }
        var declaredModules = Dictionary(uniqueKeysWithValues: rootMetadata.modules.map { ($0.name, $0) })
        for record in records where declaredModules[record.Key] == nil {
            declaredModules[record.Key] = TerraformModuleCallMetadata(name: record.Key, source: record.Source,
                                                                       version: nil, sourceFile: "", sourceLine: nil)
        }
        let allKeys = Set(records.map(\.Key)).union(declaredModules.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let selectedKeys = Array(allKeys.prefix(maximumModules))
        let installed = Dictionary(uniqueKeysWithValues: records.map { ($0.Key, $0) })
        var moduleResults: [TerraformModuleContextHelp] = []
        let deadline = Date().addingTimeInterval(15)
        for key in selectedKeys {
            let declaration = declaredModules[key]
            let record = installed[key]
            let safeDirectory = record.flatMap { validatedModuleDirectory($0.Dir, root: root) }
            var moduleMetadata: TerraformConfigurationMetadata?
            if let safeDirectory, Date() < deadline, isBoundedConfigurationDirectory(safeDirectory) {
                moduleMetadata = TerraformConfigurationInspector.inspectMetadata(directory: safeDirectory, helper: helper)
            }
            let link = record == nil ? nil : TerraformModuleDocumentation.resolve(moduleKey: key, workspaceDirectory: root)
            moduleResults.append(TerraformModuleContextHelp(key: key, source: record?.Source ?? declaration?.source ?? "",
                declaredVersion: declaration?.version,
                installedVersion: record?.Version, documentationURL: link?.registryURL,
                metadata: moduleMetadata))
        }

        var diagnostics = rootMetadata.diagnostics
        if allKeys.count > maximumModules { diagnostics.append("Showing declaration help for the first \(maximumModules) of \(allKeys.count) declared and installed modules.") }
        if records.contains(where: { validatedModuleDirectory($0.Dir, root: root) == nil }) {
            diagnostics.append("Some module paths are outside this workspace and were not inspected.")
        }
        return TerraformWorkspaceContextHelp(providers: providers, modules: moduleResults,
            inputs: rootMetadata.inputs, outputs: rootMetadata.outputs, requiredCore: rootMetadata.requiredCore,
            diagnostics: diagnostics, omittedModuleCount: max(0, allKeys.count - maximumModules))
    }

    private static func canonicalProviderSource(_ provider: TerraformProviderRequirementMetadata) -> String {
        if let source = provider.source, !source.isEmpty {
            if source.split(separator: "/").count == 2 { return "registry.terraform.io/\(source)" }
            return source
        }
        return "registry.terraform.io/hashicorp/\(provider.name)"
    }

    private static func readModules(_ manifest: URL) -> [Module] {
        guard let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximumManifestBytes,
              let data = try? Data(contentsOf: manifest), data.count <= maximumManifestBytes,
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
              let modules = decoded.Modules, modules.count <= 128 else { return [] }
        return modules.filter { !$0.Key.isEmpty && !$0.Source.isEmpty && !$0.Dir.isEmpty }
    }

    private static func validatedModuleDirectory(_ path: String, root: URL) -> URL? {
        let candidate = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true else { return nil }
        return candidate
    }

    private static func isBoundedConfigurationDirectory(_ directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return false }
        let sourceFiles = entries.filter { $0.pathExtension == "tf" || $0.lastPathComponent.hasSuffix(".tf.json") }
        guard sourceFiles.count <= maximumModuleFiles else { return false }
        var bytes = 0
        for file in sourceFiles {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= maximumModuleBytes, bytes + size <= maximumModuleBytes else { return false }
            bytes += size
        }
        return true
    }
}

@MainActor
final class TerraformConfigurationContextHelpModel: ObservableObject {
    @Published private(set) var context: TerraformWorkspaceContextHelp?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private var requestID = UUID()

    func load(directory: URL?) {
        requestID = UUID()
        let request = requestID
        context = nil
        isLoading = false
        message = nil
        guard let directory else { message = "Open a workspace to load configuration help."; return }
        isLoading = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                TerraformConfigurationContextHelpLoader.load(directory: directory)
            }.value
            guard let self, self.requestID == request else { return }
            self.context = result
            self.isLoading = false
            self.message = result.providers.isEmpty && result.modules.isEmpty && result.inputs.isEmpty && result.outputs.isEmpty
                ? "No provider, module, input, or output declarations were found."
                : nil
        }
    }

    func reset() {
        requestID = UUID()
        context = nil
        isLoading = false
        message = nil
    }
}
