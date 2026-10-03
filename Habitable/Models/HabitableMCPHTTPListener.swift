import Foundation
#if canImport(Network) && canImport(MCP)
@preconcurrency import Network
import MCP

enum HabitableMCPHTTPParseResult {
    case incomplete
    case invalid(Int, String)
    case request(String, String, [String: String], Data)
}

enum HabitableMCPHTTPParser {
    static let maximumHeaderBytes = 8 * 1024

    static func parse(_ data: Data) -> HabitableMCPHTTPParseResult {
        guard data.count <= HabitableMCPRequestPolicy.maximumRequestBytes + maximumHeaderBytes else {
            return .invalid(413, "Request too large")
        }
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else {
            return data.count > maximumHeaderBytes ? .invalid(431, "Headers too large") : .incomplete
        }
        guard range.lowerBound <= maximumHeaderBytes else { return .invalid(431, "Headers too large") }
        guard let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return .invalid(400, "Invalid HTTP headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid(400, "Invalid request") }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else { return .invalid(400, "Invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "Invalid header") }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { return .invalid(400, "Duplicate or invalid header") }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { return .invalid(400, "Chunked requests are unsupported") }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 else {
            return .invalid(411, "Content-Length is required")
        }
        guard length <= HabitableMCPRequestPolicy.maximumRequestBytes else { return .invalid(413, "Request too large") }
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + length else { return .incomplete }
        guard data.count == bodyStart + length else { return .invalid(400, "Unexpected request bytes") }
        return .request(String(requestLine[0]), String(requestLine[1]), headers, data[bodyStart...])
    }
}

/// A single-purpose HTTP/1.1 listener that binds only to 127.0.0.1. It deliberately
/// supports bounded Content-Length POSTs only; no chunking, upgrades, or file serving.
@MainActor
final class HabitableMCPHTTPListener {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.habitable.mcp-http")
    private let connectionSlots = DispatchSemaphore(value: 4)
    private let connections = MCPHTTPConnectionRegistry()
    private weak var server: HabitableMCPServer?

    var endpoint: URL? {
        guard let port = listener?.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)\(HabitableMCPRequestPolicy.endpointPath)")
    }

    func start(server: HabitableMCPServer) async throws -> URL {
        guard listener == nil else { if let endpoint { return endpoint }; throw ListenerError.notReady }
        self.server = server
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let slots = connectionSlots
        let registry = connections
        let queue = self.queue
        listener.newConnectionHandler = { [weak server] connection in
            guard let server else { connection.cancel(); return }
            guard slots.wait(timeout: .now()) == .success else { connection.cancel(); return }
            let lease = MCPHTTPConnectionLease(connection: connection, slots: slots, registry: registry)
            registry.insert(lease)
            connection.stateUpdateHandler = { state in
                if case .failed = state { lease.finish() }
                if case .cancelled = state { lease.finish() }
            }
            connection.start(queue: queue)
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                    lease.finish()
                } catch {
                    // A completed exchange cancels the deadline task.
                }
            }
            Self.receive(lease, server: server, buffer: Data(), timeout: timeout)
        }
        self.listener = listener
        listener.start(queue: queue)
        for _ in 0..<40 {
            switch listener.state {
            case .ready:
                if let endpoint { return endpoint }
                throw ListenerError.notReady
            case .failed(let error): self.listener = nil; throw error
            case .cancelled: self.listener = nil; throw ListenerError.cancelled
            default: try await Task.sleep(for: .milliseconds(50))
            }
        }
        listener.cancel(); self.listener = nil
        throw ListenerError.notReady
    }

    func stop() {
        listener?.cancel()
        listener = nil
        server = nil
        connections.cancelAll()
    }

    private enum ListenerError: Error { case notReady, cancelled }

    nonisolated private static func receive(_ lease: MCPHTTPConnectionLease, server: HabitableMCPServer, buffer: Data, timeout: Task<Void, Never>) {
        let connection = lease.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if error != nil { timeout.cancel(); lease.finish(); return }
            switch HabitableMCPHTTPParser.parse(accumulated) {
            case .incomplete where !complete:
                receive(lease, server: server, buffer: accumulated, timeout: timeout)
            case .request(let method, let path, let headers, let body):
                Task { @MainActor in
                    let response = await server.handleHTTP(method: method, path: path, headers: headers, body: body)
                    timeout.cancel()
                    send(response, lease: lease)
                }
            case .invalid(let status, let message):
                timeout.cancel()
                send(status: status, message: message, lease: lease)
            default:
                timeout.cancel()
                send(status: 400, message: "Incomplete request", lease: lease)
            }
        }
    }

    nonisolated private static func send(_ response: HTTPResponse, lease: MCPHTTPConnectionLease) {
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        send(status: response.statusCode, headers: headers, body: body, lease: lease)
    }

    nonisolated private static func send(status: Int, message: String, lease: MCPHTTPConnectionLease) {
        let body = Data(message.utf8)
        send(status: status, headers: ["Content-Type": "text/plain; charset=utf-8", "Content-Length": String(body.count), "Connection": "close"], body: body, lease: lease)
    }

    nonisolated private static func send(status: Int, headers: [String: String], body: Data, lease: MCPHTTPConnectionLease) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers where !key.contains("\r") && !value.contains("\r") { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        lease.connection.send(content: data, completion: .contentProcessed { _ in lease.finish() })
    }
}

private final class MCPHTTPConnectionLease: @unchecked Sendable {
    let connection: NWConnection
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private let registry: MCPHTTPConnectionRegistry
    private var released = false

    init(connection: NWConnection, slots: DispatchSemaphore, registry: MCPHTTPConnectionRegistry) {
        self.connection = connection; self.slots = slots; self.registry = registry
    }

    func finish() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        guard shouldRelease else { return }
        registry.remove(self)
        connection.stateUpdateHandler = nil
        connection.cancel()
        slots.signal()
    }
}

private final class MCPHTTPConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ObjectIdentifier: MCPHTTPConnectionLease] = [:]

    func insert(_ lease: MCPHTTPConnectionLease) {
        lock.lock(); items[ObjectIdentifier(lease)] = lease; lock.unlock()
    }

    func remove(_ lease: MCPHTTPConnectionLease) {
        lock.lock(); items.removeValue(forKey: ObjectIdentifier(lease)); lock.unlock()
    }

    func cancelAll() {
        lock.lock(); let leases = Array(items.values); items.removeAll(); lock.unlock()
        leases.forEach { $0.finish() }
    }
}
#endif
