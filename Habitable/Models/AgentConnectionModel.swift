import Foundation
import CryptoKit

/// A conservative JSON configuration editor used by agent connection adapters.
/// It preserves unrelated settings, makes a dated backup, and atomically replaces the file.
struct AgentJSONConfigurationEditor {
    enum EditError: Error { case malformedConfiguration, invalidPath }

    @discardableResult
    static func install(serverName: String, server: [String: Any], at url: URL,
                        sectionPath: [String] = ["mcpServers"]) throws -> URL? {
        guard !serverName.isEmpty, !serverName.contains("/") else { throw EditError.invalidPath }
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EditError.malformedConfiguration
            }
            root = object
        }
        var cursor = root
        var containers: [(String, [String: Any])] = []
        for key in sectionPath {
            containers.append((key, cursor))
            if let child = cursor[key] as? [String: Any] { cursor = child }
            else if cursor[key] == nil { cursor = [:] }
            else { throw EditError.malformedConfiguration }
        }
        cursor[serverName] = server
        for (key, parent) in containers.reversed() {
            var copy = parent
            copy[key] = cursor
            cursor = copy
        }
        let data = try JSONSerialization.data(withJSONObject: cursor, options: [.prettyPrinted, .sortedKeys])
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backupURL: URL?
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())")
            try manager.copyItem(at: url, to: backup)
            backupURL = backup
        }
        try data.write(to: url, options: .atomic)
        return backupURL
    }

    static func rollback(configurationURL: URL, backupURL: URL) throws {
        let original = try Data(contentsOf: backupURL)
        guard (try? JSONSerialization.jsonObject(with: original)) is [String: Any] else {
            throw EditError.malformedConfiguration
        }
        try original.write(to: configurationURL, options: .atomic)
    }

    @discardableResult
    static func remove(serverName: String, at url: URL,
                       sectionPath: [String] = ["mcpServers"]) throws -> URL? {
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EditError.malformedConfiguration
        }
        var parents: [(String, [String: Any])] = []
        var cursor = root
        for key in sectionPath {
            guard let child = cursor[key] as? [String: Any] else { return nil }
            parents.append((key, cursor)); cursor = child
        }
        guard cursor[serverName] != nil else { return nil }
        cursor.removeValue(forKey: serverName)
        for (key, parent) in parents.reversed() {
            var copy = parent; copy[key] = cursor; cursor = copy
        }
        root = cursor
        let replacement = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let backup = url.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())")
        try FileManager.default.copyItem(at: url, to: backup)
        try replacement.write(to: url, options: .atomic)
        return backup
    }

    static func configured(serverName: String, at url: URL,
                           sectionPath: [String] = ["mcpServers"]) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var cursor = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        for key in sectionPath {
            guard let child = cursor[key] as? [String: Any] else { return false }
            cursor = child
        }
        return cursor[serverName] != nil
    }
}

struct DetectedAgentClient: Identifiable, Equatable {
    let id: String
    let name: String
    let configURL: URL
    let sectionPath: [String]
    let configExists: Bool
    let appInstalled: Bool

    var isDetected: Bool { configExists || appInstalled }
    var isConfigured: Bool {
        if id == "codex" {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            return text.contains("[mcp_servers.habitable]") || text.contains("[mcp_servers.\"habitable\"]")
        }
        return AgentJSONConfigurationEditor.configured(serverName: "habitable", at: configURL, sectionPath: sectionPath)
    }

    func hasCurrentBridge(_ identifier: String) -> Bool {
        guard isConfigured else { return false }
        if id == "codex" {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            return text.contains("AgentBridge/\(identifier)/")
        }
        guard let data = try? Data(contentsOf: configURL),
              var cursor = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        for key in sectionPath {
            guard let child = cursor[key] as? [String: Any] else { return false }
            cursor = child
        }
        guard let server = cursor["habitable"] as? [String: Any], let args = server["args"] as? [String] else { return false }
        return args.contains { $0.contains("AgentBridge/\(identifier)/") }
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DetectedAgentClient] {
        let appSupport = home.appendingPathComponent("Library/Application Support")
        let entries: [(String, String, URL, [String])] = [
            ("codex", "Codex", home.appendingPathComponent(".codex/config.toml"), []),
            ("claude-desktop", "Claude Desktop", appSupport.appendingPathComponent("Claude/claude_desktop_config.json"), ["mcpServers"]),
            ("cursor", "Cursor", home.appendingPathComponent(".cursor/mcp.json"), ["mcpServers"]),
            ("kiro", "Kiro", home.appendingPathComponent(".kiro/settings/mcp.json"), ["mcpServers"]),
            ("gemini-cli", "Gemini CLI", home.appendingPathComponent(".gemini/settings.json"), ["mcpServers"]),
            ("copilot-cli", "GitHub Copilot CLI", home.appendingPathComponent(".copilot/mcp-config.json"), ["mcpServers"]),
            ("vscode-copilot", "VS Code with Copilot", appSupport.appendingPathComponent("Code/User/mcp.json"), ["servers"])
        ]
        return entries.map { id, name, url, section in
            DetectedAgentClient(id: id, name: name, configURL: url, sectionPath: section,
                                configExists: FileManager.default.fileExists(atPath: url.path),
                                appInstalled: knownApplicationInstalled(id: id))
        }
    }

