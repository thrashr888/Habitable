import Foundation

/// One row of the List: a resource as the Map knows it.
struct ResourceListRow: Identifiable, Equatable, Sendable {
    let id: String
    let address: String
    let name: String
    let type: String
    let provider: String
    let module: String
    let kind: String
    let tileID: String?
    /// "new" | "update" | "replace" | "remove" | "read" | "drifted" | "unchanged"
    let status: String
    let isDataSource: Bool
}

struct ResourceListToken: Equatable, Sendable, Hashable {
    enum Field: String, Sendable, CaseIterable { case type, module, provider, status, kind, name, tag }
    let field: Field
    /// May end with `*` for a prefix match, or contain `*` as a glob.
    let value: String

    /// How the token is written back into the field.
    var rendered: String {
        let needsQuotes = value.contains { $0.isWhitespace || $0 == "\"" }
        return "\(field.rawValue):" + (needsQuotes ? "\"\(value.replacingOccurrences(of: "\"", with: ""))\"" : value)
    }
}

struct ResourceListQuery: Equatable, Sendable {
    /// The raw field contents.
    var text: String = ""

    /// One whitespace-separated word of `text`, as typed and as understood.
    private struct Word {
        let raw: String
        let content: String
        let token: ResourceListToken?
    }

    private var words: [Word] {
        var result: [Word] = []
        var raw = ""
        var content = ""
        var inQuotes = false
        func flush() {
            defer { raw = ""; content = "" }
            guard !raw.isEmpty else { return }
            result.append(Word(raw: raw, content: content, token: Self.token(from: content)))
        }
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                raw.append(character)
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else {
                raw.append(character)
                content.append(character)
            }
        }
        flush()
        return result
    }

    private static func token(from content: String) -> ResourceListToken? {
        guard let colon = content.firstIndex(of: ":"),
              let field = ResourceListToken.Field(rawValue: content[..<colon].lowercased()) else { return nil }
        let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : ResourceListToken(field: field, value: value)
    }

    /// Tokens parsed from `text` (field:value pairs, values may be quoted).
    var tokens: [ResourceListToken] { words.compactMap(\.token) }

    /// The leftover free words, space-joined.
    var freeText: String { freeTerms.joined(separator: " ") }

    /// Free words; a quoted phrase counts as one word. Empty `field:` words are dropped.
    var freeTerms: [String] {
        words.compactMap { word in
            guard word.token == nil, !word.content.isEmpty else { return nil }
            if let colon = word.content.firstIndex(of: ":"), word.content.index(after: colon) == word.content.endIndex,
               ResourceListToken.Field(rawValue: word.content[..<colon].lowercased()) != nil { return nil }
            return word.content
        }
    }

    var isEmpty: Bool { tokens.isEmpty && freeTerms.isEmpty }

    /// Removes the first occurrence of one token from `text`, keeping the rest intact.
    func removing(_ token: ResourceListToken) -> ResourceListQuery {
        var kept = words.map(\.raw)
        if let index = words.firstIndex(where: { $0.token == token }) { kept.remove(at: index) }
        return ResourceListQuery(text: kept.joined(separator: " "))
    }

    /// Adds a token to `text`; with `replace` an existing token of the same field is swapped in place.
    func adding(_ token: ResourceListToken, replace: Bool) -> ResourceListQuery {
        var raws = words.map(\.raw)
        if replace, let index = words.firstIndex(where: { $0.token?.field == token.field }) {
            raws[index] = token.rendered
        } else if !tokens.contains(token) {
            raws.append(token.rendered)
        }
        return ResourceListQuery(text: raws.joined(separator: " "))
    }
}

enum ResourceListFilter {
    /// Rows matching the query: every token must match, and every free word must match name, address, type or module.
    static func apply(_ query: ResourceListQuery, to rows: [ResourceListRow]) -> [ResourceListRow] {
        let tokens = query.tokens
        let terms = query.freeTerms.map { $0.lowercased() }
        guard !tokens.isEmpty || !terms.isEmpty else { return rows }
        return rows.filter { row in
            tokens.allSatisfy { matches($0, row) } && terms.allSatisfy { term in
                [row.name, row.address, row.type, row.module].contains { $0.lowercased().contains(term) }
            }
        }
    }

    /// Distinct values for a field across rows, sorted, for suggestion menus.
    static func suggestions(for field: ResourceListToken.Field, in rows: [ResourceListRow]) -> [String] {
        let values: [String] = rows.map { row in
            switch field {
            case .type: row.type
            case .module: row.module
            case .provider: row.provider
            case .status: row.status
            case .kind: row.kind
            case .name: row.name
            case .tag: ""
            }
        }
        return Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Addresses joined with newlines, for Copy Addresses.
    static func addressesText(_ rows: [ResourceListRow]) -> String {
        rows.map(\.address).joined(separator: "\n")
    }

    private static let changedStatuses: Set<String> = ["new", "update", "replace", "remove"]

    private static func matches(_ token: ResourceListToken, _ row: ResourceListRow) -> Bool {
        let value = token.value.lowercased()
        switch token.field {
        case .type: return glob(value, row.type)
        case .provider: return glob(value, row.provider)
        case .kind: return glob(value, row.kind)
        case .name: return glob(value, row.name)
        case .tag: return false
        case .module:
            let module = row.module.lowercased()
            return glob(value, module) || (!value.contains("*") && module.hasPrefix(value + "."))
        case .status:
            switch value {
            case "changed": return changedStatuses.contains(row.status)
            case "create": return row.status == "new"
            case "delete": return row.status == "remove"
            default: return glob(value, row.status)
            }
        }
    }

    /// Case-insensitive `*` glob; `pattern` must already be lowercased.
    private static func glob(_ pattern: String, _ candidate: String) -> Bool {
        let text = candidate.lowercased()
        guard pattern.contains("*") else { return pattern == text }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var remaining = Substring(text)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                guard remaining.hasPrefix(part) else { return false }
                remaining = remaining.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return remaining.hasSuffix(part)
            } else if !part.isEmpty {
                guard let range = remaining.range(of: part) else { return false }
                remaining = remaining[range.upperBound...]
            }
        }
        return true
    }
}

