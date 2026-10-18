import AppKit
import Combine

struct ExternalEditor: Identifiable, Equatable {
    let id: String
    let name: String
    let applicationURL: URL
}

/// Shared by the window so opening a page does not rescan Launch Services.
@MainActor
final class ExternalEditorStore: ObservableObject {
    @Published private(set) var editors: [ExternalEditor] = []
    @Published private(set) var selectedID: String?
    @Published var error: String?
    private let defaults: UserDefaults
    private let resolve: (String) -> URL?
    private static let preference = "Habitable.externalEditor"
    private static let customPath = "Habitable.externalEditorPath"
    private static let known: [(String, String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("dev.zed.Zed", "Zed"), ("com.exafunction.windsurf", "Windsurf"),
        ("com.sublimetext.4", "Sublime Text"), ("com.panic.Nova", "Nova"),
        ("com.barebones.bbedit", "BBEdit"), ("com.coteditor.CotEditor", "CotEditor"),
        ("com.apple.dt.Xcode", "Xcode")
    ]

    init(defaults: UserDefaults = .standard,
         resolve: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        self.defaults = defaults
        self.resolve = resolve
        selectedID = defaults.string(forKey: Self.preference)
    }

    var selected: ExternalEditor? { editors.first { $0.id == selectedID } }

    func refresh() {
        editors = Self.known.compactMap { id, name in
            resolve(id).map { ExternalEditor(id: id, name: name, applicationURL: $0) }
        }
        if let path = defaults.string(forKey: Self.customPath), let bundle = Bundle(path: path),
           let id = bundle.bundleIdentifier, !editors.contains(where: { $0.id == id }) {
            editors.append(ExternalEditor(id: id, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundle.bundleURL.deletingPathExtension().lastPathComponent,
                applicationURL: bundle.bundleURL))
        }
        // Pick a detected editor once; retain an unavailable preference so a different
        // editor is never silently substituted after the preferred app is removed.
        if selectedID == nil, let first = editors.first { select(first) }
    }

    func select(_ editor: ExternalEditor) {
        selectedID = editor.id
        defaults.set(editor.id, forKey: Self.preference)
    }

    func open(_ file: URL, with editor: ExternalEditor? = nil) {
        guard let editor = editor ?? selected else { return }
        select(editor)
        error = nil
        NSWorkspace.shared.open([file], withApplicationAt: editor.applicationURL,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, failure in
            let message = failure?.localizedDescription
            Task { @MainActor in self?.error = message }
        }
    }

    func chooseApplication(opening file: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose an Editor"
        panel.prompt = "Use Editor"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, let self else { return }
            self.defaults.set(url.path, forKey: Self.customPath)
            self.selectedID = id
            self.defaults.set(id, forKey: Self.preference)
            self.refresh()
            if let file { self.open(file) }
        }
    }
}
