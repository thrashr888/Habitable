import XCTest
import SwiftyJSON
@testable import HabitableCore

final class MapResourcePresentationTests: XCTestCase {
    private func attributes(_ values: [String: JSON], sensitive: JSON = JSON(false)) -> [ResourceAttribute] {
        resourceAttributes(values: values, sensitiveValues: sensitive)
    }

    func testKnownAnchorProducesTypedFactsAndOnlyWebLinksBecomeURLs() {
        let resource = MapDisplayResource(address: "aws_db_instance.main", type: "aws_db_instance", displayAttributes: attributes([
            "engine": JSON("postgres"), "engine_version": JSON("16.2"),
            "instance_class": JSON("db.t4g.medium"), "allocated_storage": JSON(40),
            "storage_encrypted": JSON(true), "multi_az": JSON(true), "availability_zone": JSON("us-west-2a"),
            "backup_retention_period": JSON(7), "backup_window": JSON("03:00-04:00"),
            "deletion_protection": JSON(false), "status": JSON("available"),
            "address": JSON("db.internal.example")
        ]))
        let tile = MapTile(id: resource.address, title: "Database", kind: .data, anchors: [resource.address], resources: [resource.address])

        let result = MapResourcePresentation.summarize(tile: tile, resources: [resource])

        XCTAssertEqual(result.subtitle, "RDS · Postgres")
        XCTAssertEqual(result.facts.map(\.label), ["Engine", "Version", "Class", "Storage", "Storage encryption", "Availability",
                                                     "Availability zone", "Backup retention", "Backup window", "Deletion protection", "Last recorded status"])
        XCTAssertEqual(result.facts.map(\.value), ["postgres", "16.2", "db.t4g.medium", "40 GiB", "Encrypted", "Multi-AZ",
                                                    "us-west-2a", "7 days", "03:00-04:00", "Disabled", "available"])
        XCTAssertEqual(result.endpoints.map(\.value), ["db.internal.example"])
        XCTAssertNil(result.endpoints.first?.url, "Database hostnames must not be turned into HTTPS links")
    }

    func testActualResourceAttributeRedactionHidesSensitiveEndpointAndFacts() {
        let resource = MapDisplayResource(address: "aws_s3_bucket.site", type: "aws_s3_bucket", displayAttributes: attributes([
            "bucket": JSON("example-site"), "website_endpoint": JSON("secret.example.test")
        ], sensitive: JSON(["website_endpoint": true])))
        let tile = MapTile(id: resource.address, title: "Site", kind: .frontDoor, anchors: [resource.address], resources: [resource.address])

        let result = MapResourcePresentation.summarize(tile: tile, resources: [resource])

        XCTAssertEqual(result.subtitle, "S3 bucket")
        XCTAssertEqual(result.facts.map(\.value), ["example-site"])
        XCTAssertTrue(result.endpoints.isEmpty)
        XCTAssertFalse(result.endpoints.map(\.value).joined().contains("secret.example.test"))
    }

    func testWebsiteEndpointAcceptsOnlyHTTPAndHTTPSURLs() {
        func resource(_ address: String, _ endpoint: String) -> MapDisplayResource {
            MapDisplayResource(address: address, type: "aws_s3_bucket", displayAttributes: attributes([
                "website_endpoint": JSON(endpoint)
            ]))
        }
        let safe = resource("aws_s3_bucket.site", "https://example.com/index.html")
        let unsafe = resource("aws_s3_bucket.bad", "javascript:alert(1)")
        let credentialed = resource("aws_s3_bucket.creds", "https://user:pass@example.com/")
        func tile(_ resource: MapDisplayResource) -> MapTile {
            MapTile(id: resource.address, title: "Site", kind: .frontDoor, anchors: [resource.address], resources: [resource.address])
        }
        XCTAssertEqual(MapResourcePresentation.summarize(tile: tile(safe), resources: [safe]).endpoints.first?.url?.absoluteString,
                       "https://example.com/index.html")
        XCTAssertNil(MapResourcePresentation.summarize(tile: tile(unsafe), resources: [unsafe]).endpoints.first?.url)
        XCTAssertNil(MapResourcePresentation.summarize(tile: tile(credentialed), resources: [credentialed]).endpoints.first?.url)
    }

