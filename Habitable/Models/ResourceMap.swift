import Foundation
import CoreFoundation

/// Map metadata deliberately excludes attribute values, which may contain secrets.
struct MapResource: Equatable, Sendable {
    let address: String
    let type: String
    let name: String
    let module: String
    let isData: Bool
    let dependencies: [String]

    init(address: String, type: String, name: String, module: String = "",
         isData: Bool = false, dependencies: [String] = []) {
        self.address = address
        self.type = type
        self.name = name
        self.module = module
        self.isData = isData
        self.dependencies = dependencies
    }
}

enum MapKind: Int, CaseIterable, Sendable {
    case frontDoor, appsAndAI, messaging, data, network, identityAndMonitoring, other
}

struct MapTile: Equatable, Sendable {
    /// Stable Terraform address, independent of collection order and display name.
    let id: String
    let title: String
    let kind: MapKind
    let anchors: [String]
    let resources: [String]
}

struct MapConnection: Equatable, Hashable, Sendable {
    let source: String
    let target: String
}

struct MapWorkspaceReference: Equatable, Sendable {
    let address: String
    /// The Terraform data-source alias, not a verified remote workspace name.
    let name: String
    let consumers: [String]
}

struct ResourceMap: Equatable, Sendable {
    let tiles: [MapTile]
    let connections: [MapConnection]
    let dataSources: [String]
    var workspaceReferences: [MapWorkspaceReference] = []
}

struct MapCanvasBand: Equatable, Sendable {
    let kind: MapKind
    let y: Double
    let height: Double
}

struct MapCanvasTile: Equatable, Sendable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct MapCanvasLayout: Equatable, Sendable {
    let width: Double
    let height: Double
    let bands: [MapCanvasBand]
    let tiles: [MapCanvasTile]

    init(map: ResourceMap, width requestedWidth: Double) {
        let minimumWidth = 680.0
        let tileWidth = 264.0
        let tileHeight = 120.0
        let horizontalInset = 28.0
        let tileGap = 70.0
        let rowGap = 26.0
        let topPadding = 38.0
        let bottomPadding = 20.0
        let bandGap = 12.0

        width = max(minimumWidth, requestedWidth)
        let availableWidth = width - 2 * horizontalInset
        let columns = max(1, Int((availableWidth + tileGap) / (tileWidth + tileGap)))
        let groupedTiles = Dictionary(grouping: map.tiles, by: \.kind)
        var y = 0.0
        var bands: [MapCanvasBand] = []
        var positionedTiles: [MapCanvasTile] = []

        let kinds = MapKind.allCases.filter { $0 != .other || !(groupedTiles[.other] ?? []).isEmpty }
        for (bandIndex, kind) in kinds.enumerated() {
            let orderedTiles = Self.orderedTiles(groupedTiles[kind] ?? [], connections: map.connections)
            let rowCount = (orderedTiles.count + columns - 1) / columns
            let bandHeight = orderedTiles.isEmpty
                ? 54.0
                : topPadding + Double(rowCount) * tileHeight + Double(max(0, rowCount - 1)) * rowGap + bottomPadding
            bands.append(MapCanvasBand(kind: kind, y: y, height: bandHeight))

            for (index, tile) in orderedTiles.enumerated() {
                let column = index % columns
                let row = index / columns
                positionedTiles.append(MapCanvasTile(
                    id: tile.id,
                    x: horizontalInset + Double(column) * (tileWidth + tileGap),
                    y: y + topPadding + Double(row) * (tileHeight + rowGap),
                    width: tileWidth,
                    height: tileHeight
                ))
            }
            y += bandHeight
            if bandIndex < kinds.count - 1 { y += bandGap }
        }

        self.height = y
        self.bands = bands
        self.tiles = positionedTiles
    }

