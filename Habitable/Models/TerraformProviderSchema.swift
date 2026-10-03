import Combine
import CryptoKit
import Darwin
import Foundation

struct TerraformSchemaAttribute: Identifiable, Equatable, Sendable {
    let path: String
    let type: String?
    let description: String?
    let required: Bool
    let optional: Bool
    let computed: Bool
    let sensitive: Bool

    var id: String { path }
}

struct TerraformProviderSchemaIndex: Sendable {
    private let providers: [String: Provider]

    func attributes(providerIdentity: String?, resourceType: String?, mode: String?) -> [TerraformSchemaAttribute]? {
        guard let providerIdentity, let resourceType,
              let provider = providers[providerIdentity] else { return nil }
        return mode == "data" ? provider.dataSources[resourceType] : provider.resources[resourceType]
    }

    fileprivate init(providers: [String: Provider]) { self.providers = providers }

    fileprivate struct Provider: Sendable {
        let resources: [String: [TerraformSchemaAttribute]]
        let dataSources: [String: [TerraformSchemaAttribute]]
    }
}

enum TerraformProviderSchemaLoader {
    enum SchemaError: LocalizedError {
        case notInitialized
        case contextTooLarge
        case timedOut
        case outputTooLarge
        case unavailable
        case unsupportedFormat
        case malformed
        case contextChanged
        case tooManyAttributes

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Initialize this workspace and install its providers before loading attribute help."
            case .contextTooLarge: return "The workspace configuration is too large to verify safely."
            case .timedOut: return "Loading installed provider schemas exceeded its time limit."
            case .outputTooLarge: return "Installed providers returned more schema data than Habitable can display safely."
            case .unavailable: return "Could not load schemas from providers already installed in this workspace."
            case .unsupportedFormat: return "Terraform returned an unsupported provider schema format."
            case .malformed: return "Terraform returned provider schema data that Habitable could not read."
            case .contextChanged: return "The workspace configuration changed while provider schemas were loading. Try again."
            case .tooManyAttributes: return "The provider schema contains too many attributes to display safely."
            }
        }
    }

    private static let maxOutputBytes = 24 * 1_024 * 1_024
    private static let maxConfigFiles = 512
    private static let maxConfigFileBytes = 4 * 1_024 * 1_024
    private static let maxContextBytes = 16 * 1_024 * 1_024
    private static let maxAttributes = 30_000

    static func load(executable: URL, directory: URL) throws -> (String, TerraformProviderSchemaIndex) {
        let key = try contextKey(executable: executable, directory: directory)
        let data = try run(executable: executable, directory: directory)
        guard try contextKey(executable: executable, directory: directory) == key else { throw SchemaError.contextChanged }
        return (key, try decode(data))
    }

    static func decode(_ data: Data) throws -> TerraformProviderSchemaIndex {
        guard data.count <= maxOutputBytes else { throw SchemaError.outputTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SchemaError.malformed }
        guard let format = root["format_version"] as? String,
              let major = Int(format.split(separator: ".").first ?? ""), major == 1 else { throw SchemaError.unsupportedFormat }
        guard let providerSchemas = root["provider_schemas"] as? [String: [String: Any]] else { throw SchemaError.malformed }

        var providers: [String: TerraformProviderSchemaIndex.Provider] = [:]
        var count = 0
        for (providerType, providerSchema) in providerSchemas {
            let resources = try resourceSchemas(providerSchema["resource_schemas"], in: &count)
            let dataSources = try resourceSchemas(providerSchema["data_source_schemas"], in: &count)
            providers[providerType] = .init(resources: resources, dataSources: dataSources)
        }
        return TerraformProviderSchemaIndex(providers: providers)
    }

    private static func resourceSchemas(_ value: Any?, in count: inout Int) throws -> [String: [TerraformSchemaAttribute]] {
        guard let schemas = value as? [String: [String: Any]] else { return [:] }
        var result: [String: [TerraformSchemaAttribute]] = [:]
        for (resourceType, schema) in schemas {
            guard let block = schema["block"] as? [String: Any] else { continue }
            var attributes: [TerraformSchemaAttribute] = []
            try collect(block, prefix: "", depth: 0, result: &attributes, total: &count)
            result[resourceType] = attributes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return result
    }

    private static func collect(_ block: [String: Any], prefix: String, depth: Int,
                                result: inout [TerraformSchemaAttribute], total: inout Int) throws {
        guard depth <= 16 else { return }
        if let attributes = block["attributes"] as? [String: [String: Any]] {
            for (name, value) in attributes {
                total += 1
                guard total <= maxAttributes else { throw SchemaError.tooManyAttributes }
                let path = prefix.isEmpty ? name : "\(prefix).\(name)"
                result.append(TerraformSchemaAttribute(
                    path: path,
                    type: typeName(value["type"]),
                    description: (value["description"] as? String).map { String($0.prefix(2_000)) },
                    required: value["required"] as? Bool ?? false,
                    optional: value["optional"] as? Bool ?? false,
                    computed: value["computed"] as? Bool ?? false,
                    sensitive: value["sensitive"] as? Bool ?? false
                ))
                if let nested = value["nested_type"] as? [String: Any] {
                    try collect(nested, prefix: path, depth: depth + 1, result: &result, total: &total)
                }
            }
        }
        if let blocks = block["block_types"] as? [String: [String: Any]] {
            for (name, value) in blocks {
                guard let nested = value["block"] as? [String: Any] else { continue }
                let path = prefix.isEmpty ? name : "\(prefix).\(name)"
                try collect(nested, prefix: path, depth: depth + 1, result: &result, total: &total)
            }
        }
    }

    private static func typeName(_ type: Any?) -> String? {
        guard let type else { return nil }
        if let value = type as? String { return value }
        guard let data = try? JSONSerialization.data(withJSONObject: type, options: [.fragmentsAllowed, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return String(value.prefix(256))
    }

    fileprivate static func contextKey(executable: URL, directory: URL) throws -> String {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var hasher = SHA256()
        func append(_ value: String) { hasher.update(data: Data(value.utf8)) }
        append("workspace=\(root.path)\ncli=\(executable.standardizedFileURL.path)\n")
        guard let cliAttributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let cliSize = cliAttributes[.size] as? NSNumber,
              let cliDate = cliAttributes[.modificationDate] as? Date else { throw SchemaError.unavailable }
        append("cli-size=\(cliSize);cli-date=\(cliDate.timeIntervalSince1970)\n")

        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var files = Set(children.filter { url in
            let name = url.lastPathComponent
            return url.pathExtension == "tf" || name.hasSuffix(".tf.json") || name == ".terraform.lock.hcl"
        })
        let lockFile = root.appendingPathComponent(".terraform.lock.hcl")
        let modulesManifest = root.appendingPathComponent(".terraform/modules/modules.json")
        files.insert(lockFile)
        files.insert(modulesManifest)
        let manifestValues = try? modulesManifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if manifestValues?.isRegularFile == true,
           let manifestSize = manifestValues?.fileSize, manifestSize <= maxConfigFileBytes,
           let data = try? Data(contentsOf: modulesManifest), data.count <= maxConfigFileBytes,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let modules = object["Modules"] as? [[String: Any]], modules.count <= 128 {
            for module in modules {
                guard let path = module["Dir"] as? String, !path.isEmpty else { continue }
                let moduleDirectory = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
                guard moduleDirectory.path == root.path || moduleDirectory.path.hasPrefix(root.path + "/") else { continue }
                guard let moduleFiles = try? FileManager.default.contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                files.formUnion(moduleFiles.filter { $0.pathExtension == "tf" || $0.lastPathComponent.hasSuffix(".tf.json") })
            }
        }
        guard files.count <= maxConfigFiles else { throw SchemaError.contextTooLarge }

        var total = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            append("file=\(file.path)\n")
            guard FileManager.default.fileExists(atPath: file.path) else { append("missing\n"); continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size <= maxConfigFileBytes, total + size <= maxContextBytes,
                  let data = try? Data(contentsOf: file) else { throw SchemaError.contextTooLarge }
            total += size
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(executable: URL, directory: URL) throws -> Data {
        let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable-schema-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["providers", "schema", "-json"]
        process.currentDirectoryURL = directory
        var environment: [String: String] = ["HOME": temporaryHome.path, "TMPDIR": temporaryHome.path, "CHECKPOINT_DISABLE": "1"]
        if let path = ProcessInfo.processInfo.environment["PATH"] { environment["PATH"] = path }
        if let locale = ProcessInfo.processInfo.environment["LANG"] { environment["LANG"] = locale }
        process.environment = environment

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = BoundedSchemaPipe(limit: maxOutputBytes)
        let stderr = BoundedSchemaPipe(limit: 256 * 1_024)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async { stdout.drain(stdoutPipe.fileHandleForReading); readers.leave() }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { stderr.drain(stderrPipe.fileHandleForReading); readers.leave() }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch {
            stdoutPipe.fileHandleForWriting.closeFile(); stderrPipe.fileHandleForWriting.closeFile()
            _ = readers.wait(timeout: .now() + 1)
            throw SchemaError.unavailable
        }
        guard exited.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = readers.wait(timeout: .now() + 1)
            throw SchemaError.timedOut
        }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 1)
        guard stdout.finished, stderr.finished else { throw SchemaError.unavailable }
        guard !stdout.exceededLimit && !stderr.exceededLimit else { throw SchemaError.outputTooLarge }
        guard process.terminationStatus == 0 else { throw SchemaError.unavailable }
        return stdout.data
    }

    private final class BoundedSchemaPipe: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var captured = Data()
        private var exceeded = false
        private var finishedReading = false
        init(limit: Int) { self.limit = limit }
        var data: Data { lock.lock(); defer { lock.unlock() }; return captured }
        var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return finishedReading }
        func drain(_ handle: FileHandle) {
            defer { try? handle.close(); lock.lock(); finishedReading = true; lock.unlock() }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    lock.lock()
                    let remaining = max(0, limit - captured.count)
                    if chunk.count > remaining { exceeded = true }
                    if remaining > 0 { captured.append(chunk.prefix(remaining)) }
                    lock.unlock()
                }
            } catch { lock.lock(); exceeded = true; lock.unlock() }
        }
    }
}