    private static func knownApplicationInstalled(id: String) -> Bool {
        let candidates: [String: [String]] = [
            "claude-desktop": ["/Applications/Claude.app", "~/Applications/Claude.app"],
            "cursor": ["/Applications/Cursor.app", "~/Applications/Cursor.app"],
            "kiro": ["/Applications/Kiro.app", "~/Applications/Kiro.app"],
            "gemini-cli": ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"],
            "copilot-cli": ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"],
            "vscode-copilot": ["/Applications/Visual Studio Code.app", "~/Applications/Visual Studio Code.app"],
            "codex": (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        ]
        return (candidates[id] ?? []).contains { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) }
    }
}

/// Codex owns a TOML configuration file, so use its documented CLI adapter rather
/// than attempting to parse or rewrite TOML ourselves.
struct CodexMCPConfigurationAdapter {
    enum AdapterError: Error { case cliNotFound, commandFailed }

    static func install(script: URL) throws -> URL? {
        try run(["mcp", "add", "habitable", "--", "/usr/bin/python3", script.path])
    }

    static func remove() throws -> URL? {
        try run(["mcp", "remove", "habitable"])
    }

    private static func run(_ arguments: [String]) throws -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent(".codex/config.toml")
        var backup: URL?
        if FileManager.default.fileExists(atPath: config.path) {
            let backupURL = config.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())")
            try FileManager.default.copyItem(at: config, to: backupURL)
            backup = backupURL
        }
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let executable = searchPaths.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw AdapterError.cliNotFound }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            throw AdapterError.commandFailed
        }
        guard process.terminationStatus == 0 else { throw AdapterError.commandFailed }
        return backup
    }
}

struct HabitableStdioBridgeInstaller {
    enum InstallError: Error { case invalidEndpoint }

    static let releaseNotes = "HashiCorp Terraform MCP Server v1.3.0; HashiCorp Agent Skills v1.0.0"
    static let terraformMCPRelease = "v1.3.0"
    static let terraformSkillsRelease = "v1.0.0"
    static let terraformStyleGuidePath = "terraform/code-generation/skills/terraform-style-guide"
    static let terraformSkillsCommit = "146815e19decbb28252eebcf4125054e0a8783f1"
    static let terraformMCPReleaseURL = URL(string: "https://github.com/hashicorp/terraform-mcp-server/releases/tag/v1.3.0")!
    static let terraformSkillsReleaseURL = URL(string: "https://github.com/hashicorp/agent-skills/releases/tag/v1.0.0")!

    /// Writes a private runtime credential sidecar and a newline-delimited MCP stdio bridge.
    /// Client JSON contains only the Python executable and bridge path, never the bearer token.
    static func prepare(endpoint: URL, bearerToken: String, in directory: URL) throws -> URL {
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.path == "/mcp" else {
            throw InstallError.invalidEndpoint
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let scriptURL = directory.appendingPathComponent("habitable-mcp-stdio.py")
        let credentialsURL = directory.appendingPathComponent("habitable-mcp-stdio.json")
        let credentials = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint.absoluteString, "token": bearerToken])
        let script = #"""
        import json, pathlib, sys, urllib.error, urllib.request

