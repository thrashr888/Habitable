import Foundation

/// A starter for "New infrastructure": the resources it creates, a rough monthly
/// cost, and the readable .tf files that get written into a folder the person owns.
struct InfrastructureTemplate: Identifiable, Equatable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case websites = "Websites"
        case apps = "Apps & APIs"
        case databases = "Databases"
        case networks = "Networks"
        case learn = "Learn"
        case playground = "Playground (no cloud)"
    }

    struct PlannedResource: Equatable, Sendable {
        let name: String
        let type: String
        let note: String?
    }

    struct Input: Equatable, Sendable {
        let name: String
        let prompt: String
        let example: String
        let required: Bool
    }

    let id: String
    let title: String
    let summary: String
    let category: Category
    let provider: String
    let resources: [PlannedResource]
    let estimatedMonthlyCost: String
    let inputs: [Input]
    /// Filename to contents. `${input}` placeholders are filled in when written.
    let files: [String: String]

    var resourceCount: Int { resources.count }
}

enum InfrastructureTemplateError: LocalizedError, Equatable {
    case folderNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case .folderNotEmpty(let path):
            return "\(path) already has files in it. Pick an empty folder or a new name."
        }
    }
}

enum InfrastructureTemplates {
    static func templates(in category: InfrastructureTemplate.Category) -> [InfrastructureTemplate] {
        all.filter { $0.category == category }
    }

    static func template(id: String) -> InfrastructureTemplate? {
        all.first { $0.id == id }
    }

    /// "Static website" becomes "static-website".
    static func suggestedFolderName(_ template: InfrastructureTemplate) -> String {
        var name = ""
        var pendingDash = false
        for scalar in template.title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash && !name.isEmpty { name.append("-") }
                pendingDash = false
                name.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return name.isEmpty ? template.id : name
    }

