import Combine
import Foundation

private final class DefaultsChangeObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter, observer: NSObjectProtocol) {
        self.center = center
        self.observer = observer
    }

    func cancel() {
        lock.lock()
        let token = observer
        observer = nil
        lock.unlock()
        if let token { center.removeObserver(token) }
    }

    deinit { cancel() }
}

/// Stores only local folder paths, never Terraform inputs, descriptions, or state contents.
@MainActor
final class RecentWorkspaceStore: ObservableObject {
    static let defaultsKey = "recentWorkspacePaths"
    static let maximumCount = 10

    @Published private(set) var paths: [String]
    private let defaults: UserDefaults
    private var defaultsObserver: DefaultsChangeObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.paths = Self.normalizedPaths(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        defaults.set(paths, forKey: Self.defaultsKey)
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromDefaults() }
        }
        defaultsObserver = DefaultsChangeObservation(center: .default, observer: observer)
    }

    deinit {
        defaultsObserver?.cancel()
    }

    var folders: [URL] { paths.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func recordSuccessfulOpen(_ url: URL) {
        paths = Self.normalizedPaths(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        let path = Self.canonicalPath(url)
        paths.removeAll { Self.canonicalPath(URL(fileURLWithPath: $0)) == path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(Self.maximumCount))
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    func clear() {
        paths = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func reloadFromDefaults() {
        let latest = Self.normalizedPaths(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        guard latest != paths else { return }
        paths = latest
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let canonical = canonicalPath(URL(fileURLWithPath: path, isDirectory: true))
            guard seen.insert(canonical).inserted else { return nil }
            return canonical
        }.prefix(maximumCount).map { $0 }
    }
}
