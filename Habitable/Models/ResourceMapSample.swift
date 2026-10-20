import Foundation

enum ResourceMapSample {
    static var referenceRawState: [String: Any] {
        func dataSource(_ type: String, _ name: String) -> [String: Any] {
            ["mode": "data", "type": type, "name": name, "instances": [["attributes": [:]]]]
        }
        func managed(_ type: String, _ name: String, _ values: [[String: Any]],
                     _ dependencies: [String] = [], indexed: Bool = false) -> [String: Any] {
            let instances = values.enumerated().map { index, attributes -> [String: Any] in
                var instance: [String: Any] = ["attributes": attributes, "dependencies": dependencies]
                if indexed { instance["index_key"] = index }
                return instance
            }
            return ["mode": "managed", "type": type, "name": name, "instances": instances]
        }

        return ["version": 4, "resources": [
            dataSource("terraform_remote_state", "cluster"),
            dataSource("terraform_remote_state", "vpc"),
            dataSource("terraform_remote_state", "root_dns"),
            managed("aws_bedrock_model_invocation_logging_configuration", "bedrock_logging", [
                ["id": "bedrock-logging-0", "logging_config": ["cloudwatch_config": ["log_group_name": "/aws/bedrock/reference"]]],
                ["id": "bedrock-logging-1", "logging_config": ["cloudwatch_config": ["log_group_name": "/aws/bedrock/reference"]]]
            ], ["data.terraform_remote_state.cluster", "data.terraform_remote_state.vpc", "aws_iam_role.bedrock_logging"], indexed: true),
            managed("aws_cloudwatch_event_rule", "service_health_alerts", [
                ["name": "service-health-alerts-primary", "event_bus_name": "default", "state": "ENABLED"],
                ["name": "service-health-alerts-secondary", "event_bus_name": "default", "state": "ENABLED"]
            ], ["data.terraform_remote_state.root_dns", "data.terraform_remote_state.vpc", "aws_sns_topic.chat_alerts"], indexed: true),
            managed("aws_sns_topic", "chat_alerts", [
                ["name": "chat-alerts-primary", "display_name": "Chat alerts"],
                ["name": "chat-alerts-secondary", "display_name": "Chat alerts" ]
            ], ["data.terraform_remote_state.root_dns"], indexed: true),
            managed("aws_chatbot_slack_channel_configuration", "slack_alerts_channel", [
                ["configuration_name": "slack-alerts-channel", "slack_channel_id": "C0123456789"]
            ], ["data.terraform_remote_state.cluster", "aws_sns_topic.chat_alerts"]),
            managed("aws_elasticache_replication_group", "chat_redis", [
                ["id": "chat-redis", "engine": "redis", "node_type": "cache.t4g.micro", "num_cache_clusters": 2]
            ], ["data.terraform_remote_state.vpc", "aws_elasticache_subnet_group.chat_redis"]),
            managed("aws_elasticache_serverless_cache", "chat_memcached", [
                ["name": "chat-memcached", "engine": "memcached", "major_engine_version": "1.6"]
            ], ["data.terraform_remote_state.vpc", "aws_iam_role.alerts"]),
            managed("aws_iam_role", "bedrock_logging", [
                ["name": "bedrock-logging-role", "assume_role_policy": "{\"Version\":\"2012-10-17\"}"]
            ], ["data.terraform_remote_state.cluster"]),
            managed("aws_iam_role", "alerts", [
                ["name": "alerts-role", "assume_role_policy": "{\"Version\":\"2012-10-17\"}"]
            ], ["data.terraform_remote_state.cluster"]),
            managed("aws_cloudwatch_log_group", "bedrock_logging", [
                ["name": "/aws/bedrock/reference", "retention_in_days": 30]
            ], ["data.terraform_remote_state.cluster", "aws_bedrock_model_invocation_logging_configuration.bedrock_logging"]),
            managed("aws_cloudwatch_log_group", "service_health_alerts", [
                ["name": "/aws/events/service-health-alerts", "retention_in_days": 30]
            ], ["data.terraform_remote_state.root_dns", "aws_cloudwatch_event_rule.service_health_alerts"]),
            managed("aws_elasticache_subnet_group", "chat_redis", [
                ["name": "chat-redis-subnets", "description": "Chat cache subnets"]
            ], ["data.terraform_remote_state.vpc"])
        ]]
    }