enum ResourceListBuilder {
    /// Builds rows from the Map's resources and tiles. `tiles` may be empty (no map).
    /// `actions` maps address to a MapChangeAction raw word.
    static func rows(resources: [MapDisplayResource], tiles: [MapTile], actions: [String: String], drifted: Set<String>) -> [ResourceListRow] {
        var tileByAddress: [String: MapTile] = [:]
        for tile in tiles {
            for address in tile.resources where tileByAddress[address] == nil { tileByAddress[address] = tile }
        }
        let typeByAddress = Dictionary(resources.map { ($0.address, $0.type) }, uniquingKeysWith: { first, _ in first })
        return resources.map { resource in
            let parsed = parse(resource.address)
            let tile = tileByAddress[resource.address]
            return ResourceListRow(
                id: resource.address,
                address: resource.address,
                name: name(for: resource, tile: tile, parsedName: parsed.name, typeByAddress: typeByAddress),
                type: resource.type,
                provider: provider(resource.providerName, type: resource.type),
                module: parsed.modules.isEmpty ? "root" : parsed.modules.joined(separator: "."),
                kind: tile.map { kindTitle($0.kind) } ?? "",
                tileID: tile?.id,
                status: status(actions[resource.address], drifted: drifted.contains(resource.address)),
                isDataSource: parsed.isData
            )
        }
    }

    private static func status(_ action: String?, drifted: Bool) -> String {
        switch action {
        case "create": return "new"
        case "update": return "update"
        case "replace": return "replace"
        case "delete": return "remove"
        case "read": return "read"
        default: return drifted ? "drifted" : "unchanged"
        }
    }

    /// The tile's title for its anchor; for the tile's other members, the title
    /// plus the member's role ("Static Site · acl", "Static Site · versioning"),
    /// so a tile of five resources does not read as five identical names.
    static func name(for resource: MapDisplayResource, tile: MapTile?, parsedName: String, typeByAddress: [String: String]) -> String {
        guard let tile else { return parsedName }
        // A title that is only the resource name capitalized ("This") adds nothing; keep the name as written.
        let title = tile.title == parsedName.capitalized ? parsedName : tile.title
        if tile.anchors.contains(resource.address) || tile.resources.count == 1 { return title }
        let anchorType = tile.anchors.compactMap { typeByAddress[$0] }.first ?? ""
        return title + " · " + role(of: resource.type, relativeTo: anchorType)
    }

    /// "aws_s3_bucket_acl" relative to "aws_s3_bucket" is "acl"; with no shared
    /// prefix the type loses only its provider prefix ("route53 record").
    static func role(of type: String, relativeTo anchorType: String) -> String {
        let parts = type.split(separator: "_").map(String.init)
        let anchorParts = anchorType.split(separator: "_").map(String.init)
        var shared = 0
        while shared < min(parts.count, anchorParts.count), parts[shared] == anchorParts[shared] { shared += 1 }
        let tail = shared >= 2 && shared < parts.count ? Array(parts[shared...]) : Array(parts.dropFirst())
        return (tail.isEmpty ? parts : tail).joined(separator: " ")
    }

    private static func provider(_ name: String?, type: String) -> String {
        if var name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if name.hasPrefix("provider["), name.hasSuffix("]") { name = String(name.dropFirst(9).dropLast()) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let last = name.split(separator: "/").last, !last.isEmpty { return String(last) }
        }
        return type.split(separator: "_", maxSplits: 1).first.map(String.init) ?? type
    }

    private static func kindTitle(_ kind: MapKind) -> String {
        switch kind {
        case .frontDoor: "Front door"
        case .appsAndAI: "Apps & AI"
        case .code: "Code & delivery"
        case .messaging: "Messaging & events"
        case .data: "Data"
        case .network: "Network"
        case .identityAndMonitoring: "Identity & monitoring"
        case .other: "Other resources"
        }
    }

    /// Splits `module.a.module.b["k.x"].data.type.name[0]` into module names, data flag and the instance name.
    private static func parse(_ address: String) -> (modules: [String], isData: Bool, name: String) {
        var cursor = address.startIndex
        var modules: [String] = []
        while address[cursor...].hasPrefix("module.") {
            let start = address.index(cursor, offsetBy: 7)
            var end = start
            while end < address.endIndex, address[end] != ".", address[end] != "[" { end = address.index(after: end) }
            var next = end
            if next < address.endIndex, address[next] == "[" {
                var depth = 0
                var inString = false
                var escaped = false
                repeat {
                    let character = address[next]
                    if inString {
                        if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                    } else if character == "\"" { inString = true } else if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
                    next = address.index(after: next)
                } while next < address.endIndex && depth > 0
                guard depth == 0 else { break }
            }
            guard next < address.endIndex, address[next] == "." else { break }
            modules.append(String(address[start..<end]))
            cursor = address.index(after: next)
        }
        var rest = address[cursor...]
        let isData = rest.hasPrefix("data.")
        if isData { rest = rest.dropFirst(5) }
        // type.name[index]: the name is everything after the first dot.
        let name = rest.firstIndex(of: ".").map { String(rest[rest.index(after: $0)...]) } ?? String(rest)
        return (modules, isData, name.isEmpty ? String(rest) : name)
    }
}