    private static func orderedTiles(_ tiles: [MapTile], connections: [MapConnection]) -> [MapTile] {
        let byID = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0) })
        var outgoing: [String: Set<String>] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, 0) })
        for connection in connections where byID[connection.source] != nil && byID[connection.target] != nil {
            guard outgoing[connection.source, default: []].insert(connection.target).inserted else { continue }
            indegree[connection.target, default: 0] += 1
        }

        var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var orderedIDs: [String] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            orderedIDs.append(id)
            for target in (outgoing[id] ?? []).sorted() {
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 {
                    let insertionIndex = ready.firstIndex(where: { $0 > target }) ?? ready.endIndex
                    ready.insert(target, at: insertionIndex)
                }
            }
        }
        if orderedIDs.count < tiles.count {
            let placed = Set(orderedIDs)
            orderedIDs.append(contentsOf: tiles.map(\.id).filter { !placed.contains($0) }.sorted())
        }
        return orderedIDs.compactMap { byID[$0] }
    }
}

enum ResourceMapError: Error, Equatable {
    case invalidState
    case invalidResource
    case duplicateAddress(String)
}

/// Accepts raw state v4 (local or HCP) and terraform show JSON. Show JSON has
/// no exact dependency graph; do not manufacture edges from arbitrary values.
enum ResourceMapStateReader {
    static func read(_ data: Data) throws -> [MapResource] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResourceMapError.invalidState
        }
        var result: [MapResource] = []
        if root["version"] as? Int == 4, let resources = root["resources"] as? [[String: Any]] {
            for resource in resources {
                guard let type = resource["type"] as? String, let name = resource["name"] as? String,
                      let mode = resource["mode"] as? String, ["data", "managed"].contains(mode),
                      let instances = resource["instances"] as? [[String: Any]] else {
                    throw ResourceMapError.invalidResource
                }
                let module = resource["module"] as? String ?? ""
                let prefix = module.isEmpty ? "" : module + "."
                let base = prefix + (mode == "data" ? "data." : "") + type + "." + name
                for instance in instances {
                    // Deposed instances are old objects awaiting destruction, not current resources.
                    guard instance["deposed"] == nil else { continue }
                    var address = base
                    if let key = instance["index_key"] {
                        guard key is String || key is NSNumber,
                              !(key is NSNumber && CFGetTypeID(key as CFTypeRef) == CFBooleanGetTypeID()) else {
                            throw ResourceMapError.invalidResource
                        }
                        let encoded = try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .sortedKeys])
                        address += "[" + String(decoding: encoded, as: UTF8.self) + "]"
                    }
                    let dependencies = try dependencies(in: instance)
                    result.append(MapResource(address: address, type: type, name: name, module: module,
                                              isData: mode == "data", dependencies: dependencies))
                }
            }
        } else if root["format_version"] is String, let values = root["values"] as? [String: Any] {
            func walk(_ module: [String: Any]) throws {
                let path = module["address"] as? String ?? ""
                if let value = module["resources"], !(value is [[String: Any]]) { throw ResourceMapError.invalidResource }
                if let value = module["child_modules"], !(value is [[String: Any]]) { throw ResourceMapError.invalidResource }
                for resource in module["resources"] as? [[String: Any]] ?? [] {
                    guard let address = resource["address"] as? String,
                          let type = resource["type"] as? String, let name = resource["name"] as? String,
                          let mode = resource["mode"] as? String, ["data", "managed"].contains(mode) else {
                        throw ResourceMapError.invalidResource
                    }
                    result.append(MapResource(address: address, type: type, name: name, module: path,
                                              isData: mode == "data", dependencies: []))
                }
                for child in module["child_modules"] as? [[String: Any]] ?? [] { try walk(child) }
            }
            if let value = values["root_module"], !(value is [String: Any]) { throw ResourceMapError.invalidState }
            if let module = values["root_module"] as? [String: Any] { try walk(module) }
        } else if root["format_version"] is String,
                  root.keys.allSatisfy({ ["format_version", "terraform_version"].contains($0) }) {
            // Terraform emits metadata alone before the first state exists.
        } else {
            throw ResourceMapError.invalidState
        }
        var seen = Set<String>()
        for resource in result {
            guard seen.insert(resource.address).inserted else { throw ResourceMapError.duplicateAddress(resource.address) }
        }
        return result.sorted { $0.address < $1.address }
    }

    private static func dependencies(in instance: [String: Any]) throws -> [String] {
        guard let value = instance["dependencies"] else { return [] }
        guard let dependencies = value as? [String] else { throw ResourceMapError.invalidResource }
        return dependencies.sorted()
    }
}

