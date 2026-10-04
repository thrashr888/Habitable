import Foundation

enum ResourceMapSample {
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
