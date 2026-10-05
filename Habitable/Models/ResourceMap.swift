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
    /// Optional recognizable name read from non-sensitive state (see `stateIdentity`).
    let identity: String?

    init(address: String, type: String, name: String, module: String = "",
         isData: Bool = false, dependencies: [String] = [], identity: String? = nil) {
        self.identity = identity
        self.address = address
        self.type = type
        self.name = name
        self.module = module
        self.isData = isData
        self.dependencies = dependencies
    }
}

extension MapResource {
    /// Recognizable name for a resource type from non-sensitive attributes, or nil.
    /// `attribute(key, index)` returns a top-level string attribute (index nil) or the
    /// string at `key[index]`; it must already apply redaction and return nil for
    /// sensitive, null or empty values.
    static func stateIdentity(type: String, attribute: (String, Int?) -> String?) -> String? {
        var value: String?
        switch type {
        case "aws_route53_zone":
            value = attribute("name", nil).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        case "aws_route53_record": value = attribute("name", nil)
        case "aws_acm_certificate": value = attribute("domain_name", nil)
        case "aws_cloudfront_distribution": value = attribute("aliases", 0) ?? attribute("domain_name", nil)
        case "aws_s3_bucket": value = attribute("bucket", nil)
        case "aws_ses_domain_identity": value = attribute("domain", nil)
        case "aws_key_pair": value = attribute("key_name", nil)
        case "aws_db_instance": value = attribute("identifier", nil)
        case "aws_elasticache_replication_group": value = attribute("replication_group_id", nil)
        case "aws_elasticache_cluster": value = attribute("cluster_id", nil)
        case "github_repository": value = attribute("full_name", nil) ?? attribute("name", nil)
        case "github_team": value = attribute("name", nil)
        case "datadog_monitor", "datadog_dashboard", "datadog_service_level_objective", "datadog_synthetics_test":
            value = attribute("name", nil)
        default: return nil
        }
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 48, trimmed != "(sensitive value)", trimmed != "null",
              !trimmed.contains(where: { $0.isNewline }) else { return nil }
        return trimmed
    }
}

enum MapKind: Int, CaseIterable, Sendable {
    case frontDoor, appsAndAI, code, messaging, data, network, identityAndMonitoring, other
}

struct MapTile: Equatable, Sendable {
    /// Stable Terraform address, independent of collection order and display name.
    let id: String
    let title: String
    let kind: MapKind
    let anchors: [String]
    let resources: [String]
}

enum MapConnectionRelationship: Equatable, Hashable, Sendable {
    /// The source tile contains a resource that depends on the target tile.
    case dependency
    /// Different resources in the two tiles depend on each other across the group boundary.
    /// This is a grouped relationship and does not imply a resource-level cycle.
    case mixed
}

struct MapConnectionEvidence: Equatable, Hashable, Sendable {
    /// Terraform resource address that declares the dependency.
    let sourceResource: String
    /// Terraform resource address that it depends on.
    let targetResource: String
}

struct MapConnection: Equatable, Hashable, Sendable {
    let source: String
    let target: String
    let relationship: MapConnectionRelationship
    let evidence: [MapConnectionEvidence]

    init(source: String, target: String,
         relationship: MapConnectionRelationship = .dependency,
         evidence: [MapConnectionEvidence] = []) {
        self.source = source
        self.target = target
        self.relationship = relationship
        self.evidence = evidence
    }
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
        let minimumWidth = 580.0
        let tileWidth = 240.0
        let tileHeight = 112.0
        let horizontalInset = 28.0
        let tileGap = 44.0
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

