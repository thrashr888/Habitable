import Foundation

/// Resolves Terraform diagnostic locations only to files the Configuration browser can open.
enum TerraformDiagnosticSource {
    private static let excludedDirectories = Set([".terraform", ".git", "vendor", ".terraform.d"])

    /// Returns a workspace-relative display path after checking every path component.
    static func currentWorkspaceFile(filename: String?, workspaceDirectory: URL?) -> String? {
        guard let filename, !filename.isEmpty, !filename.contains("\0"),
              let workspaceDirectory, workspaceDirectory.isFileURL,
              URLComponents(string: filename)?.scheme == nil,
              !filename.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }

        let root = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let supplied = URL(fileURLWithPath: filename, relativeTo: filename.hasPrefix("/") ? nil : root)
        let candidate = supplied.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              let relative = safeRelativePath(candidate, root: root),
              isTerraformConfiguration(candidate),
              let values = try? candidate.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1_048_576 else { return nil }
        return relative
    }

    /// Bounds the requested line only when the user opens the location, avoiding source reads during row rendering.
    static func boundedLine(_ line: Int, in filename: String, workspaceDirectory: URL?) -> Int? {
        guard line > 0,
              let safeFilename = currentWorkspaceFile(filename: filename, workspaceDirectory: workspaceDirectory),
              let root = workspaceDirectory?.standardizedFileURL.resolvingSymlinksInPath(),
              let contents = try? String(contentsOf: root.appendingPathComponent(safeFilename), encoding: .utf8) else {
            return nil
        }
        let lineCount = contents.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return min(line, lineCount)
    }

    private static func isTerraformConfiguration(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasSuffix(".tf") || url.lastPathComponent.hasSuffix(".tf.json"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    private static func safeRelativePath(_ candidate: URL, root: URL) -> String? {
        let relative = String(candidate.path.dropFirst(root.path.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= 8,
              !components.contains(where: { $0.hasPrefix(".") || excludedDirectories.contains($0) }) else { return nil }
        var current = root
        for component in components {
            current.appendPathComponent(component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  current.resolvingSymlinksInPath().path == current.standardizedFileURL.path else { return nil }
        }
        return relative
    }
}