        LIMIT = 65536
        config = json.loads(pathlib.Path(__file__).with_suffix('.json').read_text())
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        source = sys.stdin.buffer
        while True:
            line = source.readline(LIMIT + 2)
            if not line: break
            if len(line) > LIMIT + 1:
                print('Habitable MCP request too large', file=sys.stderr); sys.exit(2)
            body = line.rstrip(b'\r\n')
            if len(body) > LIMIT:
                print('Habitable MCP request too large', file=sys.stderr); sys.exit(2)
            if not body: continue
            try:
                request = urllib.request.Request(config['endpoint'], data=body, method='POST',
                    headers={'Authorization': 'Bearer ' + config['token'], 'Content-Type': 'application/json',
                             'Accept': 'application/json, text/event-stream'})
                response = opener.open(request, timeout=90)
                payload = response.read(LIMIT + 1)
                if len(payload) > LIMIT:
                    raise RuntimeError('Habitable MCP response too large')
                if payload:
                    sys.stdout.buffer.write(payload.rstrip(b'\r\n') + b'\n')
                    sys.stdout.buffer.flush()
            except urllib.error.HTTPError as error:
                print('Habitable MCP HTTP error: ' + str(error.code), file=sys.stderr)
                if error.code == 401: sys.exit(3)
            except Exception as error:
                print('Habitable MCP bridge failed: ' + str(error), file=sys.stderr)
                sys.exit(4)
        """#
        try credentials.write(to: credentialsURL, options: .atomic)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    static func installInClientConfiguration(script: URL, at configurationURL: URL,
                                             sectionPath: [String] = ["mcpServers"]) throws {
        var entry: [String: Any] = [
            "command": "/usr/bin/python3",
            "args": [script.path]
        ]
        if sectionPath.last == "servers" { entry["type"] = "stdio" }
        try AgentJSONConfigurationEditor.install(serverName: "habitable", server: entry, at: configurationURL, sectionPath: sectionPath)
    }
}

enum SkillInstaller {
    enum InstallError: Error { case invalidSkill, checksumMismatch, downloadFailed }

    @discardableResult
    static func installHabitableSkill() throws -> URL? {
        try install(files: ["SKILL.md": Data(HabitableAgentSkill.markdown.utf8)],
                    to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills/habitable-workflow", isDirectory: true))
    }

    static func installOfficialTerraformStyleGuide() async throws -> URL? {
        let base = "https://raw.githubusercontent.com/hashicorp/agent-skills/\(HabitableStdioBridgeInstaller.terraformSkillsCommit)/\(HabitableStdioBridgeInstaller.terraformStyleGuidePath)"
        let expected = [
            "SKILL.md": "fea8a0eadf68f1ac45cae3b1d6dc4c66b489fb6e40a3d41762120059c49540c2",
            "SECURITY.md": "3dc8ffa10139e9772c5c102fee6377f66f5167bd043a7c43e6e5df682dc75f92"
        ]
        var files: [String: Data] = [:]
        for (name, checksum) in expected {
            guard let url = URL(string: "\(base)/\(name)"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 256 * 1024,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw InstallError.checksumMismatch
            }
            files[name] = data
        }
        guard String(data: files["SKILL.md"] ?? Data(), encoding: .utf8)?.hasPrefix("---\nname: terraform-style-guide\n") == true else {
            throw InstallError.invalidSkill
        }
        return try install(files: files, to: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills/terraform-style-guide", isDirectory: true))
    }

    @discardableResult
    private static func install(files: [String: Data], to destination: URL) throws -> URL? {
        guard !files.isEmpty, files.keys.allSatisfy({ !$0.contains("/") && !$0.contains("..") }) else { throw InstallError.invalidSkill }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).tmp", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for (name, data) in files { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
            var backup: URL?
            if manager.fileExists(atPath: destination.path) {
                let url = destination.deletingLastPathComponent().appendingPathComponent("\(destination.lastPathComponent).backup-\(UUID().uuidString)", isDirectory: true)
                try manager.moveItem(at: destination, to: url); backup = url
            }
            do { try manager.moveItem(at: staging, to: destination) }
            catch {
                if let backup { try? manager.moveItem(at: backup, to: destination) }
                throw error
            }
            return backup
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
}

enum TerraformMCPInstaller {
    static func installPinnedRelease() -> Bool {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let go = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("go") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return false }
        let process = Process()
        process.executableURL = go
        process.arguments = ["install", "github.com/hashicorp/terraform-mcp-server/cmd/terraform-mcp-server@v1.3.0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            guard exited.wait(timeout: .now() + 300) == .success else { process.terminate(); return false }
            return process.terminationStatus == 0
        }
        catch { return false }
    }
}

enum HabitableAgentSkill {
    static let markdown = """
    ---
    name: habitable-workflow
    description: Safely inspect and plan Terraform workspaces through Habitable.
    ---

    # Habitable workflow

    Use the selected workspace in Habitable for Terraform work. Start by reading workspace status and declarations, then inspect redacted run and diagnostic summaries. Validate before requesting a plan. A plan request is plan-only and may take time; report its run identifier and poll its status. Review the plan in Habitable before any apply. Never request or expose Terraform state, credentials, sensitive variable values, or arbitrary shell commands. If no workspace is selected or the local server is unavailable, ask the user to select and enable it in Habitable.
    """
}
