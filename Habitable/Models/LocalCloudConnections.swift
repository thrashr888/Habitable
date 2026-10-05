import Foundation
import Combine
import Darwin

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

    private let runner: CloudCommandRunner
    private let environment: [String: String]
    private let executableLookup: @Sendable (String, [String: String]) -> URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         runner: @escaping CloudCommandRunner = LocalCloudConnectionsModel.runCommand,
         executableLookup: @escaping @Sendable (String, [String: String]) -> URL? = LocalCloudConnectionsModel.findExecutable) {
        self.environment = environment
        self.connections = [
            LocalCloudConnection(id: "aws", name: "AWS", status: "Not checked", isAuthenticated: false, details: [], loginCommand: "aws login"),
            LocalCloudConnection(id: "azure", name: "Azure", status: "Not checked", isAuthenticated: false, details: [], loginCommand: "az login"),
            LocalCloudConnection(id: "gcp", name: "Google Cloud", status: "Not checked", isAuthenticated: false, details: [], loginCommand: "gcloud auth login --update-adc")
        ]
        self.runner = runner
        self.executableLookup = executableLookup
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let aws = discoverAWS()
        async let azure = discoverAzure()
        async let gcp = discoverGCP()
        let results = await [aws, azure, gcp]
        connections = results
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
        await runner(exe, args, normalizedEnvironment(), 20)
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
