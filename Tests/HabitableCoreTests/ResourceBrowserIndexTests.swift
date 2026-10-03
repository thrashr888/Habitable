import XCTest
@testable import HabitableCore

final class ResourceBrowserIndexTests: XCTestCase {
    private func index() -> ResourceBrowserIndex {
        ResourceBrowserIndex(records: [
            ResourceBrowserRecord(id: "module.network.aws_instance.web", address: "module.network.aws_instance.web",
                                  type: "aws_instance", provider: "registry.terraform.io/hashicorp/aws", mode: "managed"),
            ResourceBrowserRecord(id: "data.aws_ami.base", address: "data.aws_ami.base",
                                  type: "aws_ami", provider: "registry.terraform.io/hashicorp/aws", mode: "data"),
            ResourceBrowserRecord(id: "module.region[\"east.zone\"].module.child[\"雪\"].aws_s3_bucket.logs[\"prod.eu\"]",
                                  address: "module.region[\"east.zone\"].module.child[\"雪\"].aws_s3_bucket.logs[\"prod.eu\"]",
                                  type: "aws_s3_bucket", provider: "registry.terraform.io/hashicorp/aws", mode: "managed"),
            ResourceBrowserRecord(id: "module.random.random_id.token", address: "module.random.random_id.token",
                                  type: "random_id", provider: "registry.terraform.io/hashicorp/random", mode: "managed")
        ])
    }

    func testTypeAndManagedDataCategoryAreIndependentFilters() {
        let index = index()
        var query = ResourceBrowserQuery()
        query.type = "aws_ami"
        XCTAssertEqual(index.matchingIDs(for: query), ["data.aws_ami.base"])

        query.type = "All resource types"
        query.mode = "data"
        XCTAssertEqual(index.matchingIDs(for: query), ["data.aws_ami.base"])
        XCTAssertEqual(index.types, ["aws_ami", "aws_instance", "aws_s3_bucket", "random_id"])
    }

    func testSearchMatchesAddressTypeProviderAndModule() {
        let index = index()
        var query = ResourceBrowserQuery()
        query.search = "aws_s3_bucket"
        XCTAssertEqual(index.matchingIDs(for: query), ["module.region[\"east.zone\"].module.child[\"雪\"].aws_s3_bucket.logs[\"prod.eu\"]"])

        query.search = "hashicorp/random"
        XCTAssertEqual(index.matchingIDs(for: query), ["module.random.random_id.token"])

        query.search = "module.region[\"east.zone\"].module.child[\"雪\"]"
        XCTAssertEqual(index.matchingIDs(for: query), ["module.region[\"east.zone\"].module.child[\"雪\"].aws_s3_bucket.logs[\"prod.eu\"]"])
    }

    func testNestedQuotedModuleKeysKeepEmbeddedDotsAndUnicodeIntact() {
        let row = ResourceBrowserRecord(id: "x", address: "module.region[\"east.zone\"].module.child[\"雪\"].aws_instance.web[\"prod.eu\"]",
                                        type: "aws_instance", provider: nil, mode: nil)
        XCTAssertEqual(row.module, "module.region[\"east.zone\"].module.child[\"雪\"]")
        XCTAssertEqual(row.provider, "—")
        XCTAssertEqual(row.mode, "managed")
    }

    func testOptionsAreDeduplicatedAndSearchIsCaseInsensitive() {
        let index = index()
        XCTAssertEqual(index.providers.count, 2)
        XCTAssertEqual(index.modules.count, 4)
        var query = ResourceBrowserQuery()
        query.search = "AWS_INSTANCE"
        XCTAssertEqual(index.matchingIDs(for: query), ["module.network.aws_instance.web"])
    }

    func testSelectionSurvivesOnlyWhileItsAddressRemainsVisible() {
        XCTAssertEqual(ResourceBrowserIndex.safeSelection("data.aws_ami.base",
                                                           visibleIDs: ["data.aws_ami.base"]),
                       "data.aws_ami.base")
        XCTAssertNil(ResourceBrowserIndex.safeSelection("data.aws_ami.base",
                                                        visibleIDs: ["module.network.aws_instance.web"]))
        XCTAssertNil(ResourceBrowserIndex.safeSelection("stale-address", visibleIDs: []))
    }

    func testMalformedDuplicateAddressesKeepFirstRecordWithoutDuplicatingRows() {
        let first = ResourceBrowserRecord(id: "same.address", address: "same.address",
                                          type: "aws_instance", provider: "first", mode: "managed")
        let duplicate = ResourceBrowserRecord(id: "same.address", address: "same.address",
                                              type: "aws_ami", provider: "second", mode: "data")
        let index = ResourceBrowserIndex(records: [first, duplicate])
        XCTAssertEqual(index.records, [first])
        XCTAssertEqual(index.matchingIDs(for: ResourceBrowserQuery()), ["same.address"])
        XCTAssertEqual(index.providers, ["first"])
    }
}
