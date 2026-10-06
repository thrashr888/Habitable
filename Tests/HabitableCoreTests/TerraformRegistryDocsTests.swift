import Foundation
import XCTest
@testable import HabitableCore

@MainActor
final class TerraformRegistryDocsTests: XCTestCase {
    override func setUp() async throws {
        RegistryStub.reset()
        TerraformRegistryDocsModel.clearCache()
    }

    private func model() -> TerraformRegistryDocsModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistryStub.self]
        return TerraformRegistryDocsModel(session: URLSession(configuration: config))
    }

    private func stubProvider(versions: [(String, String)], slug: String, category: String, content: String) {
        let included = versions.map { #"{"type":"provider-versions","id":"\#($0.0)","attributes":{"version":"\#($0.1)"}}"# }.joined(separator: ",")
        RegistryStub.handler = { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch url.path {
            case "/v2/providers/hashicorp/aws":
                return Data(#"{"data":{"id":"1"},"included":[\#(included)]}"#.utf8)
            case "/v2/provider-docs":
                guard value("filter[slug]") == slug, value("filter[category]") == category,
                      value("filter[language]") == "hcl" else { return Data(#"{"data":[]}"#.utf8) }
                return Data(#"{"data":[{"id":"900\#(value("filter[provider-version]") ?? "")"}]}"#.utf8)
            default:
                let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content], options: []), encoding: .utf8)!
                    .dropFirst().dropLast()
                return Data(#"{"data":{"attributes":{"content":\#(escaped)}}}"#.utf8)
            }
        }
    }

    func testPrefersLockedVersionWhenItExists() async {
        stubProvider(versions: [("11", "5.1.0"), ("12", "5.10.0"), ("13", "5.2.0")], slug: "db_instance",
                     category: "resources", content: "---\ntitle: x\n---\n# aws_db_instance\n")
        let docs = model()
        await docs.load(providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_db_instance",
                        mode: "managed", preferredVersion: "5.2.0")
        XCTAssertEqual(docs.document?.version, "5.2.0")
        XCTAssertEqual(docs.document?.url.absoluteString,
                       "https://registry.terraform.io/providers/hashicorp/aws/5.2.0/docs/resources/db_instance")
        XCTAssertEqual(docs.document?.markdown, "# aws_db_instance")
        XCTAssertNil(docs.message)
    }

    func testFallsBackToNewestVersionBySemver() async {
        stubProvider(versions: [("11", "5.9.0"), ("12", "5.10.0"), ("13", "6.0.0-beta1"), ("14", "5.2.0")], slug: "db_instance",
                     category: "resources", content: "body")
        let docs = model()
        await docs.load(providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_db_instance",
                        mode: "managed", preferredVersion: "9.9.9")
        XCTAssertEqual(docs.document?.version, "6.0.0-beta1")
        TerraformRegistryDocsModel.clearCache()
        let stable = [("11", "5.9.0"), ("12", "5.10.0"), ("14", "5.2.0")]
        XCTAssertEqual(TerraformRegistryDocsModel.chooseVersion(stable, preferred: nil)?.version, "5.10.0")
    }

    func testDataSourceSlugAndCategory() async {
        stubProvider(versions: [("11", "5.1.0")], slug: "caller_identity", category: "data-sources", content: "data")
        let docs = model()
        await docs.load(providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_caller_identity",
                        mode: "data", preferredVersion: nil)
        XCTAssertEqual(docs.document?.url.lastPathComponent, "caller_identity")
        XCTAssertTrue(docs.document?.url.path.contains("/docs/data-sources/") == true)
        XCTAssertEqual(TerraformRegistryDocsModel.slug(resourceType: "aws_db_instance", providerName: "aws"), "db_instance")
        XCTAssertEqual(TerraformRegistryDocsModel.slug(resourceType: "random_pet", providerName: "aws"), "random_pet")
    }

    func testRejectsNonRegistryIdentityAndReportsPlainMessage() async {
        let docs = model()
        await docs.load(providerIdentity: "example.com/acme/thing", resourceType: "thing_a", mode: "managed", preferredVersion: nil)
        XCTAssertNil(docs.document)
        XCTAssertEqual(docs.message, "Registry documentation isn't available for thing_a.")
        XCTAssertTrue(RegistryStub.requests.isEmpty)

        RegistryStub.handler = nil
        await docs.load(providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_vpc",
                        mode: "managed", preferredVersion: nil)
        XCTAssertEqual(docs.message, "Couldn't reach the Terraform Registry.")
    }

    func testFrontMatterAndSectionSplitting() {
        let markdown = "---\nsubcategory: \"RDS\"\n---\n\n# aws_db_instance\n\nIntro.\n\n## Argument Reference\n\n* `name`\n\n```\n## not a heading\n```\n\n## Attribute Reference\n\n* `arn`\n"
        let stripped = TerraformRegistryDocsModel.stripFrontMatter(markdown)
        XCTAssertTrue(stripped.hasPrefix("# aws_db_instance"))
        let sections = TerraformRegistryDocsModel.sections(from: stripped)
        XCTAssertEqual(sections.map(\.title), ["Overview", "Argument Reference", "Attribute Reference"])
        XCTAssertTrue(sections[1].body.contains("## not a heading"))
        XCTAssertEqual(sections[2].body, "* `arn`")
        XCTAssertEqual(TerraformRegistryDocsModel.stripFrontMatter("no front matter"), "no front matter")
    }

    func testResponsesOverTwoMebibytesAreRejected() async {
        stubProvider(versions: [("11", "5.1.0")], slug: "db_instance", category: "resources",
                     content: String(repeating: "a", count: 2 * 1_024 * 1_024 + 10))
        let docs = model()
        await docs.load(providerIdentity: "registry.terraform.io/hashicorp/aws", resourceType: "aws_db_instance",
                        mode: "managed", preferredVersion: nil)
        XCTAssertNil(docs.document)
        XCTAssertEqual(docs.message, "Registry documentation isn't available for aws_db_instance.")
    }
}

private final class RegistryStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URL) -> Data)?
    nonisolated(unsafe) static var requests: [URL] = []
    static func reset() { handler = nil; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        Self.requests.append(url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/vnd.api+json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: handler(url))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
