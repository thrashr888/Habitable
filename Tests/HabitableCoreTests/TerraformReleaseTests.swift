import CryptoKit
import XCTest
@testable import HabitableCore

final class TerraformReleaseTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Habitable releases \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCatalogSelectsStableNativeBuildsInNumericOrder() throws {
        let data = Data(#"{"versions":{"1.9.8":{"builds":[{"os":"darwin","arch":"arm64"}]},"1.16.4":{"builds":[{"os":"darwin","arch":"arm64"}]},"1.17.0-beta2":{"builds":[{"os":"darwin","arch":"arm64"}]},"1.20.0":{"builds":[{"os":"linux","arch":"arm64"}]},"1.0.0":{"builds":[{"os":"darwin","arch":"amd64"}]},"0.14.0":{"builds":[{"os":"darwin","arch":"arm64"}]},"../../other":{"builds":[{"os":"darwin","arch":"arm64"}]}}}"#.utf8)
        XCTAssertEqual(try TerraformReleaseService.parseCatalog(data, architecture: "arm64").map(\.version), ["1.16.4", "1.9.8"])
        XCTAssertEqual(try TerraformReleaseService.parseCatalog(data, architecture: "amd64").map(\.version), ["1.0.0"])
        XCTAssertThrowsError(try TerraformReleaseService.parseCatalog(Data(#"{"versions":{}}"#.utf8), architecture: "arm64"))
    }

    func testChecksumRequiresExactFilenameAndMatchingContents() throws {
        let data = Data("archive".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sums = Data("\(digest)  terraform.zip\n".utf8)
        XCTAssertNoThrow(try TerraformReleaseService.verify(data, checksums: sums, filename: "terraform.zip"))
        XCTAssertThrowsError(try TerraformReleaseService.verify(Data("corrupt".utf8), checksums: sums, filename: "terraform.zip"))
        XCTAssertThrowsError(try TerraformReleaseService.verify(data, checksums: sums, filename: "different.zip"))
        XCTAssertThrowsError(try TerraformReleaseService.verify(data, checksums: sums + sums, filename: "terraform.zip"))
    }

    private func archive(version: String) throws -> Data {
        let executable = directory.appendingPathComponent("terraform")
        try "#!/bin/sh\nprintf '%s\\n' '{\"terraform_version\":\"\(version)\"}'\n".write(to: executable, atomically: true, encoding: .utf8)
        let zip = directory.appendingPathComponent(UUID().uuidString + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-q", zip.path, executable.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: zip)
    }

    private func service(archive: Data, checksum: String? = nil) -> TerraformReleaseService {
        let digest = checksum ?? SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        return TerraformReleaseService(directory: directory.appendingPathComponent("installs"), architecture: "arm64") { url in
            XCTAssertEqual(url.host, "releases.hashicorp.com")
            XCTAssertEqual(url.scheme, "https")
            if url.lastPathComponent.hasSuffix("SHA256SUMS") {
                return Data("\(digest)  terraform_1.16.4_darwin_arm64.zip\n".utf8)
            }
            XCTAssertEqual(url.lastPathComponent, "terraform_1.16.4_darwin_arm64.zip")
            return archive
        }
    }

    func testInstallVerifiesExecutableAndKeepsAnOfflineCopy() async throws {
        let installer = service(archive: try archive(version: "1.16.4"))
        let executable = try await installer.install(TerraformRelease(version: "1.16.4"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(installer.installedReleases().map(\.version), ["1.16.4"])
        let offline = TerraformReleaseService(directory: installer.directory, architecture: "arm64") { _ in
            throw URLError(.notConnectedToInternet)
        }
        let cached = try await offline.install(TerraformRelease(version: "1.16.4"))
        XCTAssertEqual(cached, executable)
    }

    func testBadChecksumNeverPublishesExecutable() async throws {
        let installer = service(archive: try archive(version: "1.16.4"), checksum: String(repeating: "0", count: 64))
        do {
            _ = try await installer.install(TerraformRelease(version: "1.16.4"))
            XCTFail("Expected checksum rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("checksum")) }
        XCTAssertFalse(installer.isInstalled(version: "1.16.4"))
    }

    func testInvalidArchiveNeverPublishesExecutable() async throws {
        let installer = service(archive: Data("not a zip archive".utf8))
        do {
            _ = try await installer.install(TerraformRelease(version: "1.16.4"))
            XCTFail("Expected extraction failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be extracted")) }
        XCTAssertFalse(installer.isInstalled(version: "1.16.4"))
    }

    @MainActor
    func testOfflineCatalogKeepsInstalledVersionsAvailable() async throws {
        let installer = service(archive: try archive(version: "1.16.4"))
        _ = try await installer.install(TerraformRelease(version: "1.16.4"))
        let offline = TerraformReleaseService(directory: installer.directory, architecture: "arm64") { _ in
            throw URLError(.notConnectedToInternet)
        }
        let catalog = TerraformReleaseCatalog(service: offline)
        await catalog.refresh()
        XCTAssertNotNil(catalog.error)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertEqual(catalog.available.map(\.version), ["1.16.4"])
        let installed = await catalog.install(TerraformRelease(version: "1.16.4"))
        XCTAssertNotNil(installed)
    }

    func testWrongVersionNeverPublishesExecutable() async throws {
        let installer = service(archive: try archive(version: "1.15.0"))
        do {
            _ = try await installer.install(TerraformRelease(version: "1.16.4"))
            XCTFail("Expected executable version rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be verified")) }
        XCTAssertFalse(installer.isInstalled(version: "1.16.4"))
    }

    func testMissingManagedVersionDoesNotFallBackToSystemTerraform() {
        let defaults = UserDefaults(suiteName: "Habitable-test-\(UUID().uuidString)")!
        defaults.set("999.0.0", forKey: TerraformReleaseService.selectionKey)
        defer { defaults.removeObject(forKey: TerraformReleaseService.selectionKey) }
        let selected = TerraformReleaseService.selectedExecutable(defaults: defaults)
        XCTAssertNotNil(selected)
        XCTAssertNil(Runner(executableURL: selected).executableURL)
    }

    @MainActor
    func testSwitchDiscardsPendingPlansAndIsBlockedWhileRunning() async {
        let defaults = UserDefaults(suiteName: "Habitable-test-\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: TerraformReleaseService.selectionKey) }
        let workspace = Workspace(restoreLastDirectory: false, defaults: defaults)
        let run = TerraformRun(workspace: workspace)
        run.status = .planned
        workspace.runs = [run]
        workspace.lock()
        workspace.useTerraform(version: "1.16.4", executableURL: URL(fileURLWithPath: "/missing/terraform"))
        XCTAssertNil(workspace.managedTerraformVersion)
        XCTAssertEqual(run.status, .planned)
        workspace.unlock()
        workspace.useTerraform(version: "1.16.4", executableURL: URL(fileURLWithPath: "/missing/terraform"))
        XCTAssertEqual(run.status, .discarded)
        XCTAssertEqual(defaults.string(forKey: TerraformReleaseService.selectionKey), "1.16.4")
        XCTAssertNil(workspace.runner.executableURL)
    }

    func testOfficialLatestReleaseDownloadsAndRuns() async throws {
        guard ProcessInfo.processInfo.environment["HABITABLE_TEST_RELEASES"] == "1" else {
            throw XCTSkip("Set HABITABLE_TEST_RELEASES=1 to test a real HashiCorp download.")
        }
        let installer = TerraformReleaseService(directory: directory.appendingPathComponent("official"))
        let releases = try await installer.releases()
        let latest = try XCTUnwrap(releases.first)
        let executable = try await installer.install(latest)
        let runner = Runner(executableURL: executable)
        let output: String? = await withCheckedContinuation { continuation in
            runner.version { output, error in
                XCTAssertNil(error)
                continuation.resume(returning: output)
            }
        }
        XCTAssertTrue(try XCTUnwrap(output).contains(latest.version))
        print("Verified official Terraform \(latest.version) for \(installer.architecture)")
    }
}
