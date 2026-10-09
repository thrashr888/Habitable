import Foundation
import XCTest
@testable import HabitableCore

final class InfrastructureTemplatesTests: XCTestCase {
    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString)")
    }

    func testCategoriesAreInDeclaredOrder() {
        XCTAssertEqual(
            InfrastructureTemplate.Category.allCases.map(\.rawValue),
            ["Websites", "Apps & APIs", "Databases", "Networks", "Learn", "Playground (no cloud)"]
        )
    }

    func testEveryTemplateHasMainReadmeAndVariables() {
        XCTAssertFalse(InfrastructureTemplates.all.isEmpty)
        for template in InfrastructureTemplates.all {
            XCTAssertNotNil(template.files["main.tf"], template.id)
            XCTAssertNotNil(template.files["README.md"], template.id)
            XCTAssertEqual(template.files["variables.tf"] != nil, !template.inputs.isEmpty, template.id)
            XCTAssertTrue(template.files["main.tf"]?.contains("required_providers") ?? false, template.id)
        }
        XCTAssertEqual(Set(InfrastructureTemplates.all.map(\.id)).count, InfrastructureTemplates.all.count)
    }

    func testResourceCountsMatchHCL() throws {
        for template in InfrastructureTemplates.all {
            let main = try XCTUnwrap(template.files["main.tf"])
            let blocks = main.split(separator: "\n").filter { $0.hasPrefix("resource \"") }
            XCTAssertEqual(blocks.count, template.resourceCount, template.id)
            let types = blocks.compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
            XCTAssertEqual(types.sorted(), template.resources.map(\.type).sorted(), template.id)
        }
    }

    func testPlaceholdersReferenceDeclaredInputs() throws {
        let pattern = try NSRegularExpression(pattern: #"\$\{([a-z_]+)\}"#)
        for template in InfrastructureTemplates.all {
            let names = Set(template.inputs.map(\.name))
            var used = Set<String>()
            for (filename, text) in template.files {
                let range = NSRange(text.startIndex..., in: text)
                for match in pattern.matches(in: text, range: range) {
                    let name = String(text[Range(match.range(at: 1), in: text)!])
                    XCTAssertTrue(names.contains(name), "\(template.id)/\(filename) uses ${\(name)}")
                    used.insert(name)
                }
            }
            XCTAssertEqual(used, names, "\(template.id) declares inputs nothing uses")
        }
    }

    func testNoCredentialsInTemplates() {
        for template in InfrastructureTemplates.all {
            for (_, text) in template.files {
                XCTAssertFalse(text.contains("AKIA"), template.id)
                XCTAssertFalse(text.lowercased().contains("secret_key"), template.id)
            }
        }
    }

    func testLookupAndCategories() throws {
        XCTAssertEqual(InfrastructureTemplates.template(id: "static-website")?.title, "Static website")
        XCTAssertNil(InfrastructureTemplates.template(id: "nope"))
        XCTAssertEqual(InfrastructureTemplates.templates(in: .playground).map(\.id), ["playground"])
        XCTAssertTrue(InfrastructureTemplates.templates(in: .websites).count >= 3)
        for category in InfrastructureTemplate.Category.allCases where category != .registry {
            XCTAssertFalse(InfrastructureTemplates.templates(in: category).isEmpty, category.rawValue)
        }
        let playground = try XCTUnwrap(InfrastructureTemplates.template(id: "playground"))
        XCTAssertEqual(playground.estimatedMonthlyCost, "nothing; runs on this Mac")
        XCTAssertEqual(playground.provider, "None")
    }

    func testSuggestedFolderNames() throws {
        let names = InfrastructureTemplates.all.map(InfrastructureTemplates.suggestedFolderName)
        XCTAssertEqual(names.first, "static-website")
        XCTAssertTrue(names.contains("learn-outputs-and-inputs"))
        XCTAssertTrue(names.contains("postgres-database"))
    }

    func testWriteCreatesFilesAndSubstitutesInputs() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = try XCTUnwrap(InfrastructureTemplates.template(id: "static-website"))
        let urls = try InfrastructureTemplates.write(template, to: folder, inputs: ["domain": "rookeryhq.com", "region": " "])

        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["main.tf", "variables.tf", "README.md"])
        let variables = try String(contentsOf: folder.appendingPathComponent("variables.tf"), encoding: .utf8)
        XCTAssertTrue(variables.contains("default     = \"rookeryhq.com\""))
        XCTAssertTrue(variables.contains("default     = \"us-east-1\""), "blank falls back to the example")
        XCTAssertFalse(variables.contains("${"))

        let attributes = try FileManager.default.attributesOfItem(atPath: urls[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testWriteEscapesQuotesInTerraformFiles() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = try XCTUnwrap(InfrastructureTemplates.template(id: "postgres-database"))
        _ = try InfrastructureTemplates.write(template, to: folder, inputs: ["name": "a\"b"])
        let variables = try String(contentsOf: folder.appendingPathComponent("variables.tf"), encoding: .utf8)
        XCTAssertTrue(variables.contains("a\\\"b"))
    }

    func testWriteAllowsEmptyExistingFolderAndRefusesNonEmpty() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let template = try XCTUnwrap(InfrastructureTemplates.template(id: "playground"))
        XCTAssertEqual(try InfrastructureTemplates.write(template, to: folder, inputs: [:]).count, 2)

        XCTAssertThrowsError(try InfrastructureTemplates.write(template, to: folder, inputs: [:])) { error in
            XCTAssertEqual(error as? InfrastructureTemplateError, .folderNotEmpty(folder.path))
        }
    }

    func testWriteCreatesMissingParents() throws {
        let root = tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("infra/learn")
        let template = try XCTUnwrap(InfrastructureTemplates.template(id: "learn-outputs-and-inputs"))
        _ = try InfrastructureTemplates.write(template, to: folder, inputs: ["name": "Ada"])
        let variables = try String(contentsOf: folder.appendingPathComponent("variables.tf"), encoding: .utf8)
        XCTAssertTrue(variables.contains("\"Ada\""))
    }
}
