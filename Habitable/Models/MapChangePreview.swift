import Foundation

/// What a plan does to a tile or resource, ordered by severity.
enum MapChangeAction: String, Equatable, Sendable, Comparable {
    case none, read, create, update, replace, delete

    private var severity: Int {
        switch self {
        case .none: 0
        case .read: 1
        case .create: 2
        case .update: 3
        case .replace: 4
        case .delete: 5
        }
    }

    static func < (lhs: MapChangeAction, rhs: MapChangeAction) -> Bool { lhs.severity < rhs.severity }
}

/// A plan laid over the current map: planned creates become tiles, and every tile carries its most severe action.
struct MapChangePreview: Equatable, Sendable {
    let map: ResourceMap
    let tileActions: [String: MapChangeAction]
    let resourceActions: [String: MapChangeAction]
    let newTileIDs: Set<String>
    let consequences: PlanConsequences
    /// The plan the preview came from, for per-resource before/after in the Inspector.
    var plan: TerraformPlan? = nil

    func change(for address: String) -> PlanResourceChange? {
        plan?.resourceChanges.first { $0.address == address && $0.action != "no-op" }
    }

    var changedTileCount: Int { tileActions.values.filter { $0 != .none }.count }
    var unchangedTileCount: Int { tileActions.count - changedTileCount }

    static func action(for change: PlanResourceChange) -> MapChangeAction {
        if change.isReplacement { return .replace }
        switch change.action {
        case "create": return .create
        case "update": return .update
        case "delete": return .delete
        case "read": return .read
        default: return .none
        }
    }

    static func build(plan: TerraformPlan, stateResources: [MapResource]) throws -> MapChangePreview {
        var resourceActions: [String: MapChangeAction] = [:]
        for change in plan.resourceChanges {
            resourceActions[change.address] = max(resourceActions[change.address] ?? .none, action(for: change))
        }
        let existing = Set(stateResources.map(\.address))
        var combined = stateResources
        var added = Set<String>()
        for change in plan.resourceChanges where action(for: change) == .create && !existing.contains(change.address) {
            guard !added.contains(change.address), let parsed = parse(address: change.address) else { continue }
            added.insert(change.address)
            combined.append(MapResource(address: change.address, type: parsed.type, name: parsed.name,
                                        module: parsed.module, isData: parsed.isData))
        }
        let map = try ResourceMapClassifier().classify(combined)
        var tileActions: [String: MapChangeAction] = [:]
        var newTileIDs = Set<String>()
        for tile in map.tiles {
            let members = Set(tile.resources + [tile.id])
            tileActions[tile.id] = members.compactMap { resourceActions[$0] }.max() ?? MapChangeAction.none
            if members.isDisjoint(with: existing) { newTileIDs.insert(tile.id) }
        }
        var built = MapChangePreview(map: map, tileActions: tileActions, resourceActions: resourceActions,
                                newTileIDs: newTileIDs, consequences: plan.consequences)
        built.plan = plan
        return built
    }

    /// Overlay a plan on an already-classified map: current tiles and connections stay exactly as they are,
    /// and only creates that no tile contains are classified into new tiles appended to the map.
    static func build(plan: TerraformPlan, currentMap: ResourceMap) throws -> MapChangePreview {
        var resourceActions: [String: MapChangeAction] = [:]
        for change in plan.resourceChanges {
            resourceActions[change.address] = max(resourceActions[change.address] ?? MapChangeAction.none, action(for: change))
        }
        let known = Set(currentMap.tiles.flatMap { $0.resources + [$0.id] })
        var added = Set<String>()
        var created: [MapResource] = []
        for change in plan.resourceChanges where action(for: change) == .create && !known.contains(change.address) {
            guard added.insert(change.address).inserted, let parsed = parse(address: change.address) else { continue }
            created.append(MapResource(address: change.address, type: parsed.type, name: parsed.name,
                                       module: parsed.module, isData: parsed.isData))
        }
        let extra = try ResourceMapClassifier().classify(created)
        let currentIDs = Set(currentMap.tiles.map(\.id))
        let newTiles = extra.tiles.filter { !currentIDs.contains($0.id) }
        let map = ResourceMap(tiles: currentMap.tiles + newTiles,
                              connections: currentMap.connections + extra.connections,
                              dataSources: currentMap.dataSources,
                              workspaceReferences: currentMap.workspaceReferences)
        var tileActions: [String: MapChangeAction] = [:]
        for tile in map.tiles {
            tileActions[tile.id] = (tile.resources + [tile.id]).compactMap { resourceActions[$0] }.max() ?? MapChangeAction.none
        }
        var built = MapChangePreview(map: map, tileActions: tileActions, resourceActions: resourceActions,
                                newTileIDs: Set(newTiles.map(\.id)), consequences: plan.consequences)
        built.plan = plan
        return built
    }

    static func parse(address: String) -> (type: String, name: String, module: String, isData: Bool)? {
        // Split on dots outside brackets and quotes, then drop instance keys.
        var segments: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for char in address {
            if quoted {
                current.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { quoted = false }
                continue
            }
            switch char {
            case "\"": quoted = true; current.append(char)
            case "[": depth += 1; current.append(char)
            case "]": depth -= 1; current.append(char)
            case "." where depth == 0: segments.append(current); current = ""
            default: current.append(char)
            }
        }
        segments.append(current)
        segments = segments.map { segment in
            segment.firstIndex(of: "[").map { String(segment[..<$0]) } ?? segment
        }
        var index = 0
        var modules: [String] = []
        while index + 1 < segments.count, segments[index] == "module" {
            modules.append("module." + segments[index + 1])
            index += 2
        }
        var isData = false
        if index < segments.count, segments[index] == "data" { isData = true; index += 1 }
        guard segments.count - index == 2, segments[index..<index + 2].allSatisfy({ !$0.isEmpty }) else { return nil }
        return (segments[index], segments[index + 1], modules.joined(separator: "."), isData)
    }
}
