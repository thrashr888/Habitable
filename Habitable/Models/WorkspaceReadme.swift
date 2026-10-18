import Foundation

struct WorkspaceReadme: Sendable {
    let file: URL
    let root: URL
    let content: String
    var isMarkdown: Bool { ["md", "markdown"].contains(file.pathExtension.lowercased()) }
    static let maximumBytes = 512 * 1024

    static func load(directory: URL) throws -> Self? {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var ancestor = directory
        var repository: URL?
        for _ in 0..<128 {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                repository = ancestor
                break
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        let root = repository ?? directory
        let folders = root == directory ? [root] : [root, directory]
        let names = ["readme.md", "readme.markdown", "readme", "readme.txt"]
        for folder in folders {
            let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            for name in names {
                for candidate in children.filter({ $0.lastPathComponent.lowercased() == name }).sorted(by: { $0.path < $1.path }) {
                    let file = candidate.resolvingSymlinksInPath()
                    guard contains(file, in: root), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                    guard data.count <= maximumBytes else { throw ReadmeError.tooLarge }
                    guard let content = String(data: data, encoding: .utf8) else { throw ReadmeError.invalidEncoding }
                    return Self(file: file, root: root, content: content)
                }
            }
        }
        return nil
    }

    enum LinkDestination: Equatable {
        case external(URL)
        case editor(URL)
    }

    /// Local links must use an explicitly selected editor, never Launch Services'
    /// default handler, which can execute scripts or launch application bundles.
    static func linkDestination(_ url: URL, relativeTo root: URL) -> LinkDestination? {
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .external(url) }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(file, in: root.resolvingSymlinksInPath()),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return .editor(file)
    }

    private static func contains(_ file: URL, in root: URL) -> Bool {
        file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }

    private enum ReadmeError: LocalizedError {
        case tooLarge, invalidEncoding
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This README is too large to display (512 KB limit). Open it in your editor."
            case .invalidEncoding: "This README could not be read as UTF-8 text."
            }
        }
    }
}
