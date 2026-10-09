import Foundation
import Combine
import Darwin
import AppKit

struct LocalCloudConnection: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let status: String
    let isAuthenticated: Bool
    let details: [String]
    let loginCommand: String
}

struct CloudCommandResult: Sendable {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
}

typealias CloudCommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) async -> CloudCommandResult

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < 64 * 1024 else { return }
        data.append(chunk.prefix(64 * 1024 - data.count))
    }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

@MainActor
final class LocalCloudConnectionsModel: ObservableObject {
    @Published private(set) var connections: [LocalCloudConnection]
    @Published private(set) var isRefreshing = false
    /// Providers whose checks are still running; each row clears on its own.
    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var connectingID: String?
    @Published private(set) var loginMessages: [String: String] = [:]
    private let loginRunner: CloudCommandRunner

    private let runner: CloudCommandRunner
    private let environment: [String: String]
    private let executableLookup: @Sendable (String, [String: String]) -> URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         runner: @escaping CloudCommandRunner = LocalCloudConnectionsModel.runCommand,
         loginRunner: @escaping CloudCommandRunner = LocalCloudConnectionsModel.runInteractiveLogin,
         executableLookup: @escaping @Sendable (String, [String: String]) -> URL? = LocalCloudConnectionsModel.findExecutable) {
        self.environment = environment
        self.connections = [
            LocalCloudConnection(id: "aws", name: "AWS", status: "Not checked", isAuthenticated: false, details: [], loginCommand: "aws login"),
            LocalCloudConnection(id: "azure", name: "Azure", status: "Not checked", isAuthenticated: false, details: [], loginCommand: "az login"),
            LocalCloudConnection(id: "gcp", name: "Google Cloud", status: "Not checked", isAuthenticated: false, details: [], loginCommand: "gcloud auth login --update-adc")
        ]
        self.runner = runner
        self.loginRunner = loginRunner
        self.executableLookup = executableLookup
    }

    func refresh() async {
        guard !isRefreshing, connectingID == nil else { return }
        isRefreshing = true
        refreshing = ["aws", "azure", "gcp"]
        defer { isRefreshing = false; refreshing = [] }
        await withTaskGroup(of: LocalCloudConnection.self) { group in
            group.addTask { await self.discoverAWS() }
            group.addTask { await self.discoverAzure() }
            group.addTask { await self.discoverGCP() }
            for await connection in group {
                if let index = connections.firstIndex(where: { $0.id == connection.id }) { connections[index] = connection }
                if connection.isAuthenticated { loginMessages[connection.id] = nil }
                refreshing.remove(connection.id)
            }
        }
    }

    private func loginConfiguration(_ id: String) -> (String, [String])? {
        switch id {
        case "aws": return ("aws", ["login"])
        case "azure": return ("az", ["login"])
        case "gcp": return ("gcloud", ["auth", "login", "--update-adc"])
        default: return nil
        }
    }

    func canConnect(_ id: String) -> Bool {
        guard !isRefreshing, connectingID == nil,
              let connection = connections.first(where: { $0.id == id }),
              !connection.isAuthenticated, connection.status != "Not checked",
              let (command, _) = loginConfiguration(id) else { return false }
        return executable(command) != nil
    }

    func connect(_ id: String) async {
        guard canConnect(id), let (command, arguments) = loginConfiguration(id),
              let cli = executable(command) else { return }
        connectingID = id
        loginMessages[id] = "Finish sign-in in Terminal and your browser. Habitable will check the connection when it finishes."
        let result = await loginRunner(cli, arguments, normalizedEnvironment(), 600)
        connectingID = nil
        await refresh()
        if connections.first(where: { $0.id == id })?.isAuthenticated == true {
            loginMessages[id] = nil
        } else if result.timedOut {
            loginMessages[id] = "Still waiting for sign-in. Finish or cancel it in Terminal, then refresh connections."
        } else if result.exitCode != 0 {
            loginMessages[id] = "Sign-in did not finish. Check the Terminal window for details, then try again."
        } else {
            loginMessages[id] = "Sign-in finished, but credentials could not be verified. Check the selected account in Terminal and refresh."
        }
    }

    /// Only CLI paths, fixed arguments and non-secret routing preferences are written here.
    nonisolated static func loginScript(executable: URL, arguments: [String], environment: [String: String], resultFile: URL) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let routingKeys = ["PATH", "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AZURE_CONFIG_DIR", "CLOUDSDK_CONFIG"]
        let exports = routingKeys.compactMap { key in environment[key].map { "export " + key + "=" + quote($0) } }.joined(separator: "\n")
        let invocation = ([executable.path] + arguments).map(quote).joined(separator: " ")
        return """
        #!/bin/bash
        umask 077
        \(exports)
        printf '%s\\n' 'Habitable cloud sign-in. Complete the prompts below and in your browser.'
        habitable_login_cancel() {
            printf '%s\\n' '130' > \(quote(resultFile.path))
            exit 130
        }
        trap habitable_login_cancel HUP INT TERM
        \(invocation)
        habitable_login_status=$?
        printf '%s\\n' "$habitable_login_status" > \(quote(resultFile.path))
        printf '%s\\n' 'Sign-in command finished. You can return to Habitable and close this window.'
        exit "$habitable_login_status"
        """
    }

    nonisolated private static func runInteractiveLogin(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> CloudCommandResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable-sign-in-" + UUID().uuidString, isDirectory: true)
        let script = folder.appendingPathComponent("Connect.command")
        let result = folder.appendingPathComponent("result")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try loginScript(executable: executable, arguments: arguments, environment: environment, resultFile: result).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return CloudCommandResult(exitCode: -1, output: "", timedOut: false) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let opened: Bool = await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
        guard opened else { return CloudCommandResult(exitCode: -1, output: "", timedOut: false) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: result, encoding: .utf8),
               let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return CloudCommandResult(exitCode: code, output: "", timedOut: false)
            }
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return CloudCommandResult(exitCode: -1, output: "", timedOut: true) }
        }
        return CloudCommandResult(exitCode: -1, output: "", timedOut: true)
    }

    private func executable(_ name: String) -> URL? {
        executableLookup(name, environment)
    }

    nonisolated private static func findExecutable(_ name: String, _ environment: [String: String]) -> URL? {
        let roots = ["/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for root in roots {
            let candidate = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func normalizedEnvironment() -> [String: String] {
        var env = environment
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = Array(NSOrderedSet(array: dirs)).compactMap { $0 as? String }.joined(separator: ":")
        return env
    }

    private func call(_ exe: URL, _ args: [String]) async -> CloudCommandResult {
        await runner(exe, args, normalizedEnvironment(), 10)
    }

    private func callDiscardingOutput(_ exe: URL, _ args: [String]) async -> CloudCommandResult {
        let result = await call(exe, args)
        return CloudCommandResult(exitCode: result.exitCode, output: "", timedOut: result.timedOut)
    }

    private func discoverAWS() async -> LocalCloudConnection {
        guard let cli = executable("aws") else { return missing("aws", "AWS") }
        let profileResult = await call(cli, ["configure", "list-profiles"])
        let profiles = profileResult.exitCode == 0 ? profileResult.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty } : []
        let identity = await call(cli, ["sts", "get-caller-identity", "--output", "json"])
        let identityJSON = jsonObject(identity.output)
        let account = identityJSON?["Account"] as? String
        let arn = identityJSON?["Arn"] as? String
        let ok = identity.exitCode == 0 && !identity.timedOut && account?.isEmpty == false && arn?.isEmpty == false
        var details: [String] = []
        if let account, !account.isEmpty { details.append("Account: \(account)") }
        if let arn, !arn.isEmpty { details.append("Identity: \(arn)") }
        let selectedProfile = environment["AWS_PROFILE"] ?? environment["AWS_DEFAULT_PROFILE"] ?? "default"
        details.append("Profile preference: \(selectedProfile)")
        if !profiles.isEmpty { details.append("Profiles: " + profiles.joined(separator: ", ")) }
        let awsStatus = identity.timedOut ? "AWS check timed out" : ok ? "Authenticated with AWS credentials" : "Sign-in required or AWS credentials invalid"
        return LocalCloudConnection(id: "aws", name: "AWS", status: awsStatus, isAuthenticated: ok, details: details, loginCommand: "aws login")
    }

    private func discoverAzure() async -> LocalCloudConnection {
        guard let cli = executable("az") else { return missing("azure", "Azure") }
        let account = await call(cli, ["account", "show", "--output", "json"])
        let metadata = account.exitCode == 0 ? jsonObject(account.output) : nil
        let token = await callDiscardingOutput(cli, ["account", "get-access-token", "--query", "expiresOn", "--output", "tsv"])
        var details: [String] = []
        if let metadata {
            if let name = metadata["name"] as? String, !name.isEmpty { details.append("Subscription: \(name)") }
            if let id = metadata["id"] as? String, !id.isEmpty { details.append("Subscription ID: \(id)") }
            if let user = metadata["user"] as? [String: Any], let name = user["name"] as? String, !name.isEmpty { details.append("Account: \(name)") }
            if let tenant = metadata["tenantId"] as? String, !tenant.isEmpty { details.append("Tenant: \(tenant)") }
        }
        let hasSubscription = metadata?["id"] as? String != nil && metadata?["name"] as? String != nil
        let ok = hasSubscription && !account.timedOut && token.exitCode == 0 && !token.timedOut
        let status = account.timedOut || token.timedOut ? "Azure check timed out" : ok ? "Authenticated Azure account" : "Sign-in required or Azure account unavailable"
        return LocalCloudConnection(id: "azure", name: "Azure", status: status, isAuthenticated: ok, details: details, loginCommand: "az login")
    }

    private func discoverGCP() async -> LocalCloudConnection {
        guard let cli = executable("gcloud") else { return missing("gcp", "Google Cloud") }
        let accountResult = await call(cli, ["config", "get-value", "account"])
        let projectResult = await call(cli, ["config", "get-value", "project"])
        let cliToken = await callDiscardingOutput(cli, ["auth", "print-access-token"])
        let adcToken = await callDiscardingOutput(cli, ["auth", "application-default", "print-access-token"])
        let account = accountResult.exitCode == 0 ? cleanValue(accountResult.output) : ""
        let project = projectResult.exitCode == 0 ? cleanValue(projectResult.output) : ""
        let cliOK = accountResult.exitCode == 0 && !account.isEmpty && account != "(unset)" && cliToken.exitCode == 0 && !cliToken.timedOut
        let adcOK = adcToken.exitCode == 0 && !adcToken.timedOut
        var details: [String] = []
        if !account.isEmpty && account != "(unset)" { details.append("Selected account: \(account)") }
        if !project.isEmpty && project != "(unset)" { details.append("Selected project: \(project)") }
        details.append("gcloud CLI credentials: \(cliOK ? "available" : "unavailable")")
        details.append("Application Default Credentials: \(adcOK ? "available" : "unavailable")")
        let timedOut = accountResult.timedOut || projectResult.timedOut || cliToken.timedOut || adcToken.timedOut
        let complete = cliOK && adcOK
        let status = timedOut ? "Google Cloud check timed out" : complete ? "Google Cloud credentials available" : (cliOK || adcOK) ? "Sign-in incomplete: configure both CLI and ADC" : "No valid Google Cloud credentials"
        return LocalCloudConnection(id: "gcp", name: "Google Cloud", status: status, isAuthenticated: complete, details: details, loginCommand: "gcloud auth login --update-adc")
    }

    private func missing(_ id: String, _ name: String) -> LocalCloudConnection {
        LocalCloudConnection(id: id, name: name, status: "CLI not installed", isAuthenticated: false, details: [], loginCommand: id == "aws" ? "aws login" : id == "azure" ? "az login" : "gcloud auth login --update-adc")
    }

    private func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func cleanValue(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    nonisolated private static func runCommand(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> CloudCommandResult {
        await Task.detached(priority: .utility) {
            runCommandSynchronously(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
    }

    nonisolated private static func runCommandSynchronously(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) -> CloudCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let discard = arguments == ["auth", "print-access-token"] || arguments == ["auth", "application-default", "print-access-token"] || arguments == ["account", "get-access-token", "--query", "expiresOn", "--output", "tsv"]
        let pipe = Pipe()
        process.standardOutput = discard ? FileHandle.nullDevice : pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return CloudCommandResult(exitCode: -1, output: "", timedOut: false) }
        let handle = pipe.fileHandleForReading
        let output = BoundedOutput()
        if !discard {
            handle.readabilityHandler = { stream in
                let chunk = stream.availableData
                if !chunk.isEmpty { output.append(chunk) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        handle.readabilityHandler = nil
        if !discard {
            output.append(handle.readDataToEndOfFile())
        }
        return CloudCommandResult(exitCode: process.terminationStatus, output: output.string, timedOut: timedOut)
    }
}
