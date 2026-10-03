import Foundation

enum HabitableMCPRequestPolicy {
    static let maximumRequestBytes = 64 * 1024
    static let bearerTokenBytes = 32
    static let endpointPath = "/mcp"

    static func rejection(method: String, path: String, headers: [String: String], body: Data?, token: String) -> (Int, String)? {
        guard path == endpointPath else { return (404, "Not Found") }
        guard method.uppercased() == "POST" else { return (405, "Method Not Allowed") }
        guard bearerIsValid(headers, token: token) else { return (401, "Unauthorized") }
        guard let body, !body.isEmpty, body.count <= maximumRequestBytes else {
            return (413, "Request exceeds the 64 KiB limit")
        }
        return nil
    }

    private static func bearerIsValid(_ headers: [String: String], token: String) -> Bool {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })?.value,
              value.hasPrefix("Bearer ") else { return false }
        let supplied = Array(value.dropFirst(7).utf8)
        let expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
