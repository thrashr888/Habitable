import Foundation

/// A bounded, best-effort snapshot. Missing Git metadata never prevents a run.
struct RunGitContext: Equatable, Sendable {
    let branch: String?
    let commit: String

    static func capture(directory: URL) -> Self? {
        var root = directory.standardizedFileURL
        for _ in 0..<128 {
            let marker = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let git: URL
                if isDirectory.boolValue {
                    git = marker
                } else if let pointer = read(marker), pointer.hasPrefix("gitdir: ") {
                    git = URL(fileURLWithPath: String(pointer.dropFirst(8)), relativeTo: root).standardizedFileURL
                } else { return nil }
                return capture(gitDirectory: git)
            }
            guard root.path != "/", !root.path.isEmpty else { return nil }
            let parent = root.deletingLastPathComponent().standardizedFileURL
            guard parent.path != root.path else { return nil }
            root = parent
        }
        return nil
    }

    private static func capture(gitDirectory: URL) -> Self? {
        guard let head = read(gitDirectory.appendingPathComponent("HEAD")) else { return nil }
        if isCommit(head) { return Self(branch: nil, commit: head) }
        guard head.hasPrefix("ref: refs/heads/") else { return nil }
        let reference = String(head.dropFirst(5))
        guard !reference.contains(".."), !reference.contains("\\"), !reference.contains("\n") else { return nil }
        let common = read(gitDirectory.appendingPathComponent("commondir"))
            .map { URL(fileURLWithPath: $0, relativeTo: gitDirectory).standardizedFileURL } ?? gitDirectory
        let branch = String(reference.dropFirst("refs/heads/".count))
        if let commit = read(common.appendingPathComponent(reference)), isCommit(commit) {
            return Self(branch: branch, commit: commit)
        }
        if let packed = read(common.appendingPathComponent("packed-refs"), limit: 2 * 1024 * 1024) {
            for line in packed.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[1] == reference, isCommit(String(parts[0])) {
                    return Self(branch: branch, commit: String(parts[0]))
                }
            }
        }
        return nil
    }

    private static func isCommit(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit }
    }

    private static func read(_ file: URL, limit: Int = 8192) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
