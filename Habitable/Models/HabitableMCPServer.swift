import Foundation
#if canImport(MCP)
import MCP
import Combine

enum HabitableMCPRuntimeState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}

/// The app supplies snapshots from its selected Workspace. Closures must return only
/// redacted, bounded text and must route plans through Workspace.queueRun(planOnly: true).
struct HabitableMCPActions: Sendable {
    var workspaceStatus: @MainActor @Sendable () async -> String
    var declarations: @MainActor @Sendable () async -> String
    var resourceMetadata: @MainActor @Sendable () async -> String
    var outputMetadata: @MainActor @Sendable () async -> String
    var runSummaries: @MainActor @Sendable () async -> String
    var diagnostics: @MainActor @Sendable () async -> String
    var validate: @MainActor @Sendable () async -> String
    var requestPlan: @MainActor @Sendable () async -> String
    var runStatus: @MainActor @Sendable (_ id: String) async -> String
}

/// MCP protocol runtime for the opt-in local server. The HTTP listener calls
/// `handleHTTP` for each bounded POST; authentication is checked before parsing.
@MainActor
final class HabitableMCPServer: ObservableObject {
    static let maximumRequestBytes = HabitableMCPRequestPolicy.maximumRequestBytes
    static let bearerTokenBytes = HabitableMCPRequestPolicy.bearerTokenBytes
    static let endpointPath = HabitableMCPRequestPolicy.endpointPath

    private let actions: HabitableMCPActions
    private let token: String
    let bridgeIdentifier: String
    private var transport: StatelessHTTPServerTransport?
    private var server: Server?
    private let httpListener = HabitableMCPHTTPListener()
    private var started = false
    private var requestInFlight = false
    @Published private(set) var runtimeState: HabitableMCPRuntimeState = .stopped
    @Published private(set) var recentActivity: [String] = []
    @Published private(set) var endpointURL: URL?
    private var bridgeCredentialURL: URL?

    init(actions: HabitableMCPActions, token: String? = nil, bridgeIdentifier: String = UUID().uuidString.lowercased()) {
        self.actions = actions
        self.token = token ?? Self.generateToken()
        self.bridgeIdentifier = bridgeIdentifier
    }

    var bearerToken: String { token }
    var isRunning: Bool { started }
    var endpoint: URL? { endpointURL }

    func startListening() async throws {
        guard !started else { return }
        runtimeState = .starting
        let transport = StatelessHTTPServerTransport()
        let server = Server(name: "habitable", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", title: "Habitable",
                            instructions: "Inspect the selected Terraform workspace and request plan-only runs.",
                            capabilities: .init(tools: .init(listChanged: false)))
        self.transport = transport
        self.server = server
        await registerTools(on: server)
        do {
            try await server.start(transport: transport)
            started = true
            endpointURL = try await httpListener.start(server: self)
            runtimeState = .running
            recordActivity("Local MCP server started")
        } catch {
            started = false
            await server.stop()
            await transport.disconnect()
            self.server = nil
            self.transport = nil
            runtimeState = .failed(error.localizedDescription)
            throw error
        }
    }

    func start() async throws { try await startListening() }

    func stop() async {
        guard started || runtimeState == .starting else { return }
        httpListener.stop()
        endpointURL = nil
        if let server { await server.stop() }
        if let transport { await transport.disconnect() }
        self.server = nil
        self.transport = nil
        if let bridgeCredentialURL { try? FileManager.default.removeItem(at: bridgeCredentialURL) }
        bridgeCredentialURL = nil
        started = false
        runtimeState = .stopped
        recordActivity("Local MCP server stopped")
    }

    func registerBridgeCredentialFile(_ url: URL) {
        guard started else { try? FileManager.default.removeItem(at: url); return }
        bridgeCredentialURL = url
    }