@MainActor
final class TerraformProviderSchemaHelpModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var attributes: [TerraformSchemaAttribute]?
    private var loadedProviderIdentity: String?
    private var loadedResourceType: String?
    private var loadedMode: String?

    private static var cache: [String: TerraformProviderSchemaIndex] = [:]
    private static var cacheOrder: [String] = []
    private var requestID = UUID()

    func reset() {
        requestID = UUID()
        isLoading = false
        message = nil
        attributes = nil
        loadedProviderIdentity = nil
        loadedResourceType = nil
        loadedMode = nil
    }

    func load(directory: URL?, executable: URL?, workspaceInitialized: Bool,
              providerIdentity: String?, resourceType: String?, mode: String?) {
        requestID = UUID()
        let request = requestID
        isLoading = false
        attributes = nil
        loadedProviderIdentity = providerIdentity
        loadedResourceType = resourceType
        loadedMode = mode
        guard let directory, let executable else { message = "Terraform CLI is unavailable."; return }
        guard workspaceInitialized else { message = TerraformProviderSchemaLoader.SchemaError.notInitialized.localizedDescription; return }
        isLoading = true
        message = "Loading schemas from installed providers…"

        Task { @MainActor [weak self] in
            do {
                let key = try await Task.detached(priority: .utility) {
                    try TerraformProviderSchemaLoader.contextKey(executable: executable, directory: directory)
                }.value
                let index: TerraformProviderSchemaIndex
                if let cached = Self.cache[key] {
                    index = cached
                } else {
                    let loaded = try await Task.detached(priority: .utility) {
                        try TerraformProviderSchemaLoader.load(executable: executable, directory: directory)
                    }.value
                    guard loaded.0 == key else { throw TerraformProviderSchemaLoader.SchemaError.contextChanged }
                    index = loaded.1
                }
                guard let self, self.requestID == request else { return }
                Self.cache[key] = index
                Self.cacheOrder.removeAll { $0 == key }
                Self.cacheOrder.append(key)
                while Self.cacheOrder.count > 4 {
                    let oldest = Self.cacheOrder.removeFirst()
                    Self.cache.removeValue(forKey: oldest)
                }
                self.attributes = index.attributes(providerIdentity: providerIdentity, resourceType: resourceType, mode: mode)
                self.message = self.attributes == nil ? "No installed schema is available for this resource." : nil
                self.isLoading = false
            } catch {
                guard let self, self.requestID == request else { return }
                self.isLoading = false
                self.message = error.localizedDescription
            }
        }
    }

    func attributes(for providerIdentity: String?, resourceType: String?, mode: String?) -> [TerraformSchemaAttribute]? {
        guard loadedProviderIdentity == providerIdentity,
              loadedResourceType == resourceType, loadedMode == mode else { return nil }
        return attributes
    }

    func message(for providerIdentity: String?, resourceType: String?, mode: String?) -> String? {
        guard loadedProviderIdentity == providerIdentity,
              loadedResourceType == resourceType, loadedMode == mode else { return nil }
        return message
    }

    func isLoading(for providerIdentity: String?, resourceType: String?, mode: String?) -> Bool {
        isLoading && loadedProviderIdentity == providerIdentity &&
            loadedResourceType == resourceType && loadedMode == mode
    }
}
