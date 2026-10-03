import Combine
import CryptoKit
import Foundation

struct TerraformRelease: Identifiable, Equatable, Sendable {
    let version: String
    var id: String { version }

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, (part.count == 1 || part.first != "0"),
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }

    static func newestFirst(_ lhs: TerraformRelease, _ rhs: TerraformRelease) -> Bool {
        (components(rhs.version) ?? []).lexicographicallyPrecedes(components(lhs.version) ?? [])
    }
}

struct TerraformReleaseError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Uses the machine-readable catalog behind HashiCorp's official releases page.
struct TerraformReleaseService: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data
    typealias ProgressHandler = @MainActor @Sendable (String) async -> Void

    static let sourceURL = URL(string: "https://releases.hashicorp.com/terraform/")!
    static let selectionKey = "managedTerraformVersion"
    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "amd64"
    #endif
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Habitable/Terraform", isDirectory: true)

    let directory: URL
    let architecture: String
    let fetch: Fetch

    init(directory: URL = Self.defaultDirectory, architecture: String = Self.architecture,
         fetch: @escaping Fetch = TerraformReleaseService.download) {
        self.directory = directory
        self.architecture = architecture
        self.fetch = fetch
    }

    private struct Index: Decodable {
        struct Release: Decodable {
            struct Build: Decodable { let os: String; let arch: String }
            let builds: [Build]?
        }
        let versions: [String: Release]
    }

    static func parseCatalog(_ data: Data, architecture: String) throws -> [TerraformRelease] {
        let index = try JSONDecoder().decode(Index.self, from: data)
        let releases = index.versions.compactMap { version, value -> TerraformRelease? in
            guard let components = TerraformRelease.components(version),
                  !components.lexicographicallyPrecedes([0, 15, 0]),
                  value.builds?.contains(where: { $0.os == "darwin" && $0.arch == architecture }) == true else { return nil }
            return TerraformRelease(version: version)
        }.sorted(by: TerraformRelease.newestFirst)
        guard !releases.isEmpty else {
            throw TerraformReleaseError(message: "No compatible stable Terraform releases were found for this Mac.")
        }
        return releases
    }

    func releases() async throws -> [TerraformRelease] {
        try Self.parseCatalog(try await fetch(Self.sourceURL.appendingPathComponent("index.json")), architecture: architecture)
    }

    func executableURL(version: String) -> URL {
        directory.appendingPathComponent(version).appendingPathComponent(architecture).appendingPathComponent("terraform")
    }

    static func selectedExecutable(defaults: UserDefaults = .standard) -> URL? {
        guard let version = defaults.string(forKey: selectionKey), TerraformRelease.components(version) != nil else { return nil }
        // Keep the selected path even if missing so the runner reports an error instead of silently changing versions.
        return Self().executableURL(version: version)
    }

    func installedReleases() -> [TerraformRelease] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { TerraformRelease.components($0) != nil && isInstalled(version: $0) }
            .map { TerraformRelease(version: $0) }.sorted(by: TerraformRelease.newestFirst)
    }

    func isInstalled(version: String) -> Bool {
        guard TerraformRelease.components(version) != nil else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL(version: version).path)
    }

    static func verify(_ archive: Data, checksums: Data, filename: String) throws {
        let matches = String(decoding: checksums, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == Substring(filename) || fields[1] == Substring("*" + filename) else { return nil }
            return String(fields[0]).lowercased()
        }
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard matches.count == 1, matches[0] == actual else {
            throw TerraformReleaseError(message: "Terraform's download did not match HashiCorp's SHA-256 checksum. Your current version has not changed. Try downloading again.")
        }
    }

    func install(_ release: TerraformRelease, progress: @escaping ProgressHandler = { _ in }) async throws -> URL {
        guard TerraformRelease.components(release.version) != nil, ["arm64", "amd64"].contains(architecture) else {
            throw TerraformReleaseError(message: "Invalid Terraform release or Mac architecture.")
        }
        if isInstalled(version: release.version) { return executableURL(version: release.version) }
        let filename = "terraform_\(release.version)_darwin_\(architecture).zip"
        let base = Self.sourceURL.appendingPathComponent(release.version)
        await progress("Downloading Terraform \(release.version)…")
        let checksums = try await fetch(base.appendingPathComponent("terraform_\(release.version)_SHA256SUMS"))
        let archive = try await fetch(base.appendingPathComponent(filename))
        await progress("Verifying download…")
        try Self.verify(archive, checksums: checksums, filename: filename)
        try Task.checkCancellation()
        await progress("Installing Terraform \(release.version)…")
        // Extraction and version probing can block, so keep them off the UI actor.
        let target = executableURL(version: release.version)
        return try await Task.detached {
            try Self.extract(archive, to: target, expectedVersion: release.version)
            return target
        }.value
    }

    private static func extract(_ archive: Data, to target: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let zip = staging.appendingPathComponent("archive.zip")
        let executable = staging.appendingPathComponent("terraform")
        try archive.write(to: zip)
        fm.createFile(atPath: executable.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: executable)
        defer { try? output.close() }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // Extract only the expected entry into an explicit file; never trust archive paths.
        unzip.arguments = ["-p", zip.path, "terraform"]
        unzip.standardInput = FileHandle.nullDevice
        unzip.standardOutput = output
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        try output.close()
        guard unzip.terminationStatus == 0 else {
            throw TerraformReleaseError(message: "The Terraform archive could not be extracted. Your current version has not changed.")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let versionOutput = staging.appendingPathComponent("version.json")
        fm.createFile(atPath: versionOutput.path, contents: nil)
        let versionHandle = try FileHandle(forWritingTo: versionOutput)
        defer { try? versionHandle.close() }
        let probe = Process()
        probe.executableURL = executable
        probe.arguments = ["version", "-json"]
        probe.environment = ["CHECKPOINT_DISABLE": "1"]
        probe.currentDirectoryURL = staging
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = versionHandle
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        struct Version: Decodable { let terraform_version: String }
        let reported = try? JSONDecoder().decode(Version.self, from: Data(contentsOf: versionOutput))
        guard probe.terminationStatus == 0, reported?.terraform_version == expectedVersion else {
            throw TerraformReleaseError(message: "The downloaded Terraform executable could not be verified as version \(expectedVersion).")
        }
        // Publish only a complete, verified executable with an atomic move or replacement.
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: executable)
        } else {
            try fm.moveItem(at: executable, to: target)
        }
    }

    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == "releases.hashicorp.com",
              (200..<300).contains(http.statusCode) else {
            throw TerraformReleaseError(message: "HashiCorp's release server could not provide \(url.lastPathComponent). Please try again.")
        }
        return data
    }
}

