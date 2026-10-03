import Foundation

struct ResourceBrowserRecord: Identifiable, Equatable, Sendable {
    let id: String
    let address: String
    let type: String
    let provider: String
    let module: String
    let mode: String

    init(id: String, address: String, type: String?, provider: String?, mode: String?) {
        self.id = id
        self.address = address
        self.type = type ?? "—"
        self.provider = provider ?? "—"
        self.mode = mode ?? "managed"
        self.module = Self.modulePath(in: address)
    }

    private static func modulePath(in address: String) -> String {
        var cursor = address.startIndex
        var moduleEnd: String.Index?
        while cursor < address.endIndex, address[cursor...].hasPrefix("module.") {
            cursor = address.index(cursor, offsetBy: "module.".count)
            guard cursor < address.endIndex else { break }
            while cursor < address.endIndex, address[cursor] != ".", address[cursor] != "[" {
                cursor = address.index(after: cursor)
            }
            if cursor < address.endIndex, address[cursor] == "[" {
                var depth = 0
                var inString = false
                var escaped = false
                repeat {
                    let character = address[cursor]
                    if inString {
                        if escaped { escaped = false }
                        else if character == "\\" { escaped = true }
                        else if character == "\"" { inString = false }
                    } else if character == "\"" { inString = true }
                    else if character == "[" { depth += 1 }
                    else if character == "]" { depth -= 1 }
                    cursor = address.index(after: cursor)
                } while cursor < address.endIndex && depth > 0
                guard depth == 0 else { break }
            }
            guard cursor < address.endIndex, address[cursor] == "." else { break }
            moduleEnd = cursor
            cursor = address.index(after: cursor)
        }
        guard let moduleEnd else { return "root" }
        return String(address[..<moduleEnd])
    }
}

struct ResourceBrowserQuery: Equatable, Sendable {
    var search = ""
    var mode = "All categories"
    var type = "All resource types"
    var provider = "All providers"
    var module = "All modules"
    var hasFilters: Bool {
        !search.isEmpty || mode != "All categories" || type != "All resource types" ||
        provider != "All providers" || module != "All modules"
    }
}

struct ResourceBrowserIndex: Sendable {
    let records: [ResourceBrowserRecord]
    let types: [String]
    let providers: [String]
    let modules: [String]

    init(records: [ResourceBrowserRecord]) {
        var seenIDs = Set<String>()
        let uniqueRecords = records.filter { seenIDs.insert($0.id).inserted }
        self.records = uniqueRecords
        types = Array(Set(uniqueRecords.map(\.type).filter { $0 != "—" })).sorted()
        providers = Array(Set(uniqueRecords.map(\.provider).filter { $0 != "—" })).sorted()
        modules = Array(Set(uniqueRecords.map(\.module))).sorted()
    }

    func matchingIDs(for query: ResourceBrowserQuery) -> [String] {
        let needle = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            (needle.isEmpty || record.address.localizedCaseInsensitiveContains(needle) ||
             record.type.localizedCaseInsensitiveContains(needle) ||
             record.provider.localizedCaseInsensitiveContains(needle) ||
             record.module.localizedCaseInsensitiveContains(needle)) &&
            (query.mode == "All categories" || record.mode == query.mode) &&
            (query.type == "All resource types" || record.type == query.type) &&
            (query.provider == "All providers" || record.provider == query.provider) &&
            (query.module == "All modules" || record.module == query.module)
        }.map(\.id)
    }

    static func safeSelection(_ selectedID: String?, visibleIDs: [String]) -> String? {
        guard let selectedID, visibleIDs.contains(selectedID) else { return nil }
        return selectedID
    }
}
