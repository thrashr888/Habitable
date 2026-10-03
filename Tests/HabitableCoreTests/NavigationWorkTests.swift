import XCTest
import SwiftyJSON
@testable import HabitableCore

@MainActor
final class NavigationWorkTests: XCTestCase {
    func testCachedResourceAttributesInvalidateForValuesAndSensitiveMask() {
        let resource = ShowResource(address: "example.test", mode: "managed", type: "example", name: "test",
            provider_name: nil, schema_version: nil, values: ["token": JSON("before")], sensitiveValues: JSON(false))
        XCTAssertEqual(resource.displayAttributes.first?.value, "before")
        resource.values = ["token": JSON("after")]
        XCTAssertEqual(resource.displayAttributes.first?.value, "after")
        resource.sensitiveValues = JSON(["token": true])
        XCTAssertEqual(resource.displayAttributes.first?.value, "(sensitive value)")
        XCTAssertFalse(resource.displayAttributes.map(\.value).joined().contains("after"))
    }

    func testFastVersionParserPreservesStableVersionRules() {
        XCTAssertEqual(TerraformRelease.components("1.16.5"), [1, 16, 5])
        XCTAssertEqual(TerraformRelease.components("0.0.0"), [0, 0, 0])
        for invalid in ["01.2.3", "1.02.3", "1.2.03", "1..3", "1.2", "1.2.3.4", "1.2.3-beta", "１.2.3", "1.2.-3", "1.2.3\n", "999999999999999999999999.2.3"] {
            XCTAssertNil(TerraformRelease.components(invalid), invalid)
        }
    }

    func testOutputFormattingCacheTracksValueAndSensitivityChanges() {
        let output = Output(key: "example", type: "object", value: #"{"b":2,"a":1}"#, sensitive: false)
        XCTAssertTrue(output.displayValue.contains("\n"))
        output.value = "replacement"
        XCTAssertEqual(output.displayValue, "replacement")
        output.sensitive = true
        XCTAssertEqual(output.displayValue, "(sensitive value)")
        output.value = "secret"
        XCTAssertEqual(output.displayValue, "(sensitive value)")
        output.sensitive = false
        XCTAssertEqual(output.displayValue, "secret")
    }

    @MainActor
    func testPageReentryReusesCatalogButExplicitRefreshStillFetches() async throws {
        let counter = CatalogFetchCounter()
        let service = TerraformReleaseService(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), architecture: "arm64") { _ in
            await counter.record()
            return Data(#"{"versions":{"1.16.5":{"builds":[{"os":"darwin","arch":"arm64"}]}}}"#.utf8)
        }
        let catalog = TerraformReleaseCatalog(service: service)
        await catalog.refreshIfNeeded()
        await catalog.refreshIfNeeded()
        let firstCount = await counter.count
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(catalog.available.map(\.version), ["1.16.5"])
        await catalog.refresh()
        let refreshedCount = await counter.count
        XCTAssertEqual(refreshedCount, 2)
    }

    func testRepresentativeNavigationWorkBenchmark() throws {
        guard ProcessInfo.processInfo.environment["HABITABLE_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in benchmark; timings are not a UI navigation measurement")
        }
        let values = Dictionary(uniqueKeysWithValues: (0..<1000).map { ("attribute_\($0)", JSON(["value": "example", "number": $0])) })
        let resource = ShowResource(address: "example.test", mode: "managed", type: "example", name: "test",
            provider_name: nil, schema_version: nil, values: values, sensitiveValues: JSON(false))
        let start = Date()
        for _ in 0..<5 { XCTAssertEqual(resourceAttributes(values: values, sensitiveValues: JSON(false)).count, 2000) }
        let repeated = Date().timeIntervalSince(start)
        let cachedStart = Date()
        for _ in 0..<5 { XCTAssertEqual(resource.displayAttributes.count, 2000) }
        let cached = Date().timeIntervalSince(cachedStart)
        let releases = (0..<300).reversed().map { TerraformRelease(version: "1.\($0).0") }
        func legacyComponents(_ version: String) -> [Int] {
            guard version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return [] }
            return version.split(separator: ".").compactMap { Int($0) }
        }
        let sortStart = Date()
        var legacy: [TerraformRelease] = []
        for _ in 0..<5 { legacy = releases.sorted { legacyComponents($1.version).lexicographicallyPrecedes(legacyComponents($0.version)) } }
        let legacyTime = Date().timeIntervalSince(sortStart)
        let fastStart = Date()
        var fast: [TerraformRelease] = []
        for _ in 0..<5 { fast = releases.sorted(by: TerraformRelease.newestFirst) }
        let fastTime = Date().timeIntervalSince(fastStart)
        XCTAssertEqual(legacy, fast)
        print(String(format: "NAV_WORK attributes five reads: %.2f → %.2f ms; version sorts five times: %.2f → %.2f ms", repeated * 1000, cached * 1000, legacyTime * 1000, fastTime * 1000))
    }
}

private actor CatalogFetchCounter {
    var count = 0
    func record() { count += 1 }
}