@MainActor
final class TerraformReleaseCatalog: ObservableObject {
    @Published var releases: [TerraformRelease] = [] { didSet { updateAvailable() } }
    @Published var installed: [TerraformRelease] = [] { didSet { updateAvailable() } }
    @Published private(set) var available: [TerraformRelease] = []
    @Published var isLoading = false
    @Published var isInstalling = false
    @Published var status: String?
    @Published var error: String?
    let service: TerraformReleaseService
    private var lastRefresh: Date?

    init(service: TerraformReleaseService = TerraformReleaseService()) {
        self.service = service
    }

    private func updateAvailable() {
        available = Array(Set((releases + installed).map(\.version))).map { TerraformRelease(version: $0) }
            .sorted(by: TerraformRelease.newestFirst)
    }

    func refreshIfNeeded() async {
        guard lastRefresh.map({ Date().timeIntervalSince($0) < 300 }) != true else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { releases = try await service.releases() }
        catch { if !Task.isCancelled { self.error = "Could not load releases: \(error.localizedDescription)" } }
        let service = service
        installed = await Task.detached(priority: .utility) { service.installedReleases() }.value
        if !Task.isCancelled { lastRefresh = Date() }
    }

    func install(_ release: TerraformRelease) async -> URL? {
        guard !isInstalling else { return nil }
        isInstalling = true
        error = nil
        defer { isInstalling = false; status = nil }
        do {
            let url = try await service.install(release) { [weak self] message in
                self?.status = message
            }
            let service = service
            installed = await Task.detached(priority: .utility) { service.installedReleases() }.value
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
