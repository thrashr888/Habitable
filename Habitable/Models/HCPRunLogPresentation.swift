import Foundation

/// Structured view of a Terraform JSON-UI (NDJSON) plan or apply log, plus any
/// plain-text lines mixed in. Values are passed through verbatim; redacted
/// placeholders stay as-is and nothing is synthesized.
struct HCPRunLogPresentation: Equatable, Sendable {
    struct Summary: Equatable, Sendable {
        var add: Int
        var change: Int
        var remove: Int
        var `import`: Int
    }

    struct Change: Equatable, Sendable, Identifiable {
        let address: String
        let action: ChangeActions
        var id: String { address + "|" + action.rawValue }
    }

    struct Diagnostic: Equatable, Sendable, Identifiable {
        let id: Int
        let severity: String
        let summary: String
        let detail: String?
        let address: String?
    }

    struct ApplyEvent: Equatable, Sendable, Identifiable {
        let id: Int
        let address: String
        let action: String
        /// started | progress | complete | errored
        let outcome: String
        let elapsedSeconds: Int?
    }

    var terraformVersion: String?
    var summary: Summary?
    /// "plan" | "apply"
    var summaryOperation: String?
    var plannedChanges: [Change] = []
    var diagnostics: [Diagnostic] = []
    var applyEvents: [ApplyEvent] = []
    /// Human-readable `@message` lines of other message types, in order.
    var messages: [String] = []
    /// Lines that were not JSON objects, trimmed and non-empty.
    var unparsedLines: [String] = []
    var rawText: String = ""

    static let maxLines = 20_000

    var replaceCount: Int { plannedChanges.filter { $0.action == .Replace }.count }
    var hasStructuredContent: Bool {
        summary != nil || !plannedChanges.isEmpty || !diagnostics.isEmpty || !applyEvents.isEmpty
    }

    private struct DiagnosticBlock {
        var severity: String
        var summary: String
        var detail: [String] = []
        var address: String?
        var boxed: Bool
    }

    private static let boxCharacters = CharacterSet(charactersIn: "│╷╵╴╶─")