    func testServiceSubtitlesKeepContextForCapacityAndNetworkAnchors() {
        let asg = MapDisplayResource(address: "aws_autoscaling_group.app", type: "aws_autoscaling_group", displayAttributes: attributes([
            "desired_capacity": JSON(2)
        ]))
        let vpc = MapDisplayResource(address: "aws_vpc.main", type: "aws_vpc", displayAttributes: attributes([
            "cidr_block": JSON("10.0.0.0/16")
        ]))
        func summarize(_ resource: MapDisplayResource) -> MapResourcePresentation {
            let tile = MapTile(id: resource.address, title: resource.type, kind: .network,
                               anchors: [resource.address], resources: [resource.address])
            return MapResourcePresentation.summarize(tile: tile, resources: [resource])
        }
        XCTAssertEqual(summarize(asg).subtitle, "Auto Scaling · 2 desired")
        XCTAssertEqual(summarize(vpc).subtitle, "VPC · 10.0.0.0/16")
    }

    func testGroupedVpcPrefersVpcAnchorOverAlphabeticallyEarlierNetworkHelpers() {
        let gateway = MapDisplayResource(address: "aws_internet_gateway.main", type: "aws_internet_gateway", displayAttributes: [])
        let routeTable = MapDisplayResource(address: "aws_route_table.main", type: "aws_route_table", displayAttributes: [])
        let subnet = MapDisplayResource(address: "aws_subnet.main", type: "aws_subnet", displayAttributes: [])
        let vpc = MapDisplayResource(address: "aws_vpc.main", type: "aws_vpc", displayAttributes: attributes([
            "cidr_block": JSON("10.0.0.0/16")
        ]))
        let tile = MapTile(id: gateway.address, title: "Network", kind: .network,
                           anchors: [gateway.address, routeTable.address, subnet.address, vpc.address],
                           resources: [gateway.address, routeTable.address, subnet.address, vpc.address])

        let result = MapResourcePresentation.summarize(tile: tile, resources: [gateway, routeTable, subnet, vpc])

        XCTAssertEqual(result.subtitle, "VPC · 10.0.0.0/16")
    }

    func testMissingRecordedStatusIsNotInvented() {
        let resource = MapDisplayResource(address: "aws_db_instance.main", type: "aws_db_instance", displayAttributes: attributes([
            "engine": JSON("postgres"), "status": JSON("(sensitive value)")
        ]))
        let tile = MapTile(id: resource.address, title: "Database", kind: .data, anchors: [resource.address], resources: [resource.address])

        let result = MapResourcePresentation.summarize(tile: tile, resources: [resource])

        XCTAssertFalse(result.facts.contains { $0.label.localizedCaseInsensitiveContains("status") })
    }

    func testUnknownAndCommonAWSTypesHaveReadableNamesWithoutAttributeDump() {
        let widget = MapDisplayResource(address: "custom_widget.example", type: "custom_widget", displayAttributes: attributes([
            "token": JSON("secret-looking-value")
        ]))
        let tile = MapTile(id: widget.address, title: "Widget", kind: .other, anchors: [widget.address], resources: [widget.address])
        let result = MapResourcePresentation.summarize(tile: tile, resources: [widget])
        XCTAssertEqual(result.subtitle, "Custom Widget")
        XCTAssertTrue(result.facts.isEmpty)
        XCTAssertTrue(result.endpoints.isEmpty)

        for (type, expected) in [("aws_acm_certificate", "ACM certificate"), ("aws_ses_email_identity", "SES identity"),
                                 ("aws_eip", "Elastic IP"), ("aws_key_pair", "EC2 key pair")] {
            let resource = MapDisplayResource(address: "\(type).example", type: type, displayAttributes: [])
            let typeTile = MapTile(id: resource.address, title: expected, kind: .other, anchors: [resource.address], resources: [resource.address])
            XCTAssertEqual(MapResourcePresentation.summarize(tile: typeTile, resources: [resource]).subtitle, expected)
        }
    }
}
