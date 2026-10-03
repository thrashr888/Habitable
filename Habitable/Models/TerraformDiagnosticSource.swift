import Foundation

/// Resolves Terraform diagnostic locations only to files the Configuration browser can open.
enum TerraformDiagnosticSource {
    /// Returns the root configuration's display name after checking path and symlink boundaries.
    static func currentWorkspaceFile(filename: String?, workspaceDirectory: URL?) -> String? {
        guard let filename, !filename.isEmpty, !filename.contains("\0"),
              let workspaceDirectory, workspaceDirectory.isFileURL,
              URLComponents(string: filename)?.scheme == nil else { return nil }

        let root = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let supplied = URL(fileURLWithPath: filename, relativeTo: filename.hasPrefix("/") ? nil : root)
        let candidate = supplied.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent().path == root.path,
              isTerraformConfiguration(candidate),
              let values = try? candidate.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1_048_576 else { return nil }
        return candidate.lastPathComponent
    }

    /// Bounds the requested line only when the user opens the location, avoiding source reads during row rendering.
    static func boundedLine(_ line: Int, in filename: String, workspaceDirectory: URL?) -> Int? {
        guard line > 0,
              let safeFilename = currentWorkspaceFile(filename: filename, workspaceDirectory: workspaceDirectory),
              safeFilename == filename,
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
}
