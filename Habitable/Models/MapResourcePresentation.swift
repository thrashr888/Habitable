import Foundation

struct MapResourceFact: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct MapResourceEndpoint: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    let url: URL?
}

struct MapResourcePresentation: Equatable, Sendable {
    let subtitle: String
    let facts: [MapResourceFact]
    let endpoints: [MapResourceEndpoint]

    static func summarize(tile: MapTile, resources: [MapDisplayResource]) -> MapResourcePresentation {
        var seen = Set<String>()
        let addresses = (tile.anchors + tile.resources).filter { seen.insert($0).inserted }
        let members = addresses.compactMap { address in resources.first { $0.address == address } }
        let anchor = tile.anchors.enumerated().compactMap { index, address in
            resources.first { $0.address == address }.map { (index, $0) }
        }.min { lhs, rhs in
            let left = anchorPriority(lhs.1.type), right = anchorPriority(rhs.1.type)
            return left == right ? lhs.0 < rhs.0 : left < right
        }?.1
        var facts: [MapResourceFact] = []
        var endpoints: [MapResourceEndpoint] = []
        for resource in members {
            let schema = schema(for: resource.type)
            for field in schema.facts {
                if let value = attribute(field.path, in: resource), !isRedactedOrEmpty(value) {
                    let rendered = factValue(field.path, value: value)
                    facts.append(MapResourceFact(id: "\(resource.address):\(field.path)", label: field.label, value: rendered))
                }
            }
            if resource.type == "aws_db_instance", let status = attribute("status", in: resource), !isRedactedOrEmpty(status) {
                facts.append(MapResourceFact(id: "\(resource.address):recorded-status", label: "Last recorded status", value: status))
            }
            for field in schema.endpoints {
                if let value = attribute(field.path, in: resource), !isRedactedOrEmpty(value) {
                    let url = validatedWebURL(value)
                    endpoints.append(MapResourceEndpoint(id: "\(resource.address):\(field.path)", label: field.label,
                                                         value: value, url: url))
                }
            }
        }
        let subtitle: String
        if let anchor {
            let values = schema(for: anchor.type).facts.compactMap { field -> (String, String)? in
                guard let value = attribute(field.path, in: anchor), !isRedactedOrEmpty(value) else { return nil }
                return (field.path, value)
            }
            subtitle = serviceSubtitle(for: anchor.type, values: values)
        } else {
            // No recorded anchor (a planned tile, or one outside the known schemas):
            // name the resource types rather than repeat the card's own count line.
            var types: [String] = []
            for address in addresses {
                let type = resources.first { $0.address == address }?.type ?? resourceType(inAddress: address)
                if let type, !types.contains(type) { types.append(type) }
            }
            subtitle = types.count <= 2 ? types.joined(separator: ", ")
                : types.prefix(2).joined(separator: ", ") + " and \(types.count - 2) more"
        }
        return MapResourcePresentation(subtitle: subtitle, facts: facts, endpoints: endpoints)
    }

    /// The resource type in an address such as `module.a.aws_instance.web[0]`.
    static func resourceType(inAddress address: String) -> String? {
        var parts = address.split(separator: ".").map(String.init)
        if let last = parts.last, let bracket = last.firstIndex(of: "[") { parts[parts.count - 1] = String(last[..<bracket]) }
        // Strip module prefixes and an index on each module segment.
        while parts.count > 2, parts[0] == "module" { parts.removeFirst(2) }
        if parts.first == "data" { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2]
    }

    private static func schema(for type: String) -> (facts: [(path: String, label: String)], endpoints: [(path: String, label: String)]) {
        switch type {
        case "aws_db_instance":
            return ([ ("engine", "Engine"), ("engine_version", "Version"), ("instance_class", "Class"), ("allocated_storage", "Storage"),
                      ("storage_encrypted", "Storage encryption"), ("multi_az", "Availability"), ("availability_zone", "Availability zone"),
                      ("backup_retention_period", "Backup retention"), ("backup_window", "Backup window"),
                      ("deletion_protection", "Deletion protection") ], [("address", "Database address")])
        case "aws_elasticache_cluster", "aws_elasticache_replication_group":
            return ([ ("engine", "Engine"), ("engine_version", "Version"), ("node_type", "Node type"), ("num_cache_nodes", "Cache nodes"),
                      ("at_rest_encryption_enabled", "At-rest encryption"), ("transit_encryption_enabled", "Transit encryption") ], [("primary_endpoint_address", "Primary endpoint")])
        case "aws_autoscaling_group":
            return ([ ("min_size", "Minimum"), ("max_size", "Maximum"), ("desired_capacity", "Desired") ], [])
        case "aws_instance": return ([("instance_type", "Instance type"), ("availability_zone", "Availability zone"), ("private_ip", "Private IP"), ("public_ip", "Public IP")], [])
        case "aws_s3_bucket": return ([("bucket", "Bucket"), ("region", "Region"), ("object_lock_enabled", "Object lock")], [("website_endpoint", "Website")])
        case "aws_cloudfront_distribution": return ([("enabled", "Enabled"), ("price_class", "Price class")], [("domain_name", "Domain")])
        case "aws_route53_zone": return ([("zone_id", "Zone"), ("private_zone", "Private zone")], [("name", "DNS name")])
        case "aws_vpc": return ([("cidr_block", "CIDR"), ("enable_dns_support", "DNS support"), ("enable_dns_hostnames", "DNS hostnames")], [])
        case "aws_subnet": return ([("cidr_block", "CIDR"), ("availability_zone", "Availability zone"), ("map_public_ip_on_launch", "Public IPs on launch")], [])
        default: return ([], [])
        }
    }

