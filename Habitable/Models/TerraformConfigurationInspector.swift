import Foundation
import Darwin

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

struct TerraformOutputMetadata: Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let type: String?
    let sensitive: Bool
    let sourceFile: String
    let sourceLine: Int?
    var id: String { name }
}

struct TerraformConfigurationMetadata: Sendable {
    var inputs: [TerraformDeclaredInput] = []
    var outputs: [TerraformOutputMetadata] = []
    var providers: [TerraformProviderRequirementMetadata] = []
    var modules: [TerraformModuleCallMetadata] = []
    var requiredCore: [String] = []
    var diagnostics: [String] = []
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
        var requiredCore: [String]?
        var diagnostics: [Diagnostic]?
        enum CodingKeys: String, CodingKey {
            case variables, outputs, diagnostics
            case requiredProviders = "required_providers"
            case moduleCalls = "module_calls"
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
    static func inspectMetadata(directory: URL, helper overrideHelper: URL? = nil) -> TerraformConfigurationMetadata {
        var result = TerraformConfigurationMetadata()
        guard let helper = overrideHelper ?? helperURL else {
            result.diagnostics.append("Terraform configuration inspection helper is unavailable.")
            return result
        }
        do {
            let data = try run(helper, arguments: ["metadata", directory.path])
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
            result.requiredCore = metadata.requiredCore ?? []
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