    /// Called only by the private loopback HTTP listener after it enforces
    /// request framing bounds. Calls are serialized because the SDK 0.12.1
    /// stateless transport keys waiter/context tables by JSON-RPC ID.
    func handleHTTP(method: String, path: String, headers: [String: String], body: Data?) async -> HTTPResponse {
        guard started, let transport else { return .error(statusCode: 503, .internalError("Habitable MCP is disabled")) }
        if let (status, message) = HabitableMCPRequestPolicy.rejection(method: method, path: path,
                                                                        headers: headers, body: body, token: token) {
            recordActivity("Rejected MCP request (HTTP \(status))")
            return .error(statusCode: status, .invalidRequest(message),
                          extraHeaders: status == 405 ? ["Allow": "POST"] : [:])
        }
        guard !requestInFlight else { return .error(statusCode: 429, .internalError("A request is already being handled")) }
        requestInFlight = true
        defer { requestInFlight = false }
        recordActivity("Authenticated MCP request")
        let request = HTTPRequest(method: method, headers: headers, body: body, path: path)
        return await transport.handleRequest(request)
    }

    private func recordActivity(_ message: String) {
        recentActivity.insert("\(Date.now.formatted(date: .omitted, time: .shortened)) · \(message)", at: 0)
        if recentActivity.count > 20 { recentActivity = Array(recentActivity.prefix(20)) }
    }

    private func registerTools(on server: Server) async {
        let actions = self.actions
            await server.withMethodHandler(ListTools.self) { _ in
                let names = ["workspace_status", "declarations", "resource_metadata", "output_metadata", "run_summaries", "diagnostics", "validate_workspace", "plan_workspace", "run_status"]
                return .init(tools: names.map { name in
                    Tool(name: name, description: Self.description(for: name),
                         inputSchema: Self.schema(for: name),
                         annotations: .init(readOnlyHint: name != "plan_workspace" && name != "validate_workspace",
                                            destructiveHint: false,
                                            idempotentHint: name != "plan_workspace" && name != "validate_workspace",
                                            openWorldHint: false))
                })
            }
            await server.withMethodHandler(CallTool.self) { params in
                let text: String
                switch params.name {
                case "workspace_status": text = await actions.workspaceStatus()
                case "declarations": text = await actions.declarations()
                case "resource_metadata": text = await actions.resourceMetadata()
                case "output_metadata": text = await actions.outputMetadata()
                case "run_summaries": text = await actions.runSummaries()
                case "diagnostics": text = await actions.diagnostics()
                case "validate_workspace": text = await actions.validate()
                case "plan_workspace": text = await actions.requestPlan()
                case "run_status":
                    guard let id = params.arguments?["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 80 else {
                        return .init(content: [.text(text: "A valid run identifier is required.", annotations: nil, _meta: nil)], isError: true)
                    }
                    text = await actions.runStatus(id)
                default: return .init(content: [.text(text: "Unknown Habitable tool.", annotations: nil, _meta: nil)], isError: true)
                }
                return .init(content: [.text(text: Self.bounded(text), annotations: nil, _meta: nil)], isError: false)
            }
    }

    nonisolated private static func bounded(_ value: String) -> String {
        let limit = 32 * 1024
        guard value.utf8.count > limit else { return value }
        return String(decoding: value.utf8.prefix(limit), as: UTF8.self) + "\n[Response truncated]"
    }

    nonisolated private static func schema(for name: String) -> Value {
        let properties: [String: Value] = name == "run_status"
            ? ["id": .object(["type": .string("string"), "maxLength": .int(80)])] : [:]
        return .object(["type": .string("object"), "properties": .object(properties),
                        "additionalProperties": .bool(false)])
    }

    nonisolated private static func description(for name: String) -> String {
        switch name {
        case "workspace_status": "Read status for the user-selected workspace."
        case "declarations": "Read Terraform declarations and source locations without values."
        case "resource_metadata": "Read bounded resource addresses, types, providers, modules, and sensitivity metadata."
        case "output_metadata": "Read bounded output names and sensitivity metadata, without values."
        case "run_summaries": "Read bounded, redacted run and output summaries."
        case "diagnostics": "Read bounded configuration diagnostics."
        case "validate_workspace": "Validate the selected workspace configuration."
        case "plan_workspace": "Request a plan-only run. It never applies changes."
        default: "Read status for a known Habitable run identifier."
        }
    }

    private static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<bearerTokenBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