        let kinds = MapKind.allCases.filter { !(groupedTiles[$0] ?? []).isEmpty }
        for (bandIndex, kind) in kinds.enumerated() {
            let orderedTiles = Self.orderedTiles(groupedTiles[kind] ?? [], connections: map.connections)
            let rowCount = (orderedTiles.count + columns - 1) / columns
            let bandHeight = topPadding + Double(rowCount) * tileHeight + Double(max(0, rowCount - 1)) * rowGap + bottomPadding
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
        for connection in connections where connection.relationship == .dependency &&
            byID[connection.source] != nil && byID[connection.target] != nil {
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

    /// Identity and monitoring resources usually support an application, but
    /// for GitHub and Datadog workspaces these are the product itself, so they
    /// anchor their own tiles instead of folding into a neighbor.
    static let primaryIdentityAndMonitoringTypes: Set<String> = [
        "github_team",
        "datadog_monitor", "datadog_monitor_json", "datadog_dashboard", "datadog_dashboard_json",
        "datadog_service_level_objective", "datadog_synthetics_test",
        "datadog_security_monitoring_rule", "datadog_team"
    ]
    /// Providers whose helpers commonly reuse their anchor's block name instead
    /// of referencing it (for example `repository = "rookery"`).
    static let nameOwnedProviders: Set<String> = ["github", "datadog"]

    func kind(for type: String) -> MapKind {
        // Auto Scaling groups are compute workloads; their launch-template and
        // IAM/network support resources should collect around the group.
        if type == "aws_autoscaling_group" { return .appsAndAI }
        if type == "aws_eip" { return .network }
        if type.hasPrefix("aws_cloudwatch_event_") || type.hasPrefix("aws_chatbot_") { return .messaging }
        if type.hasPrefix("kubernetes_") || type.hasPrefix("helm_") { return .appsAndAI }
        // GitHub repositories and their settings are code; teams, members and
        // organization settings are identity. Datadog is monitoring throughout.
        if type.hasPrefix("github_") {
            return type.range(of: #"^github_(team($|_)|membership$|organization|user_|enterprise|emu_|actions_organization_)"#, options: .regularExpression) != nil
                ? .identityAndMonitoring : .code
        }
        if type.hasPrefix("datadog_") { return .identityAndMonitoring }
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
            if Self.primaryIdentityAndMonitoringTypes.contains(resource.type) { return facets[resource.address] != nil }
            return resourceKind(resource) == .identityAndMonitoring || facets[resource.address] != nil ||
            resource.type.range(of: #"^github_(branch|repository_|actions_(secret|variable|environment)|issue_label)|(_policy_attachment|_role_policy|_iam_|^aws_iam|_security_group_rule|^aws_security_group$|_launch_template|_subnet_group|_parameter_group|_log_group|_metric_alarm|_route_table_association|_secret_version|_public_access_block|_ownership_controls|_server_side_encryption|_versioning|_lifecycle_configuration|_event_target|_subscription|_permission$|_listener_rule|_target_group_attachment|^aws_route53_record|_kms_|_policy$)"#, options: .regularExpression) != nil
        }
        let anchors = resources.filter { !helper($0) }
        let anchorIDs = Set(anchors.map(\.address))
        let anchorsByName = Dictionary(grouping: anchors) { $0.module + "|" + $0.name }
        func provider(_ type: String) -> String { String(type.prefix { $0 != "_" }) }
        var owner: [String: String] = [:]
        func semanticFamily(_ resource: MapResource) -> String {
            let category = categories[resource.type] ?? ""
            if !category.isEmpty { return category }
            if resource.type.contains("subnet_group") { return "database-subnet" }
            if resource.type.contains("launch_template") { return "compute-template" }
            if resource.type.contains("security_group") { return "network-security" }
            return resource.type.components(separatedBy: "_").dropFirst().prefix(2).joined(separator: "_")
        }
        for resource in resources where !anchorIDs.contains(resource.address) {
            var parent = facets[resource.address]
            var visited = Set<String>()
            while let candidate = parent, visited.insert(candidate).inserted {
                if anchorIDs.contains(candidate) { owner[resource.address] = candidate; break }
                parent = facets[candidate]
            }
            if owner[resource.address] != nil { continue }
            // Prefer a directly consuming workload with a related service
            // family. In particular subnet groups belong to the DB/cache that
            // references them, even when another application is nearby.
            let directOwners = (neighbors[resource.address] ?? []).intersection(anchorIDs).sorted()
            let family = semanticFamily(resource)
            if let preferred = directOwners.first(where: {
                guard let candidate = by[$0] else { return false }
                let candidateFamily = semanticFamily(candidate)
                return !family.isEmpty && (candidateFamily == family ||
                    (resource.type.contains("launch_template") && candidate.type == "aws_autoscaling_group") ||
                    (resource.type.contains("subnet_group") && candidate.type.range(of: #"(db_instance|db_cluster|elasticache_cluster|docdb_cluster|rds_cluster)"#, options: .regularExpression) != nil))
            }) {
                owner[resource.address] = preferred
                continue
            }
            var frontier: Set<String> = [resource.address]
            visited = frontier
            for _ in 0..<3 {
                let next = Set(frontier.flatMap { neighbors[$0] ?? [] }).subtracting(visited)
                let candidates = next.intersection(anchorIDs).sorted {
                    let leftLocal = by[$0]?.module == resource.module
                    let rightLocal = by[$1]?.module == resource.module
                    let leftFamily = by[$0].map(semanticFamily) == family
                    let rightFamily = by[$1].map(semanticFamily) == family
                    if leftFamily != rightFamily { return leftFamily }
                    return leftLocal == rightLocal ? $0 < $1 : leftLocal
                }
                if let candidate = candidates.first { owner[resource.address] = candidate; break }
                visited.formUnion(next)
                frontier = next
            }
            if owner[resource.address] != nil { continue }
            // Without a reference, fall back to the one same-provider, same-kind
            // anchor sharing this block name. Ambiguous names stay separate.
            let resourceProvider = provider(resource.type)
            guard Self.nameOwnedProviders.contains(resourceProvider) else { continue }
            let sameName = (anchorsByName[resource.module + "|" + resource.name] ?? []).filter {
                provider($0.type) == resourceProvider && resourceKind($0) == resourceKind(resource)
            }
            if sameName.count == 1 { owner[resource.address] = sameName[0].address }
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
                      resourceKind(other) == resourceKind(resource) else { continue }
                let category = categories[resource.type] ?? ""
                let sameCategory = !category.isEmpty && category == categories[other.type]
                // An SLO and the monitors it measures are one service objective.
                // Dashboards only connect to monitors; they often show many.
                let objective = resource.type == "datadog_service_level_objective" && other.type.hasPrefix("datadog_monitor")
                guard sameCategory || objective else { continue }
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
        func shortService(_ type: String) -> String {
            switch type {
            case "aws_vpc": return "Network"
            case let value where value.hasPrefix("aws_vpc_"): return "Network"
            case let value where value.hasPrefix("aws_acm_"): return "Certificate"
            case let value where value.hasPrefix("aws_cloudfront_"): return "CDN"
            case let value where value.hasPrefix("aws_route53_"): return "DNS"
            case let value where value.hasPrefix("aws_ses_"):
                return value.contains("configuration_set") ? "SES configuration set" : "SES domain"
            case let value where value.hasPrefix("aws_s3_"): return "Bucket"
            case "aws_internet_gateway", "aws_route_table", "aws_subnet", "aws_security_group", "aws_network_acl", "aws_eip", "aws_nat_gateway": return "Network"
            case "aws_key_pair": return "SSH key"
            case "github_repository": return "Repository"
            case "github_team": return "Team"
            case "datadog_monitor", "datadog_monitor_json": return "Monitor"
            case "datadog_dashboard", "datadog_dashboard_json": return "Dashboard"
            case "datadog_service_level_objective": return "SLO"
            case "datadog_synthetics_test": return "Synthetic test"
            default: return categories[type] ?? ""
            }
        }
        let titleCounts = Dictionary(grouping: groups.keys.compactMap { id -> (String, String)? in
            guard let resource = by[id] else { return nil }
            let plain = resource.name.replacingOccurrences(of: "-", with: "_").split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
            return (plain, id)
        }, by: { $0.0 }).mapValues(\.count)
        func plain(_ resource: MapResource) -> String {
            resource.name.replacingOccurrences(of: "-", with: "_").split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
        }
        var identityTitleCounts: [String: Int] = [:]
        for id in groups.keys {
            guard let resource = by[id], (titleCounts[plain(resource)] ?? 0) > 1, let identity = resource.identity,
                  identity.lowercased() != plain(resource).lowercased() else { continue }
            identityTitleCounts[identity.lowercased(), default: 0] += 1
        }
        let tiles: [MapTile] = groups.map { id, members in
            let anchorMembers = (anchorGroups[id] ?? []).sorted()
            let resource = by[id]!
            let words = resource.name.replacingOccurrences(of: "-", with: "_").split(separator: "_")
            let plainTitle = words.map { String($0).capitalized }.joined(separator: " ")
            let service = shortService(resource.type)
            let collides = (titleCounts[plainTitle] ?? 0) > 1
            var title = collides && !service.isEmpty ? "\(plainTitle) · \(service)" : plainTitle
            if collides, let identity = resource.identity, identity.lowercased() != plainTitle.lowercased() { title = identity }
            return MapTile(id: id, title: title, kind: anchorMembers.isEmpty ? .identityAndMonitoring : resourceKind(resource),
                           anchors: anchorMembers, resources: members.sorted())
        }.map { tile -> MapTile in
            // Two tiles can share one identity (a zone and its certificate); qualify those.
            guard let resource = by[tile.id], let identity = resource.identity, tile.title == identity,
                  (identityTitleCounts[identity.lowercased()] ?? 0) > 1 else { return tile }
            let service = shortService(resource.type)
            return service.isEmpty ? tile : MapTile(id: tile.id, title: "\(identity) · \(service)", kind: tile.kind,
                                                    anchors: tile.anchors, resources: tile.resources)
        }.sorted { $0.kind == $1.kind ? $0.id < $1.id : $0.kind.rawValue < $1.kind.rawValue }
        let tileForResource = Dictionary(uniqueKeysWithValues: tiles.flatMap { tile in tile.resources.map { ($0, tile.id) } })
        var evidenceByPair: [String: [MapConnectionEvidence]] = [:]
        var pairEndpoints: [String: (String, String)] = [:]
        for (source, targets) in refs {
            for target in targets {
                if let a = tileForResource[source], let b = tileForResource[target], a != b {
                    let first = min(a, b), second = max(a, b)
                    let key = first + "\u{0}" + second
                    pairEndpoints[key] = (first, second)
                    evidenceByPair[key, default: []].append(
                        MapConnectionEvidence(sourceResource: source, targetResource: target))
                }
            }
        }
        let connections = evidenceByPair.compactMap { key, evidence -> MapConnection? in
            guard let (first, second) = pairEndpoints[key] else { return nil }
            let orderedEvidence = evidence.sorted {
                $0.sourceResource == $1.sourceResource
                    ? $0.targetResource < $1.targetResource
                    : $0.sourceResource < $1.sourceResource
            }
            let hasFirstToSecond = orderedEvidence.contains {
                tileForResource[$0.sourceResource] == first && tileForResource[$0.targetResource] == second
            }
            let hasSecondToFirst = orderedEvidence.contains {
                tileForResource[$0.sourceResource] == second && tileForResource[$0.targetResource] == first
            }
            guard hasFirstToSecond || hasSecondToFirst else { return nil }
            let relationship: MapConnectionRelationship = hasFirstToSecond && hasSecondToFirst ? .mixed : .dependency
            let source: String
            let target: String
            if relationship == .mixed || hasFirstToSecond {
                source = first
                target = second
            } else {
                source = second
                target = first
            }
            return MapConnection(source: source, target: target,
                                 relationship: relationship, evidence: orderedEvidence)
        }.sorted {
            $0.source == $1.source ? $0.target < $1.target : $0.source < $1.source
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
        return ResourceMap(tiles: tiles, connections: connections,
                           dataSources: all.filter(\.isData).map(\.address), workspaceReferences: workspaceReferences)
    }
}