    /// Removes ANSI escapes, including bare `[31m` fragments left after ESC was dropped.
    /// Bare fragments must be digits/semicolons ending in `m`, so `[redacted]` and `[id=...]` survive.
    static func stripANSI(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\[[0-9;]+m", with: "", options: .regularExpression)
        return out.replacingOccurrences(of: "\u{1B}", with: "")
    }

    static func parse(_ text: String) -> HCPRunLogPresentation {
        let clean = stripANSI(text)
        var result = HCPRunLogPresentation(rawText: clean)
        var block: DiagnosticBlock?
        func flush() {
            guard let b = block else { return }
            let detail = b.detail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            result.diagnostics.append(Diagnostic(id: result.diagnostics.count, severity: b.severity, summary: b.summary,
                                                 detail: detail.isEmpty ? nil : detail, address: b.address))
            block = nil
        }
        var lineCount = 0
        for substring in clean.split(separator: "\n", omittingEmptySubsequences: false) {
            lineCount += 1
            if lineCount > maxLines { break }
            let raw = String(substring)
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let object = jsonObject(in: line) {
                flush()
                result.absorb(object)
                continue
            }
            let content = line.trimmingCharacters(in: boxCharacters.union(.whitespaces))
            if var current = block {
                if raw.contains("╵") { flush(); continue }
                if content.isEmpty {
                    if current.boxed && raw.contains("│") { current.detail.append(""); block = current } else { flush() }
                    continue
                }
                if matchGroups("^(Error|Warning):\\s*(.*)$", content) == nil {
                    if let with = matchGroups("^with (.+?),?$", content) {
                        current.address = with[0]
                    } else {
                        current.detail.append(content)
                    }
                    block = current
                    continue
                }
                flush()
            }
            if content.isEmpty { continue }
            if let head = matchGroups("^(Error|Warning):\\s*(.*)$", content) {
                block = DiagnosticBlock(severity: head[0].lowercased(), summary: head[1],
                                        boxed: raw.unicodeScalars.contains { boxCharacters.contains($0) })
                continue
            }
            result.absorbText(content, unparsedOriginal: line)
        }
        flush()
        return result
    }

    private static func matchGroups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(1, match.numberOfRanges)).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// "2s", "1m30s", "1h2m3s" -> seconds.
    private static func seconds(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)([hms])") else { return nil }
        let ns = text as NSString
        var total = 0, found = false
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let n = Int(ns.substring(with: m.range(at: 1))) else { continue }
            found = true
            switch ns.substring(with: m.range(at: 2)) {
            case "h": total += n * 3600
            case "m": total += n * 60
            default: total += n
            }
        }
        return found ? total : nil
    }

    private mutating func absorbText(_ s: String, unparsedOriginal: String) {
        if let g = Self.matchGroups("^Terraform v(\\S+)", s) { terraformVersion = g[0]; return }
        if let g = Self.matchGroups("^Plan: (?:(\\d+) to import, )?(\\d+) to add, (\\d+) to change, (\\d+) to destroy", s) {
            summary = Summary(add: Int(g[1]) ?? 0, change: Int(g[2]) ?? 0, remove: Int(g[3]) ?? 0, import: Int(g[0]) ?? 0)
            summaryOperation = "plan"; return
        }
        if s.hasPrefix("No changes.") {
            summary = Summary(add: 0, change: 0, remove: 0, import: 0); summaryOperation = "plan"; return
        }
        if let g = Self.matchGroups("^Apply complete! Resources: (\\d+) added, (\\d+) changed, (\\d+) destroyed", s) {
            summary = Summary(add: Int(g[0]) ?? 0, change: Int(g[1]) ?? 0, remove: Int(g[2]) ?? 0, import: 0)
            summaryOperation = "apply"; return
        }
        if let g = Self.matchGroups("^# (\\S+) (will be created|will be updated in-place|will be destroyed|will be replaced|will be read during apply|must be replaced)", s) {
            let action: ChangeActions
            switch g[1] {
            case "will be created": action = .Create
            case "will be updated in-place": action = .Update
            case "will be destroyed": action = .Delete
            case "will be read during apply": action = .Read
            default: action = .Replace
            }
            let change = Change(address: g[0], action: action)
            if !plannedChanges.contains(change) { plannedChanges.append(change) }
            return
        }
        if let g = Self.matchGroups("^(\\S+): (Creating|Modifying|Destroying|Reading)\\.\\.\\.", s) {
            applyEvents.append(ApplyEvent(id: applyEvents.count, address: g[0], action: Self.textAction(g[1]),
                                          outcome: "started", elapsedSeconds: nil)); return
        }
        if let g = Self.matchGroups("^(\\S+): (Creation|Modifications|Destruction|Read) complete after (\\S+)", s) {
            applyEvents.append(ApplyEvent(id: applyEvents.count, address: g[0], action: Self.textAction(g[1]),
                                          outcome: "complete", elapsedSeconds: Self.seconds(g[2]))); return
        }
        if let g = Self.matchGroups("^(\\S+): Still (creating|modifying|destroying|reading)\\.\\.\\. \\[(\\S+) elapsed\\]", s) {
            applyEvents.append(ApplyEvent(id: applyEvents.count, address: g[0], action: Self.textAction(g[1]),
                                          outcome: "progress", elapsedSeconds: Self.seconds(g[2]))); return
        }
        let chatter = ["- Installing", "- Reusing previous version", "- Finding", "- Using", "- Installed", "Initializing",
                       "Partner and community providers are signed", "If you'd like to know more",
                       "Terraform has created a lock file", "Terraform has been successfully", "http://", "https://"]
        if chatter.contains(where: { s.hasPrefix($0) }) { messages.append(s); return }
        unparsedLines.append(unparsedOriginal)
    }

    private static func textAction(_ word: String) -> String {
        switch word.lowercased() {
        case "creating", "creation": return "create"
        case "modifying", "modifications", "modifying": return "update"
        case "destroying", "destruction": return "delete"
        default: return "read"
        }
    }

    private static func jsonObject(in line: String) -> [String: Any]? {
        var candidate = line
        if !line.hasPrefix("{") {
            // Tolerate stray framing characters before the object.
            guard let start = line.firstIndex(of: "{") else { return nil }
            candidate = String(line[start...])
        }
        guard candidate.hasSuffix("}"), let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? Double(string).map { Int($0) } }
        return nil
    }

    private mutating func absorb(_ object: [String: Any]) {
        let message = (object["@message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeName = object["type"] as? String
        guard let typeName, let type = MessageTypes(rawValue: typeName) else {
            addMessage(message)
            return
        }
        switch type {
        case .Version:
            if let version = object["terraform"] as? String { terraformVersion = version } else { addMessage(message) }
        case .ChangeSummary:
            let changes = object["changes"] as? [String: Any] ?? [:]
            summary = Summary(add: Self.int(changes["add"]) ?? 0, change: Self.int(changes["change"]) ?? 0,
                              remove: Self.int(changes["remove"]) ?? 0, import: Self.int(changes["import"]) ?? 0)
            summaryOperation = changes["operation"] as? String
        case .PlannedChange:
            let change = object["change"] as? [String: Any] ?? [:]
            let resource = change["resource"] as? [String: Any] ?? [:]
            guard let address = resource["addr"] as? String, !address.isEmpty else { addMessage(message); return }
            let actionName = change["action"] as? String ?? ""
            if let action = ChangeActions(rawValue: actionName) {
                if action != .NoOp { plannedChanges.append(Change(address: address, action: action)) }
            } else {
                // import/move have no ChangeActions case; keep Terraform's own text.
                addMessage(message ?? "\(actionName) \(address)")
            }
        case .Diagnostic:
            let diagnostic = object["diagnostic"] as? [String: Any] ?? [:]
            let summaryText = (diagnostic["summary"] as? String) ?? message ?? ""
            let detail = (diagnostic["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = (diagnostic["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            diagnostics.append(Diagnostic(id: diagnostics.count, severity: diagnostic["severity"] as? String ?? "error",
                                          summary: summaryText, detail: detail?.isEmpty == false ? detail : nil,
                                          address: address))
        case .ApplyStart, .ApplyProgress, .ApplyComplete, .ApplyErrored:
            let hook = object["hook"] as? [String: Any] ?? [:]
            let resource = hook["resource"] as? [String: Any] ?? [:]
            let outcome: String
            switch type {
            case .ApplyStart: outcome = "started"
            case .ApplyProgress: outcome = "progress"
            case .ApplyComplete: outcome = "complete"
            default: outcome = "errored"
            }
            applyEvents.append(ApplyEvent(id: applyEvents.count, address: resource["addr"] as? String ?? "unknown resource",
                                          action: hook["action"] as? String ?? "", outcome: outcome,
                                          elapsedSeconds: Self.int(hook["elapsed_seconds"])))
        case .Log, .Outputs, .ProvisionStart, .ProvisionProgress, .ProvisionComplete, .ProvisionErrored,
             .RefreshStart, .RefreshComplete:
            addMessage(message)
        }
    }

    private mutating func addMessage(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        messages.append(message)
    }
}
