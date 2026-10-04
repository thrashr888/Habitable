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
}