    private static func factValue(_ path: String, value: String) -> String {
        if path == "allocated_storage", Int(value) != nil { return "\(value) GiB" }
        if path == "backup_retention_period", Int(value) != nil { return "\(value) days" }
        if ["storage_encrypted", "at_rest_encryption_enabled", "transit_encryption_enabled"].contains(path) {
            if value == "true" { return "Encrypted" }
            if value == "false" { return "Not encrypted" }
        }
        if path == "multi_az" {
            if value == "true" { return "Multi-AZ" }
            if value == "false" { return "Single-AZ" }
        }
        if ["deletion_protection", "enabled", "private_zone", "object_lock_enabled", "enable_dns_support",
            "enable_dns_hostnames", "map_public_ip_on_launch"].contains(path) {
            if value == "true" { return "Enabled" }
            if value == "false" { return "Disabled" }
        }
        return value
    }

    private static func anchorPriority(_ type: String) -> Int {
        switch type {
        case "aws_vpc": 0
        case "aws_db_instance", "aws_elasticache_replication_group", "aws_autoscaling_group",
             "aws_instance", "aws_s3_bucket", "aws_cloudfront_distribution", "aws_route53_zone",
             "aws_lambda_function", "aws_lb", "aws_ecs_service", "aws_sqs_queue", "aws_sns_topic": 1
        case "aws_ses_domain_identity": 1
        case "aws_internet_gateway", "aws_route_table", "aws_subnet", "aws_network_acl": 20
        case "aws_ses_domain_dkim", "aws_ses_domain_identity_verification": 20
        default: 10
        }
    }

    private static func serviceSubtitle(for type: String, values: [(String, String)]) -> String {
        let value = Dictionary(values, uniquingKeysWith: { first, _ in first })
        func get(_ key: String) -> String? { value[key] }
        switch type {
        case "aws_db_instance":
            return ["RDS", get("engine")?.capitalized].compactMap { $0 }.joined(separator: " · ")
        case "aws_elasticache_cluster", "aws_elasticache_replication_group":
            return ["ElastiCache", get("engine")?.capitalized].compactMap { $0 }.joined(separator: " · ")
        case "aws_autoscaling_group":
            return get("desired_capacity").map { "Auto Scaling · \($0) desired" } ?? "Auto Scaling"
        case "aws_instance":
            return get("instance_type").map { "EC2 · \($0)" } ?? "EC2 instance"
        case "aws_s3_bucket": return "S3 bucket"
        case "aws_cloudfront_distribution": return "CloudFront distribution"
        case "aws_route53_zone": return "Route 53 zone"
        case "aws_vpc": return get("cidr_block").map { "VPC · \($0)" } ?? "VPC"
        default: return readableType(type)
        }
    }

    private static func attribute(_ key: String, in resource: MapDisplayResource) -> String? {
        let encoded = (try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(key)\""
        return resource.displayAttributes.first { $0.path == encoded }?.value
    }

    private static func isRedactedOrEmpty(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value == "(sensitive value)" || value == "null" || value == "{}" || value == "[]"
    }

    private static func validatedWebURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    private static func readableType(_ type: String) -> String {
        switch type {
        case "aws_acm_certificate": return "ACM certificate"
        case "aws_ses_email_identity", "aws_ses_domain_identity": return "SES identity"
        case "aws_eip": return "Elastic IP"
        case "aws_key_pair": return "EC2 key pair"
        default: break
        }
        let name = type.hasPrefix("aws_") ? String(type.dropFirst(4)) : type
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
