import SwiftUI

private struct QuickHelpModelKey: EnvironmentKey {
    static let defaultValue: QuickHelpModel? = nil
}

extension EnvironmentValues {
    var quickHelpModel: QuickHelpModel? {
        get { self[QuickHelpModelKey.self] }
        set { self[QuickHelpModelKey.self] = newValue }
    }
}

private struct QuickHelpModifier: ViewModifier {
    let entry: QuickHelpEntry
    @Environment(\.quickHelpModel) private var model

    func body(content: Content) -> some View {
        content
            .help(entry.text)
            .onHover { inside in
                guard let model, model.isEnabled else { return }
                if inside { model.show(entry) } else { model.clear(entry) }
            }
    }
}

extension View {
    func quickHelp(_ title: String, _ text: String, url: URL? = nil) -> some View {
        modifier(QuickHelpModifier(entry: QuickHelpEntry(title: title, text: text, learnMoreURL: url)))
    }

    /// Looks up `id` in `QuickHelpGlossary`; an unknown id adds nothing.
    @ViewBuilder
    func quickHelp(glossary id: String) -> some View {
        if let entry = QuickHelpGlossary.entry(id) {
            modifier(QuickHelpModifier(entry: entry))
        } else {
            self
        }
    }
}

/// The card shown while Quick Help is on.
struct QuickHelpPanel: View {
    @ObservedObject var model: QuickHelpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Help")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            if let entry = model.current {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(entry.text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if let url = entry.learnMoreURL {
                    Link(entry.learnMoreTitle, destination: url)
                        .font(.system(size: 13))
                }
            } else {
                Text("Hover anything to learn what it is.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .animation(.easeInOut(duration: 0.12), value: model.current)
    }
}

/// Toolbar toggle for Quick Help.
struct QuickHelpToggle: View {
    @ObservedObject var model: QuickHelpModel

    var body: some View {
        Toggle(isOn: $model.isEnabled) {
            Label("Quick Help", systemImage: "questionmark.circle")
        }
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
        .help("Show a sentence about whatever the pointer is over")
        .keyboardShortcut("/", modifiers: [.command, .shift])
    }
}