struct ResourceMapClassifier {
    var categories: [String: String] = ResourceMapCategories.values

    func kind(for type: String) -> MapKind {
        if type.hasPrefix("aws_cloudwatch_event_") || type.hasPrefix("aws_chatbot_") { return .messaging }
        if type.hasPrefix("kubernetes_") || type.hasPrefix("helm_") { return .appsAndAI }
        if type.range(of: #"^google_compute_(url_map|target_https?_proxy|global_forwarding_rule|forwarding_rule|backend_service|ssl_certificate|managed_ssl)"#, options: .regularExpression) != nil { return .frontDoor }
        if type.range(of: #"^google_compute_(network|subnetwork|firewall|router|route|global_address|address)|^aws_(security_group|network_acl|vpc_endpoint)"#, options: .regularExpression) != nil { return .network }
        if type.range(of: #"^aws_(lb|alb)(_|$)"#, options: .regularExpression) != nil { return .frontDoor }
        let category = categories[type] ?? ""
        let groups: [(MapKind, [String])] = [
            (.frontDoor, ["Route 53", "CloudFront", "ELB", "API Gateway", "WAF", "ACM", "Global Accelerator", "Cloud DNS", "Front Door", "DNS", "Application Gateway", "CDN"]),
            (.messaging, ["SQS", "SNS", "EventBridge", "Kinesis", "SES", "Pinpoint", "SFN", "Step Functions", "Pub/Sub", "Cloud Tasks", "Cloud Scheduler", "Messaging", "MQ", "End User Messaging"]),
            (.network, ["VPC", "Transit Gateway", "Direct Connect", "VPN", "Network Firewall", "Network", "Cloud NAT"]),
            (.identityAndMonitoring, ["IAM", "KMS", "Secrets Manager", "SSM", "Secret Manager", "Cloud IAM", "Key Vault", "Authorization", "Resource Manager", "Cloud Platform", "Organizations", "Shield", "CloudWatch", "X-Ray", "Logging", "Monitoring", "Security Hub", "GuardDuty", "CloudTrail", "Config", "Inspector"]),
            (.data, ["RDS", "DynamoDB", "S3 (", "ElastiCache", "OpenSearch", "Redshift", "Glue", "Athena", "EFS", "BigQuery", "Cloud SQL", "Cloud Storage", "Spanner", "Firestore", "Memorystore", "Database", "Storage", "CosmosDB", "Backup", "QuickSight", "DocumentDB", "MemoryDB", "Lake Formation"]),
            (.appsAndAI, ["EC2 (Elastic", "ECS", "EKS", "Lambda", "App Runner", "Batch", "Elastic Beanstalk", "Bedrock", "SageMaker", "Cloud Run", "Cloud Functions", "Kubernetes (Container)", "Container", "App Service", "Compute", "Cognito", "Chatbot", "Lightsail", "ECR", "CodePipeline", "CodeBuild", "CodeDeploy", "CodeStar", "Artifact Registry", "Cloud Build"])
        ]
        for (kind, prefixes) in groups where prefixes.contains(where: { category.hasPrefix($0) }) { return kind }
        let tokens = Set(type.split(separator: "_").dropFirst().map(String.init))
        if !tokens.isDisjoint(with: ["db", "database", "bucket"]) { return .data }
        if !tokens.isDisjoint(with: ["queue", "topic"]) { return .messaging }
        if tokens.contains("lb") { return .frontDoor }
        return .other
    }

    func classify(_ input: [MapResource]) throws -> ResourceMap {
        let all = input.sorted { $0.address < $1.address }
        var by: [String: MapResource] = [:]
        for resource in all {
            guard by.updateValue(resource, forKey: resource.address) == nil else {
                throw ResourceMapError.duplicateAddress(resource.address)
            }
        }
        let resources = all.filter { !$0.isData }
        let managed = Set(resources.map(\.address))
        let kinds = Dictionary(uniqueKeysWithValues: Set(resources.map(\.type)).map { ($0, kind(for: $0)) })
        func resourceKind(_ resource: MapResource) -> MapKind { kinds[resource.type] ?? .other }
        // State dependencies may name a resource block rather than an instance.
        // Strip only the final instance key; module instance boundaries stay intact.
        func block(_ resource: MapResource) -> String {
            (resource.module.isEmpty ? "" : resource.module + ".") + resource.type + "." + resource.name
        }
        let blocks = Dictionary(grouping: resources, by: block)
        var refs: [String: Set<String>] = [:]
        var neighbors: [String: Set<String>] = [:]
        for resource in resources {
            for dependency in resource.dependencies {
                let targets = managed.contains(dependency) ? [dependency] : (blocks[dependency] ?? []).map(\.address)
                for target in targets where target != resource.address {
                    refs[resource.address, default: []].insert(target)
                    neighbors[resource.address, default: []].insert(target)
                    neighbors[target, default: []].insert(resource.address)
                }
            }
        }
        var facets: [String: String] = [:]
        for resource in resources {
            let parents = (refs[resource.address] ?? []).compactMap { by[$0] }.filter {
                resource.type.hasPrefix($0.type + "_")
            }.sorted { $0.type.count == $1.type.count ? $0.address < $1.address : $0.type.count > $1.type.count }
            facets[resource.address] = parents.first?.address
        }
        func helper(_ resource: MapResource) -> Bool {
            resourceKind(resource) == .identityAndMonitoring || facets[resource.address] != nil ||
            resource.type.range(of: #"(_policy_attachment|_role_policy|_iam_|^aws_iam|_security_group_rule|^aws_security_group$|_subnet_group|_parameter_group|_log_group|_metric_alarm|_route_table_association|_secret_version|_public_access_block|_ownership_controls|_server_side_encryption|_versioning|_lifecycle_configuration|_event_target|_subscription|_permission$|_listener_rule|_target_group_attachment|^aws_route53_record|_kms_|_policy$)"#, options: .regularExpression) != nil
        }
        let anchors = resources.filter { !helper($0) }
        let anchorIDs = Set(anchors.map(\.address))
        var owner: [String: String] = [:]
        for resource in resources where !anchorIDs.contains(resource.address) {
            var parent = facets[resource.address]
            var visited = Set<String>()
            while let candidate = parent, visited.insert(candidate).inserted {
                if anchorIDs.contains(candidate) { owner[resource.address] = candidate; break }
                parent = facets[candidate]
            }
            if owner[resource.address] != nil { continue }
            var frontier: Set<String> = [resource.address]
            visited = frontier
            for _ in 0..<3 {
                let next = Set(frontier.flatMap { neighbors[$0] ?? [] }).subtracting(visited)
                let candidates = next.intersection(anchorIDs).sorted {
                    let leftLocal = by[$0]?.module == resource.module
                    let rightLocal = by[$1]?.module == resource.module
                    return leftLocal == rightLocal ? $0 < $1 : leftLocal
                }
                if let candidate = candidates.first { owner[resource.address] = candidate; break }
                visited.formUnion(next)
                frontier = next
            }
        }
        var parent = Dictionary(uniqueKeysWithValues: anchors.map { ($0.address, $0.address) })
        func find(_ value: String) -> String {
            var key = value
            while let next = parent[key], next != key { key = next }
            return key
        }
        func union(_ a: String, _ b: String) {
            let left = find(a), right = find(b)
            parent[max(left, right)] = min(left, right)
        }
        var stems: [String: String] = [:]
        for resource in anchors {
            let words = resource.name.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
            // Single generic names (this/main/default) are not semantic groups.
            let stem = words.count >= 2 ? words.prefix(2).joined(separator: "_") : resource.name
            let key = resource.module + "|" + String(resourceKind(resource).rawValue) + "|" + stem
            if words.count >= 2, let previous = stems[key] { union(resource.address, previous) }
            if words.count >= 2 { stems[key] = resource.address }
            // Count and for_each copies form one stack, even with a generic name.
            let instanceKey = "instance|" + block(resource)
            if let previous = stems[instanceKey] { union(resource.address, previous) }
            stems[instanceKey] = resource.address
            for target in refs[resource.address] ?? [] where anchorIDs.contains(target) {
                guard let other = by[target], other.module == resource.module,
                      resourceKind(other) == resourceKind(resource),
                      let category = categories[resource.type], !category.isEmpty,
                      category == categories[other.type] else { continue }
                union(resource.address, target)
            }
        }
        var groups: [String: [String]] = [:]
        var anchorGroups: [String: [String]] = [:]
        for resource in anchors {
            let id = find(resource.address)
            groups[id, default: []].append(resource.address)
            anchorGroups[id, default: []].append(resource.address)
        }
        for resource in resources where !anchorIDs.contains(resource.address) {
            let id = owner[resource.address].map(find) ?? resource.address
            groups[id, default: []].append(resource.address)
        }
        let tiles: [MapTile] = groups.map { id, members in
            let anchorMembers = (anchorGroups[id] ?? []).sorted()
            let resource = by[id]!
            let words = resource.name.replacingOccurrences(of: "-", with: "_").split(separator: "_")
            let title = words.map { String($0).capitalized }.joined(separator: " ")
            return MapTile(id: id, title: title, kind: anchorMembers.isEmpty ? .identityAndMonitoring : resourceKind(resource),
                           anchors: anchorMembers, resources: members.sorted())
        }.sorted { $0.kind == $1.kind ? $0.id < $1.id : $0.kind.rawValue < $1.kind.rawValue }
        let tileForResource = Dictionary(uniqueKeysWithValues: tiles.flatMap { tile in tile.resources.map { ($0, tile.id) } })
        var connections = Set<MapConnection>()
        for (source, targets) in refs {
            for target in targets {
                if let a = tileForResource[source], let b = tileForResource[target], a != b {
                    connections.insert(MapConnection(source: a, target: b))
                }
            }
        }
        let workspaceData = all.filter {
            $0.isData && ["terraform_remote_state", "tfe_outputs"].contains($0.type)
        }
        func workspaceBlock(_ resource: MapResource) -> String {
            (resource.module.isEmpty ? "" : resource.module + ".") + "data." + resource.type + "." + resource.name
        }
        let workspaceByAddress = Dictionary(uniqueKeysWithValues: workspaceData.map { ($0.address, $0) })
        let workspaceByBlock = Dictionary(grouping: workspaceData, by: workspaceBlock)
        var consumersByWorkspace: [String: Set<String>] = [:]
        for resource in resources {
            guard let consumerTile = tileForResource[resource.address] else { continue }
            for dependency in resource.dependencies {
                var matches: [MapResource] = []
                if let exact = workspaceByAddress[dependency] { matches.append(exact) }
                matches.append(contentsOf: workspaceByBlock[dependency] ?? [])
                for match in matches {
                    consumersByWorkspace[match.address, default: []].insert(consumerTile)
                }
            }
        }
        let workspaceReferences = workspaceData.map { resource in
            MapWorkspaceReference(address: resource.address, name: resource.name,
                                  consumers: (consumersByWorkspace[resource.address] ?? []).sorted())
        }.sorted { $0.address < $1.address }
        return ResourceMap(tiles: tiles, connections: connections.sorted {
            $0.source == $1.source ? $0.target < $1.target : $0.source < $1.source
        }, dataSources: all.filter(\.isData).map(\.address), workspaceReferences: workspaceReferences)
    }
}