    static var referenceShownState: [String: Any] {
        let resources = (referenceRawState["resources"] as? [[String: Any]] ?? []).flatMap { resource -> [[String: Any]] in
            let type = resource["type"] as? String ?? ""
            let name = resource["name"] as? String ?? ""
            let mode = resource["mode"] as? String ?? "managed"
            let module = resource["module"] as? String ?? ""
            let prefix = module.isEmpty ? "" : module + "."
            let base = prefix + (mode == "data" ? "data." : "") + type + "." + name
            return (resource["instances"] as? [[String: Any]] ?? []).map { instance in
                let key = instance["index_key"]
                let address: String
                if let key, let encoded = try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]),
                   let value = String(data: encoded, encoding: .utf8) {
                    address = base + "[" + value + "]"
                } else {
                    address = base
                }
                let values = instance["attributes"] as? [String: Any] ?? [:]
                return ["address": address, "type": type, "name": name, "mode": mode,
                        "provider_name": "registry.terraform.io/hashicorp/aws",
                        "values": values, "sensitive_values": [String: Any]()]
            }
        }
        return ["format_version": "1.0", "values": ["root_module": ["resources": resources]]]
    }

    static var shownState: [String: Any] {
        let resources = (rawState["resources"] as? [[String: Any]] ?? []).map { resource -> [String: Any] in
            let instance = (resource["instances"] as? [[String: Any]])!.first!
            return ["address": "\(resource["type"]!).\(resource["name"]!)", "type": resource["type"]!,
                    "name": resource["name"]!, "mode": "managed", "provider_name": "registry.terraform.io/hashicorp/aws",
                    "values": instance["attributes"]!, "sensitive_values": instance["sample_sensitive"] ?? [:]]
        }
        return ["format_version": "1.0", "values": ["root_module": ["resources": resources]]]
    }

    static var rawState: [String: Any] {
        func resource(_ type: String, _ name: String, _ attributes: [String: Any],
                      _ dependencies: [String] = [], sensitive: [String: Any] = [:]) -> [String: Any] {
            ["mode": "managed", "type": type, "name": name,
             "instances": [["attributes": attributes, "dependencies": dependencies, "sample_sensitive": sensitive]]]
        }
        return ["version": 4, "resources": [
            resource("aws_lb", "public_entry", ["dns_name": "app.example.test", "load_balancer_type": "application"], ["aws_vpc.main"]),
            resource("aws_ecs_service", "web_service", ["desired_count": 3, "launch_type": "FARGATE"], ["aws_lb.public_entry", "aws_db_instance.orders", "aws_s3_bucket.uploads", "aws_iam_role.web", "aws_vpc.main"]),
            resource("aws_lambda_function", "event_worker", ["runtime": "python3.13", "memory_size": 256], ["aws_sqs_queue.events", "aws_db_instance.orders"]),
            resource("aws_sqs_queue", "events", ["message_retention_seconds": 86400]),
            resource("aws_db_instance", "orders", ["engine": "postgres", "engine_version": "16", "allocated_storage": 100, "multi_az": true, "password": "SAMPLE_SECRET_MUST_STAY_HIDDEN"], ["aws_vpc.main"], sensitive: ["password": true]),
            resource("aws_s3_bucket", "uploads", ["bucket": "acme-uploads-example"]),
            resource("aws_s3_bucket_versioning", "uploads", ["status": "Enabled"], ["aws_s3_bucket.uploads"]),
            resource("aws_vpc", "main", ["cidr_block": "10.0.0.0/16"]),
            resource("aws_iam_role", "web", ["name": "web-task-role"]),
            resource("aws_cloudwatch_log_group", "audit", ["retention_in_days": 30])
        ]]
    }

    // MARK: - acme-platform: a whole product, for the offline sample and screenshots

    /// A storefront on AWS: CDN and DNS in front, two services and a worker,
    /// queues and alerts, a database, cache and buckets, a network, and the
    /// roles and logs that support them. `keeping` returns an earlier revision
    /// with only the first n resources, so time travel has somewhere to go.
    static func platformRawState(keeping: Int? = nil) -> [String: Any] {
        func resource(_ type: String, _ name: String, _ attributes: [String: Any],
                      _ dependencies: [String] = [], sensitive: [String: Any] = [:]) -> [String: Any] {
            ["mode": "managed", "type": type, "name": name,
             "instances": [["attributes": attributes, "dependencies": dependencies, "sample_sensitive": sensitive]]]
        }
        let all: [[String: Any]] = [
            // Network first: the oldest revision was just the VPC.
            resource("aws_vpc", "main", ["cidr_block": "10.20.0.0/16", "enable_dns_hostnames": true]),
            resource("aws_subnet", "public_a", ["cidr_block": "10.20.1.0/24", "availability_zone": "us-west-2a"], ["aws_vpc.main"]),
            resource("aws_subnet", "private_a", ["cidr_block": "10.20.11.0/24", "availability_zone": "us-west-2a"], ["aws_vpc.main"]),
            resource("aws_internet_gateway", "main", ["id": "igw-0a1b2c"], ["aws_vpc.main"]),
            resource("aws_nat_gateway", "a", ["connectivity_type": "public"], ["aws_subnet.public_a", "aws_internet_gateway.main"]),
            resource("aws_security_group", "web", ["name": "web", "description": "HTTPS from the load balancer"], ["aws_vpc.main"]),
            resource("aws_security_group", "data", ["name": "data", "description": "Postgres and Redis from web"], ["aws_vpc.main"]),
            // Data
            resource("aws_db_instance", "orders", ["engine": "postgres", "engine_version": "16.4", "instance_class": "db.r6g.large", "allocated_storage": 200, "multi_az": true, "password": "SAMPLE_SECRET_MUST_STAY_HIDDEN"], ["aws_subnet.private_a", "aws_security_group.data"], sensitive: ["password": true]),
            resource("aws_elasticache_replication_group", "sessions", ["engine": "redis", "node_type": "cache.t4g.medium", "num_cache_clusters": 2], ["aws_subnet.private_a", "aws_security_group.data"]),
            resource("aws_dynamodb_table", "carts", ["billing_mode": "PAY_PER_REQUEST", "hash_key": "cart_id"]),
            resource("aws_s3_bucket", "assets", ["bucket": "acme-assets", "region": "us-west-2"]),
            resource("aws_s3_bucket_versioning", "assets", ["status": "Enabled"], ["aws_s3_bucket.assets"]),
            resource("aws_s3_bucket", "uploads", ["bucket": "acme-uploads", "region": "us-west-2"]),
            // Identity and secrets
            resource("aws_kms_key", "platform", ["description": "acme platform", "enable_key_rotation": true]),
            resource("aws_secretsmanager_secret", "orders_db", ["name": "acme/orders/db"], ["aws_kms_key.platform"]),
            resource("aws_iam_role", "web_task", ["name": "acme-web-task"]),
            resource("aws_iam_role", "worker", ["name": "acme-worker"]),
            // Apps
            resource("aws_ecs_cluster", "platform", ["name": "acme-platform"]),
            resource("aws_ecs_task_definition", "web", ["family": "acme-web", "cpu": "512", "memory": "1024"], ["aws_iam_role.web_task", "aws_secretsmanager_secret.orders_db"]),
            resource("aws_ecs_service", "web", ["name": "web", "desired_count": 3, "launch_type": "FARGATE"], ["aws_ecs_cluster.platform", "aws_ecs_task_definition.web", "aws_lb_target_group.web", "aws_security_group.web", "aws_subnet.private_a", "aws_db_instance.orders", "aws_elasticache_replication_group.sessions"]),
            resource("aws_ecs_task_definition", "api", ["family": "acme-api", "cpu": "1024", "memory": "2048"], ["aws_iam_role.web_task"]),
            resource("aws_ecs_service", "api", ["name": "api", "desired_count": 2, "launch_type": "FARGATE"], ["aws_ecs_cluster.platform", "aws_ecs_task_definition.api", "aws_lb_target_group.api", "aws_db_instance.orders", "aws_dynamodb_table.carts"]),
            resource("aws_lambda_function", "image_resizer", ["runtime": "python3.13", "memory_size": 1024, "timeout": 30], ["aws_s3_bucket.uploads", "aws_sqs_queue.uploads", "aws_iam_role.worker"]),
            // Messaging
            resource("aws_sqs_queue", "uploads", ["name": "acme-uploads", "visibility_timeout_seconds": 60]),
            resource("aws_sns_topic", "alerts", ["name": "acme-alerts"]),
            resource("aws_cloudwatch_event_rule", "nightly_reports", ["schedule_expression": "cron(0 6 * * ? *)"], ["aws_lambda_function.image_resizer"]),
            // Front door
            resource("aws_lb", "public", ["name": "acme-public", "load_balancer_type": "application", "dns_name": "acme-public-1234.us-west-2.elb.amazonaws.com"], ["aws_subnet.public_a", "aws_security_group.web"]),
            resource("aws_lb_target_group", "web", ["name": "acme-web", "port": 8080, "protocol": "HTTP"], ["aws_vpc.main"]),
            resource("aws_lb_target_group", "api", ["name": "acme-api", "port": 9090, "protocol": "HTTP"], ["aws_vpc.main"]),
            resource("aws_lb_listener", "https", ["port": 443, "protocol": "HTTPS"], ["aws_lb.public", "aws_acm_certificate.site", "aws_lb_target_group.web"]),
            resource("aws_acm_certificate", "site", ["domain_name": "shop.acme.example", "validation_method": "DNS"]),
            resource("aws_cloudfront_distribution", "site", ["domain_name": "d111111abcdef8.cloudfront.net", "enabled": true, "price_class": "PriceClass_100"], ["aws_lb.public", "aws_s3_bucket.assets", "aws_acm_certificate.site"]),
            resource("aws_route53_zone", "acme", ["name": "acme.example"]),
            resource("aws_route53_record", "shop", ["name": "shop.acme.example", "type": "A"], ["aws_route53_zone.acme", "aws_cloudfront_distribution.site"]),
            // Monitoring last: the most recent revision added the audit trail.
            resource("aws_cloudwatch_log_group", "web", ["name": "/acme/web", "retention_in_days": 30]),
            resource("aws_cloudwatch_log_group", "audit", ["name": "/acme/audit", "retention_in_days": 365], ["aws_kms_key.platform"]),
        ]
        let kept = keeping.map { Array(all.prefix($0)) } ?? all
        return ["version": 4, "resources": kept]
    }

    static let platformResourceCount = 36

    static func platformShownState(keeping: Int? = nil) -> [String: Any] {
        shown(from: platformRawState(keeping: keeping))
    }

    /// `terraform show -json` shape for a raw state whose resources have one instance each.
    static func shown(from raw: [String: Any]) -> [String: Any] {
        let resources = (raw["resources"] as? [[String: Any]] ?? []).map { resource -> [String: Any] in
            let instance = (resource["instances"] as? [[String: Any]])!.first!
            return ["address": "\(resource["type"]!).\(resource["name"]!)", "type": resource["type"]!,
                    "name": resource["name"]!, "mode": "managed", "provider_name": "registry.terraform.io/hashicorp/aws",
                    "values": instance["attributes"]!, "sensitive_values": instance["sample_sensitive"] ?? [:]]
        }
        return ["format_version": "1.0", "values": ["root_module": ["resources": resources]]]
    }
}