    /// Writes the template into `folder`, creating it. An existing folder must be empty.
    /// `${input}` placeholders become the given value, or the input's example when blank.
    static func write(_ template: InfrastructureTemplate, to folder: URL, inputs: [String: String]) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            let contents = try fileManager.contentsOfDirectory(atPath: folder.path)
            guard isDirectory.boolValue, contents.isEmpty else {
                throw InfrastructureTemplateError.folderNotEmpty(folder.path)
            }
        } else {
            try fileManager.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

        var values: [String: String] = [:]
        for input in template.inputs {
            let given = inputs[input.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            values[input.name] = given.isEmpty ? input.example : given
        }

        var written: [URL] = []
        for filename in template.files.keys.sorted() {
            var text = template.files[filename] ?? ""
            let isTerraform = filename.hasSuffix(".tf")
            for (name, value) in values {
                let replacement = isTerraform ? hclEscaped(value) : value
                text = text.replacingOccurrences(of: "${\(name)}", with: replacement)
            }
            let url = folder.appendingPathComponent(filename)
            try Data(text.utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            written.append(url)
        }
        return written
    }

    private static func hclEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Catalog

    static let all: [InfrastructureTemplate] = [
        staticWebsite, edgeSite, redirectDomain, containerWebsite,
        postgresDatabase, privateNetwork, learnOutputs, playground
    ]

    private static func variablesFile(_ inputs: [InfrastructureTemplate.Input]) -> String {
        inputs.map { input in
            """
            variable "\(input.name)" {
              description = "\(input.prompt)"
              type        = string
              default     = "${\(input.name)}"
            }
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private static func make(
        id: String,
        title: String,
        summary: String,
        category: InfrastructureTemplate.Category,
        provider: String,
        resources: [InfrastructureTemplate.PlannedResource],
        cost: String,
        inputs: [InfrastructureTemplate.Input],
        main: String,
        readme: String
    ) -> InfrastructureTemplate {
        var files = ["main.tf": main, "README.md": readme]
        if !inputs.isEmpty { files["variables.tf"] = variablesFile(inputs) }
        return InfrastructureTemplate(
            id: id, title: title, summary: summary, category: category, provider: provider,
            resources: resources, estimatedMonthlyCost: cost, inputs: inputs, files: files
        )
    }

    private static func resource(_ name: String, _ type: String, _ note: String? = nil) -> InfrastructureTemplate.PlannedResource {
        .init(name: name, type: type, note: note)
    }

    private static func input(_ name: String, _ prompt: String, _ example: String, required: Bool = true) -> InfrastructureTemplate.Input {
        .init(name: name, prompt: prompt, example: example, required: required)
    }

    // MARK: Websites

    private static let staticWebsite = make(
        id: "static-website",
        title: "Static website",
        summary: "Bucket, CDN, certificate and a domain record.",
        category: .websites,
        provider: "AWS",
        resources: [
            resource("Bucket", "aws_s3_bucket", "Holds your site files"),
            resource("Website settings", "aws_s3_bucket_website_configuration", "index.html and 404.html"),
            resource("Certificate", "aws_acm_certificate", "HTTPS for your domain"),
            resource("CDN", "aws_cloudfront_distribution", "Serves the bucket worldwide"),
            resource("Domain record", "aws_route53_record", "Points your domain at the CDN")
        ],
        cost: "about $1/mo",
        inputs: [
            input("domain", "Domain for the site. Its Route 53 hosted zone must already exist.", "example.com"),
            input("region", "AWS region for the bucket.", "us-east-1", required: false)
        ],
        main: #"""
        # Static website: a bucket for your files, a CDN in front, HTTPS and a domain.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }
        }

        # Credentials come from your AWS environment (profile or environment variables),
        # never from these files.
        provider "aws" {
          region = var.region
        }

        # CloudFront only accepts certificates created in us-east-1.
        provider "aws" {
          alias  = "us_east_1"
          region = "us-east-1"
        }

        # The hosted zone for your domain, looked up by name.
        data "aws_route53_zone" "site" {
          name = var.domain
        }

        # The bucket that holds your site files.
        resource "aws_s3_bucket" "site" {
          bucket = var.domain
        }

        # Tells S3 which file is the home page and which is the not-found page.
        resource "aws_s3_bucket_website_configuration" "site" {
          bucket = aws_s3_bucket.site.id

          index_document {
            suffix = "index.html"
          }

          error_document {
            key = "404.html"
          }
        }

        # The HTTPS certificate. Validate it with the DNS record AWS asks for.
        resource "aws_acm_certificate" "site" {
          provider          = aws.us_east_1
          domain_name       = var.domain
          validation_method = "DNS"

          lifecycle {
            create_before_destroy = true
          }
        }

        # The CDN: caches your site close to visitors and serves it over HTTPS.
        resource "aws_cloudfront_distribution" "site" {
          enabled             = true
          aliases             = [var.domain]
          default_root_object = "index.html"

          origin {
            domain_name = aws_s3_bucket_website_configuration.site.website_endpoint
            origin_id   = "site-bucket"

            custom_origin_config {
              http_port              = 80
              https_port             = 443
              origin_protocol_policy = "http-only"
              origin_ssl_protocols   = ["TLSv1.2"]
            }
          }

          default_cache_behavior {
            target_origin_id       = "site-bucket"
            viewer_protocol_policy = "redirect-to-https"
            allowed_methods        = ["GET", "HEAD"]
            cached_methods         = ["GET", "HEAD"]

            forwarded_values {
              query_string = false

              cookies {
                forward = "none"
              }
            }
          }

          restrictions {
            geo_restriction {
              restriction_type = "none"
            }
          }

          viewer_certificate {
            acm_certificate_arn      = aws_acm_certificate.site.arn
            ssl_support_method       = "sni-only"
            minimum_protocol_version = "TLSv1.2_2021"
          }
        }

        # Points your domain at the CDN.
        resource "aws_route53_record" "site" {
          zone_id = data.aws_route53_zone.site.zone_id
          name    = var.domain
          type    = "A"

          alias {
            name                   = aws_cloudfront_distribution.site.domain_name
            zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
            evaluate_target_health = false
          }
        }

        output "site_url" {
          value = "https://${aws_cloudfront_distribution.site.domain_name}"
        }
        """#,
        readme: """
        # Static website

        Creates a bucket for your site files, a CDN in front of it, an HTTPS
        certificate and a domain record. 5 resources on AWS.

        Cost: about $1/mo for a quiet site. Traffic and storage add to it, and
        this is a rough figure, not a quote.

        Change the domain and region in `variables.tf`. The domain needs an
        existing Route 53 hosted zone. Put `index.html` and `404.html` in the
        bucket after the first apply, and add the certificate's DNS validation
        record before the CDN will serve HTTPS.

        Credentials stay in your AWS environment. Nothing here stores them.
        """
    )

    private static let edgeSite = make(
        id: "edge-site",
        title: "Edge site",
        summary: "Cloudflare Pages with a custom domain.",
        category: .websites,
        provider: "Cloudflare",
        resources: [
            resource("Pages project", "cloudflare_pages_project", "Builds and hosts the site"),
            resource("Custom domain", "cloudflare_pages_domain", "Attaches your domain to the project"),
            resource("Domain record", "cloudflare_record", "CNAME to the Pages address")
        ],
        cost: "free tier",
        inputs: [
            input("account_id", "Cloudflare account ID.", "0123456789abcdef0123456789abcdef"),
            input("zone_id", "Zone ID of the domain's DNS zone.", "fedcba9876543210fedcba9876543210"),
            input("domain", "Domain to serve the site on.", "www.example.com")
        ],
        main: #"""
        # Edge site: a Cloudflare Pages project with your own domain.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            cloudflare = {
              source  = "cloudflare/cloudflare"
              version = "~> 4.40"
            }
          }
        }

        # The API token comes from the CLOUDFLARE_API_TOKEN environment variable,
        # never from these files.
        provider "cloudflare" {}

        # The Pages project. Upload a build with Wrangler or connect a Git repository later.
        resource "cloudflare_pages_project" "site" {
          account_id        = var.account_id
          name              = replace(var.domain, ".", "-")
          production_branch = "main"
        }

        # Attaches your domain to the project.
        resource "cloudflare_pages_domain" "site" {
          account_id   = var.account_id
          project_name = cloudflare_pages_project.site.name
          domain       = var.domain
        }

        # Sends the domain to the project's pages.dev address.
        resource "cloudflare_record" "site" {
          zone_id = var.zone_id
          name    = var.domain
          type    = "CNAME"
          content = cloudflare_pages_project.site.subdomain
          proxied = true
        }
        """#,
        readme: """
        # Edge site

        Creates a Cloudflare Pages project, attaches your domain to it and adds
        the DNS record. 3 resources on Cloudflare.

        Cost: free tier. Cloudflare's free plan covers a small site; check their
        current limits if you expect a lot of builds or traffic.

        Change the account ID, zone ID and domain in `variables.tf`. Set the
        `CLOUDFLARE_API_TOKEN` environment variable with a token that can edit
        Pages and DNS. The token is never written to these files.
        """
    )

    private static let redirectDomain = make(
        id: "redirect-domain",
        title: "Redirect domain",
        summary: "Sends one domain to another.",
        category: .websites,
        provider: "AWS",
        resources: [
            resource("Bucket", "aws_s3_bucket", "Does nothing but redirect"),
            resource("Redirect settings", "aws_s3_bucket_website_configuration", "Sends every request to the new domain"),
            resource("Domain record", "aws_route53_record", "Points the old domain at the bucket")
        ],
        cost: "under $1/mo",
        inputs: [
            input("from_domain", "The domain to redirect from.", "old-name.com"),
            input("to_domain", "The domain to send visitors to.", "new-name.com"),
            input("zone_id", "Route 53 hosted zone ID for the from domain.", "Z0123456789ABCDEFGHIJ")
        ],
        main: #"""
        # Redirect domain: visitors to one domain land on another.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }
        }

        # Credentials come from your AWS environment, never from these files.
        provider "aws" {
          region = "us-east-1"
        }

        # An empty bucket named after the old domain. S3 requires that name.
        resource "aws_s3_bucket" "redirect" {
          bucket = var.from_domain
        }

        # Sends every request to the new domain.
        resource "aws_s3_bucket_website_configuration" "redirect" {
          bucket = aws_s3_bucket.redirect.id

          redirect_all_requests_to {
            host_name = var.to_domain
            protocol  = "https"
          }
        }

        # Points the old domain at the bucket.
        resource "aws_route53_record" "redirect" {
          zone_id = var.zone_id
          name    = var.from_domain
          type    = "A"

          alias {
            name                   = aws_s3_bucket_website_configuration.redirect.website_domain
            zone_id                = aws_s3_bucket.redirect.hosted_zone_id
            evaluate_target_health = false
          }
        }
        """#,
        readme: """
        # Redirect domain

        Sends visitors from one domain to another. 3 resources on AWS.

        Cost: under $1/mo. The hosted zone is the main charge, and this is a
        rough figure.

        Change the domains and zone ID in `variables.tf`. S3 redirects work over
        plain HTTP only, so `https://` links to the old domain will not connect.
        Credentials stay in your AWS environment.
        """
    )

    // MARK: Apps & APIs

    private static let containerWebsite = make(
        id: "container-website",
        title: "Container website",
        summary: "A container image behind a load balancer with HTTPS.",
        category: .apps,
        provider: "AWS",
        resources: [
            resource("Cluster", "aws_ecs_cluster", "Where the container runs"),
            resource("Log group", "aws_cloudwatch_log_group", "Container output, kept 14 days"),
            resource("Task definition", "aws_ecs_task_definition", "Image, CPU and memory"),
            resource("Service", "aws_ecs_service", "Keeps one copy running"),
            resource("Load balancer", "aws_lb", "Public entry point"),
            resource("Target group", "aws_lb_target_group", "Where the load balancer sends traffic"),
            resource("HTTPS listener", "aws_lb_listener", "Port 443 with your certificate"),
            resource("HTTP listener", "aws_lb_listener", "Port 80, redirects to HTTPS"),
            resource("Load balancer firewall", "aws_security_group", "Allows web traffic in"),
            resource("Container firewall", "aws_security_group", "Only the load balancer can reach it"),
            resource("Certificate", "aws_acm_certificate", "HTTPS for your domain")
        ],
        cost: "about $38/mo",
        inputs: [
            input("image", "Container image to run. It must listen on port 80.", "nginx:stable"),
            input("domain", "Domain for the site.", "app.example.com")
        ],
        main: #"""
        # Container website: one container on ECS Fargate behind a load balancer.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }
        }

        # Credentials come from your AWS environment, never from these files.
        provider "aws" {
          region = "us-east-1"
        }

        # This template uses your account's default network instead of creating one.
        data "aws_vpc" "default" {
          default = true
        }

        data "aws_subnets" "default" {
          filter {
            name   = "vpc-id"
            values = [data.aws_vpc.default.id]
          }
        }

        # The role ECS uses to pull the image and write logs. AWS creates it the
        # first time you use ECS in the console; create it once if it is missing.
        data "aws_iam_role" "task_execution" {
          name = "ecsTaskExecutionRole"
        }

        resource "aws_ecs_cluster" "app" {
          name = "container-website"
        }

        resource "aws_cloudwatch_log_group" "app" {
          name              = "/ecs/container-website"
          retention_in_days = 14
        }

        # What to run: your image with a small slice of CPU and memory.
        resource "aws_ecs_task_definition" "app" {
          family                   = "container-website"
          requires_compatibilities = ["FARGATE"]
          network_mode             = "awsvpc"
          cpu                      = 256
          memory                   = 512
          execution_role_arn       = data.aws_iam_role.task_execution.arn

          container_definitions = jsonencode([
            {
              name         = "app"
              image        = var.image
              essential    = true
              portMappings = [{ containerPort = 80 }]
              logConfiguration = {
                logDriver = "awslogs"
                options = {
                  "awslogs-group"         = aws_cloudwatch_log_group.app.name
                  "awslogs-region"        = "us-east-1"
                  "awslogs-stream-prefix" = "app"
                }
              }
            }
          ])
        }

        # Firewall for the load balancer: web traffic in from anywhere.
        resource "aws_security_group" "lb" {
          name        = "container-website-lb"
          description = "Web traffic to the load balancer"
          vpc_id      = data.aws_vpc.default.id

          ingress {
            from_port   = 80
            to_port     = 80
            protocol    = "tcp"
            cidr_blocks = ["0.0.0.0/0"]
          }

          ingress {
            from_port   = 443
            to_port     = 443
            protocol    = "tcp"
            cidr_blocks = ["0.0.0.0/0"]
          }

          egress {
            from_port   = 0
            to_port     = 0
            protocol    = "-1"
            cidr_blocks = ["0.0.0.0/0"]
          }
        }

        # Firewall for the container: only the load balancer may connect.
        resource "aws_security_group" "app" {
          name        = "container-website-app"
          description = "Traffic from the load balancer to the container"
          vpc_id      = data.aws_vpc.default.id

          ingress {
            from_port       = 80
            to_port         = 80
            protocol        = "tcp"
            security_groups = [aws_security_group.lb.id]
          }

          egress {
            from_port   = 0
            to_port     = 0
            protocol    = "-1"
            cidr_blocks = ["0.0.0.0/0"]
          }
        }

        # The HTTPS certificate. Validate it with the DNS record AWS asks for.
        resource "aws_acm_certificate" "app" {
          domain_name       = var.domain
          validation_method = "DNS"

          lifecycle {
            create_before_destroy = true
          }
        }

        resource "aws_lb" "app" {
          name               = "container-website"
          load_balancer_type = "application"
          subnets            = data.aws_subnets.default.ids
          security_groups    = [aws_security_group.lb.id]
        }

        resource "aws_lb_target_group" "app" {
          name        = "container-website"
          port        = 80
          protocol    = "HTTP"
          target_type = "ip"
          vpc_id      = data.aws_vpc.default.id
        }

        # Port 443: serves the site over HTTPS.
        resource "aws_lb_listener" "https" {
          load_balancer_arn = aws_lb.app.arn
          port              = 443
          protocol          = "HTTPS"
          ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          certificate_arn   = aws_acm_certificate.app.arn

          default_action {
            type             = "forward"
            target_group_arn = aws_lb_target_group.app.arn
          }
        }

        # Port 80: sends visitors to HTTPS.
        resource "aws_lb_listener" "http" {
          load_balancer_arn = aws_lb.app.arn
          port              = 80
          protocol          = "HTTP"

          default_action {
            type = "redirect"

            redirect {
              port        = "443"
              protocol    = "HTTPS"
              status_code = "HTTP_301"
            }
          }
        }

        # Keeps one copy of the container running and registers it with the load balancer.
        resource "aws_ecs_service" "app" {
          name            = "container-website"
          cluster         = aws_ecs_cluster.app.id
          task_definition = aws_ecs_task_definition.app.arn
          desired_count   = 1
          launch_type     = "FARGATE"

          network_configuration {
            subnets          = data.aws_subnets.default.ids
            security_groups  = [aws_security_group.app.id]
            assign_public_ip = true
          }

          load_balancer {
            target_group_arn = aws_lb_target_group.app.arn
            container_name   = "app"
            container_port   = 80
          }

          depends_on = [aws_lb_listener.https]
        }

        output "load_balancer_address" {
          description = "Point your domain's DNS at this address."
          value       = aws_lb.app.dns_name
        }
        """#,
        readme: """
        # Container website

        Runs one container on ECS Fargate behind a load balancer that serves
        HTTPS. 11 resources on AWS, in your account's default network.

        Cost: about $38/mo, mostly the load balancer and one small container.
        This is a rough figure; traffic and logs add to it.

        Change the image and domain in `variables.tf`. The image must listen on
        port 80. Add the certificate's DNS validation record and point your
        domain at `load_balancer_address` after the first apply. The task needs
        an `ecsTaskExecutionRole` role in the account.

        Credentials stay in your AWS environment. Nothing here stores them.
        """
    )

    // MARK: Databases

    private static let postgresDatabase = make(
        id: "postgres-database",
        title: "Postgres database",
        summary: "A small Postgres instance with its password kept in Secrets Manager.",
        category: .databases,
        provider: "AWS",
        resources: [
            resource("Password", "random_password", "Generated once, never printed"),
            resource("Secret", "aws_secretsmanager_secret", "Where the password is kept"),
            resource("Secret value", "aws_secretsmanager_secret_version", "Stores the generated password"),
            resource("Firewall", "aws_security_group", "Postgres traffic from inside the network only"),
            resource("Subnet group", "aws_db_subnet_group", "Which subnets the database may use"),
            resource("Database", "aws_db_instance", "db.t4g.micro, 20 GB")
        ],
        cost: "about $15/mo",
        inputs: [
            input("name", "Name for the database and its secret.", "orders")
        ],
        main: #"""
        # Postgres database: one small instance, with its password in Secrets Manager.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
            random = {
              source  = "hashicorp/random"
              version = "~> 3.6"
            }
          }
        }

        # Credentials come from your AWS environment, never from these files.
        provider "aws" {
          region = "us-east-1"
        }

        # Uses your account's default network.
        data "aws_vpc" "default" {
          default = true
        }

        data "aws_subnets" "default" {
          filter {
            name   = "vpc-id"
            values = [data.aws_vpc.default.id]
          }
        }

        # A strong password, generated here and kept in Terraform state.
        resource "random_password" "db" {
          length  = 24
          special = false
        }

        # The secret that holds it, so apps can read it without a copy in code.
        resource "aws_secretsmanager_secret" "db" {
          name = "${var.name}-database-password"
        }

        resource "aws_secretsmanager_secret_version" "db" {
          secret_id     = aws_secretsmanager_secret.db.id
          secret_string = random_password.db.result
        }

        # Only machines inside the network can reach the database.
        resource "aws_security_group" "db" {
          name        = "${var.name}-database"
          description = "Postgres from inside the network"
          vpc_id      = data.aws_vpc.default.id

          ingress {
            from_port   = 5432
            to_port     = 5432
            protocol    = "tcp"
            cidr_blocks = [data.aws_vpc.default.cidr_block]
          }
        }

        resource "aws_db_subnet_group" "db" {
          name       = "${var.name}-database"
          subnet_ids = data.aws_subnets.default.ids
        }

        # The database itself: the smallest practical size.
        resource "aws_db_instance" "db" {
          identifier             = var.name
          engine                 = "postgres"
          engine_version         = "16"
          instance_class         = "db.t4g.micro"
          allocated_storage      = 20
          db_name                = replace(var.name, "-", "_")
          username               = "app"
          password               = random_password.db.result
          db_subnet_group_name   = aws_db_subnet_group.db.name
          vpc_security_group_ids = [aws_security_group.db.id]
          publicly_accessible    = false
          storage_encrypted      = true
          backup_retention_period = 7
          skip_final_snapshot    = true
        }

        output "endpoint" {
          value = aws_db_instance.db.address
        }
        """#,
        readme: """
        # Postgres database

        Creates a small Postgres database on RDS with a generated password kept
        in Secrets Manager. 6 resources on AWS, in your account's default network.

        Cost: about $15/mo for the instance and 20 GB of storage. Backups and
        extra storage add to it, and this is a rough figure.

        Change the name in `variables.tf`. The database is not reachable from the
        internet. It skips the final snapshot when destroyed, so turn that off
        before keeping real data here. The password lives in Terraform state as
        well as Secrets Manager; keep state private.
        """
    )

    // MARK: Networks

    private static let privateNetwork = make(
        id: "private-network",
        title: "Private network",
        summary: "A VPC with two subnets and a route to the internet.",
        category: .networks,
        provider: "AWS",
        resources: [
            resource("Network", "aws_vpc", "The address range you choose"),
            resource("Subnet A", "aws_subnet", "First availability zone"),
            resource("Subnet B", "aws_subnet", "Second availability zone"),
            resource("Internet gateway", "aws_internet_gateway", "The way out to the internet"),
            resource("Route table", "aws_route_table", "Sends outside traffic to the gateway"),
            resource("Route table link A", "aws_route_table_association", "Subnet A uses the route table"),
            resource("Route table link B", "aws_route_table_association", "Subnet B uses the route table")
        ],
        cost: "under $1/mo",
        inputs: [
            input("cidr", "Address range for the network.", "10.20.0.0/16")
        ],
        main: #"""
        # Private network: a VPC with two subnets and a route to the internet.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }
        }

        # Credentials come from your AWS environment, never from these files.
        provider "aws" {
          region = "us-east-1"
        }

        data "aws_availability_zones" "available" {
          state = "available"
        }

        # The network itself. Free; you pay for what runs inside it.
        resource "aws_vpc" "main" {
          cidr_block           = var.cidr
          enable_dns_hostnames = true

          tags = {
            Name = "private-network"
          }
        }

        # Two subnets in different zones, cut from the network's range.
        resource "aws_subnet" "a" {
          vpc_id            = aws_vpc.main.id
          cidr_block        = cidrsubnet(var.cidr, 8, 0)
          availability_zone = data.aws_availability_zones.available.names[0]
        }

        resource "aws_subnet" "b" {
          vpc_id            = aws_vpc.main.id
          cidr_block        = cidrsubnet(var.cidr, 8, 1)
          availability_zone = data.aws_availability_zones.available.names[1]
        }

        resource "aws_internet_gateway" "main" {
          vpc_id = aws_vpc.main.id
        }

        # Anything not inside the network goes out through the gateway.
        resource "aws_route_table" "main" {
          vpc_id = aws_vpc.main.id

          route {
            cidr_block = "0.0.0.0/0"
            gateway_id = aws_internet_gateway.main.id
          }
        }

        resource "aws_route_table_association" "a" {
          subnet_id      = aws_subnet.a.id
          route_table_id = aws_route_table.main.id
        }

        resource "aws_route_table_association" "b" {
          subnet_id      = aws_subnet.b.id
          route_table_id = aws_route_table.main.id
        }

        output "vpc_id" {
          value = aws_vpc.main.id
        }
        """#,
        readme: """
        # Private network

        Creates a VPC with two subnets in different zones and a route out to the
        internet. 7 resources on AWS.

        Cost: under $1/mo. The network itself is free; what you run inside it is
        not. This is a rough figure.

        Change the address range in `variables.tf`. It needs room for two /24
        subnets, so a /16 or /20 works. Credentials stay in your AWS environment.
        """
    )

    // MARK: Learn and Playground

    private static let learnOutputs = make(
        id: "learn-outputs-and-inputs",
        title: "Learn: Outputs and inputs",
        summary: "One input, one random number and one output, on this Mac.",
        category: .learn,
        provider: "None",
        resources: [
            resource("Lucky number", "random_integer", "A number from 1 to 100")
        ],
        cost: "nothing; runs on this Mac",
        inputs: [
            input("name", "Who the greeting is for.", "world", required: false)
        ],
        main: #"""
        # Learn: Outputs and inputs.
        # An input goes in (var.name), a resource makes a value, an output comes out.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            random = {
              source  = "hashicorp/random"
              version = "~> 3.6"
            }
          }
        }

        # Picked once and kept in state until you change the settings.
        resource "random_integer" "lucky" {
          min = 1
          max = 100
        }

        # Shown after Apply, and by `terraform output`.
        output "greeting" {
          description = "Built from the input and the resource."
          value       = format("Hello, %s. Your number is %d.", var.name, random_integer.lucky.result)
        }
        """#,
        readme: """
        # Learn: Outputs and inputs

        Shows how an input, a resource and an output fit together. 1 resource, no
        cloud account.

        Cost: nothing; runs on this Mac.

        Change `name` in `variables.tf`, then Preview Changes. The greeting
        output changes and the number stays the same. Apply it and read the
        output in the inspector.
        """
    )

    private static let playground = make(
        id: "playground",
        title: "Playground",
        summary: "Two harmless resources to try Preview, Review and Apply.",
        category: .playground,
        provider: "None",
        resources: [
            resource("Pet name", "random_pet", "A made-up name, kept in state"),
            resource("Greeting", "terraform_data", "Stores a value built from the pet name")
        ],
        cost: "nothing; runs on this Mac",
        inputs: [],
        main: #"""
        # Playground: nothing here touches a cloud account.
        # Use it to see how Preview Changes, review and Apply work.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            random = {
              source  = "hashicorp/random"
              version = "~> 3.6"
            }
          }
        }

        # A random two-word name. Change `length` and preview to see a replace.
        resource "random_pet" "pet" {
          length = 2
        }

        # terraform_data is built into Terraform. It just remembers a value in state.
        resource "terraform_data" "greeting" {
          input = random_pet.pet.id
        }

        output "pet" {
          value = random_pet.pet.id
        }
        """#,
        readme: """
        # Playground

        Two harmless resources that never leave this Mac. Preview Changes shows
        both as new, Apply records them in state, and changing `length` in
        `main.tf` shows what a replace looks like.

        Cost: nothing; runs on this Mac. No cloud account or credentials needed.
        """
    )
}
