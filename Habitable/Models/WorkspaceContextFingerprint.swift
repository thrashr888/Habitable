import CryptoKit
import Foundation

struct WorkspaceContextCaptureContext: Sendable {
    let directory: URL
    let terraformWorkspace: String
    let backendIdentity: String
    let terraformVersion: String
    let terraformExecutable: URL?
    let inputsFingerprint: String
}

/// A content snapshot of the inputs that can affect a local Terraform plan.
/// Captures are run off the main actor; files are read in fixed-size chunks.
enum WorkspaceContextFingerprint {
    enum CaptureError: LocalizedError {
        case tooManyFiles
        case unreadable(URL)

        var errorDescription: String? {
            switch self {
            case .tooManyFiles: return "The Terraform workspace contains too many configuration files to verify safely."
            case .unreadable(let url): return "Habitable could not verify the Terraform input at \(url.lastPathComponent)."
            }
        }
    }

    private static let maximumModuleDirectories = 512
    private static let maximumFiles = 4096
    private static let terraformConfigurationExtensions: Set<String> = ["tf"]

    static func capture(directory: URL, terraformWorkspace: String, backendIdentity: String,
                        terraformVersion: String, terraformExecutable: URL?, inputsFingerprint: String) throws -> String {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var urls = Set<URL>()

        func addDirectInputs(in folder: URL) throws {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw CaptureError.unreadable(folder)
            }
            for child in children {
                let name = child.lastPathComponent
                let ext = child.pathExtension
                let isTerraformConfig = terraformConfigurationExtensions.contains(ext) || name.hasSuffix(".tf.json")
                let isVariableFile = name == "terraform.tfvars" || name == "terraform.tfvars.json"
                    || name.hasSuffix(".auto.tfvars") || name.hasSuffix(".auto.tfvars.json")
                let isBackendConfig = name.hasSuffix(".tfbackend")
                guard isTerraformConfig || isVariableFile || isBackendConfig else { continue }
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isRegularFileKey])
                } catch {
                    throw CaptureError.unreadable(child)
                }
                guard values.isRegularFile == true else { throw CaptureError.unreadable(child) }
                urls.insert(child.resolvingSymlinksInPath())
                guard urls.count <= maximumFiles else { throw CaptureError.tooManyFiles }
            }
        }

        try addDirectInputs(in: root)

        // Terraform records the installed module source directories here. Read only
        // each module's root configuration files, never provider packages or caches.
        let modulesManifest = root.appendingPathComponent(".terraform/modules/modules.json")
        if FileManager.default.fileExists(atPath: modulesManifest.path) {
            let manifestSize = (try? modulesManifest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard manifestSize <= 1024 * 1024,
                  let data = try? Data(contentsOf: modulesManifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modules = object["Modules"] as? [[String: Any]] else {
                throw CaptureError.unreadable(modulesManifest)
            }
            urls.insert(modulesManifest)
            guard modules.count <= maximumModuleDirectories else { throw CaptureError.tooManyFiles }
            for module in modules {
                guard let directory = module["Dir"] as? String, !directory.isEmpty else {
                    throw CaptureError.unreadable(modulesManifest)
                }
                let moduleDirectory = URL(fileURLWithPath: directory, relativeTo: root).standardizedFileURL
                    .resolvingSymlinksInPath()
                try addDirectInputs(in: moduleDirectory)
            }
        }

        // A CLI argument environment override can point Terraform at variable
        // files outside the root module. Track those files by content as well.
        for (key, value) in ProcessInfo.processInfo.environment where
            key == "TF_CLI_ARGS" || key.hasPrefix("TF_CLI_ARGS_") {
            for path in referencedVariableFiles(in: value) {
                urls.insert(URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath())
                guard urls.count <= maximumFiles else { throw CaptureError.tooManyFiles }
            }
        }

        // Backend metadata and workspace selection are Terraform's execution context.
        for relativePath in [".terraform/environment", ".terraform/terraform.tfstate"] {
            urls.insert(root.appendingPathComponent(relativePath))
        }

        // The local backend uses these conventional locations. Include both the
        // default and selected named workspace state because either can affect a switch.
        for relativePath in [
            "terraform.tfstate", "terraform.tfstate.backup",
            "terraform.tfstate.d/\(safeWorkspaceComponent(terraformWorkspace))/terraform.tfstate",
            "terraform.tfstate.d/\(safeWorkspaceComponent(terraformWorkspace))/terraform.tfstate.backup"
        ] {
            urls.insert(root.appendingPathComponent(relativePath))
        }
        let backendMetadata = root.appendingPathComponent(".terraform/terraform.tfstate")
        if FileManager.default.fileExists(atPath: backendMetadata.path) {
            let metadataSize = (try? backendMetadata.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard metadataSize <= 1024 * 1024,
                  let backendData = try? Data(contentsOf: backendMetadata),
                  let object = try? JSONSerialization.jsonObject(with: backendData) as? [String: Any],
                  let backend = object["backend"] as? [String: Any],
                  let backendType = backend["type"] as? String else {
                throw CaptureError.unreadable(backendMetadata)
            }
            let config = backend["config"] as? [String: Any] ?? [:]
            if backendType == "local" {
                let path = config["path"] as? String ?? "terraform.tfstate"
                let workspaceDirectory = config["workspace_dir"] as? String ?? "terraform.tfstate.d"
                let stateURL = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
                urls.insert(stateURL)
                urls.insert(URL(fileURLWithPath: path + ".backup", relativeTo: root).standardizedFileURL)
                if terraformWorkspace != "default" {
                    let namedState = URL(fileURLWithPath: workspaceDirectory, relativeTo: root)
                        .appendingPathComponent(terraformWorkspace)
                        .appendingPathComponent("terraform.tfstate")
                    urls.insert(namedState.standardizedFileURL)
                    urls.insert(URL(fileURLWithPath: namedState.path + ".backup"))
                }
            }
        }

        guard urls.count <= maximumFiles else { throw CaptureError.tooManyFiles }

        var hasher = SHA256()
        append("workspace=\(terraformWorkspace)\nbackend=\(backendIdentity)\nterraform=\(terraformVersion)\n", to: &hasher)
        append("inputs=\(inputsFingerprint)\n", to: &hasher)
        // Terraform and providers inherit the app environment. Hash it in memory
        // so credential or TF_VAR changes invalidate a reviewed plan without ever
        // placing raw values in history or UI.
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key }) {
            append("env-key=\(key)\n", to: &hasher)
            append("env-length=\(value.utf8.count):", to: &hasher)
            hasher.update(data: Data(value.utf8))
            append("\n", to: &hasher)
        }
        if let terraformExecutable {
            append("cli=\(terraformExecutable.standardizedFileURL.path)\n", to: &hasher)
            appendMetadata(terraformExecutable, to: &hasher)
        }

        for url in urls.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            append(url.path + "\n", to: &hasher)
            guard FileManager.default.fileExists(atPath: url.path) else {
                append("missing\n", to: &hasher)
                continue
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var fileHasher = SHA256()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    fileHasher.update(data: chunk)
                }
                append("content=\(SHA256Digest(fileHasher.finalize()))\n", to: &hasher)
            } catch {
                throw CaptureError.unreadable(url)
            }
        }
        return SHA256Digest(hasher.finalize())
    }

    @MainActor
    static func inputsFingerprint(terraformVariables: [TerraformVariable],
                                  environmentVariables: [EnvironmentVariable]) -> String {
        var hasher = SHA256()
        for variable in terraformVariables.filter(\.isUserInput).sorted(by: { $0.key < $1.key }) {
            append("terraform-key=\(variable.key);hcl=\(variable.hcl);\n", to: &hasher)
            append("value-length=\(variable.value.utf8.count):", to: &hasher)
            hasher.update(data: Data(variable.value.utf8))
            append("\n", to: &hasher)
        }
        for variable in environmentVariables.filter(\.isUserInput).sorted(by: { $0.key < $1.key }) {
            append("environment-key=\(variable.key);\n", to: &hasher)
            append("value-length=\(variable.value.utf8.count):", to: &hasher)
            hasher.update(data: Data(variable.value.utf8))
            append("\n", to: &hasher)
        }
        return SHA256Digest(hasher.finalize())
    }

    static func captureOffMainActor(_ context: WorkspaceContextCaptureContext) -> Task<String, Error> {
        Task.detached(priority: .userInitiated) {
            try capture(directory: context.directory, terraformWorkspace: context.terraformWorkspace,
                        backendIdentity: context.backendIdentity, terraformVersion: context.terraformVersion,
                        terraformExecutable: context.terraformExecutable, inputsFingerprint: context.inputsFingerprint)
        }
    }

    private static func append(_ value: String, to hasher: inout SHA256) {
        hasher.update(data: Data(value.utf8))
    }

    private static func appendMetadata(_ url: URL, to hasher: inout SHA256) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else {
            append("cli-missing\n", to: &hasher)
            return
        }
        append("cli-size=\(values.fileSize ?? -1);mtime=\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)\n", to: &hasher)
    }

    private static func safeWorkspaceComponent(_ workspace: String) -> String {
        guard !workspace.isEmpty, workspace != ".", workspace != "..",
              !workspace.contains("/"), !workspace.contains("\\") else { return "invalid-workspace" }
        return workspace
    }

    private static func referencedVariableFiles(in arguments: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:^|\s)-var-file(?:=|\s+)['\"]?([^\s'\"]+)"#
        ) else { return [] }
        let range = NSRange(arguments.startIndex..<arguments.endIndex, in: arguments)
        return expression.matches(in: arguments, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: arguments) else { return nil }
            return String(arguments[capture])
        }
    }
}

private func SHA256Digest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}
