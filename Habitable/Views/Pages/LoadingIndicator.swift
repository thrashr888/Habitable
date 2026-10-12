import SwiftUI

/// Habitable's loading mark: three bars rising and settling in turn, in the
/// accent color. Replaces the generic spinner wherever the app waits on
/// Terraform or HCP Terraform. Static under Reduce Motion.
struct LoadingIndicator: View {
    var size: CGFloat = 20
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: size * 0.18) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: size * 0.12)
                        .fill(Color.accentColor)
                        .frame(width: size * 0.22, height: size * barScale(index))
                        .opacity(0.55 + 0.45 * barScale(index))
                }
            }
            .frame(width: size, height: size, alignment: .bottom)
            if let label {
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Loading")
        .onAppear {
            guard !reduceMotion else { phase = 0.5; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 }
        }
    }

    /// Each bar lags the previous one so the three read as a wave, not a blink.
    private func barScale(_ index: Int) -> Double {
        let offset = Double(index) * 0.33
        let value = (sin((phase + offset) * .pi) + 1) / 2
        return 0.35 + 0.65 * value
    }
}

/// Keeps every Habitable window in the Window menu. SwiftUI's single `Window`
/// scenes otherwise leave the menu's window list incomplete.
struct WindowMenuMembership: NSViewRepresentable {
    /// The folder this window shows, when it shows one. It becomes the window's
    /// represented file, so a second request to open the folder finds this window.
    var folder: URL? = nil
    /// Workspace windows draw their own title control in the toolbar.
    var hidesTitle = false

    func makeNSView(context: Context) -> MembershipView { MembershipView() }
    func updateNSView(_ view: MembershipView, context: Context) { view.folder = folder; view.hidesTitle = hidesTitle; view.apply() }

    final class MembershipView: NSView {
        var folder: URL?
        var hidesTitle = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window else { return }
            if window.isExcludedFromWindowsMenu { window.isExcludedFromWindowsMenu = false }
            if window.representedURL != folder { window.representedURL = folder }
            // SwiftUI re-applies its own title settings after navigationTitle changes;
            // set ours now and again once those have landed.
            let visibility: NSWindow.TitleVisibility = hidesTitle ? .hidden : .visible
            for delay in [0.0, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window, window.titleVisibility != visibility else { return }
                    window.titleVisibility = visibility
                }
            }
            // One window per folder, also across restoration: a second window for the
            // same folder (left over from an earlier session) closes itself.
            if let folder {
                let mine = folder.standardizedFileURL
                // Restored windows get their represented files one by one; check now and
                // again once restoration has settled.
                for delay in [0.0, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                        guard let window, window.representedURL?.standardizedFileURL == mine else { return }
                        // Only the newer window yields, so two twins never close each other.
                        let hasOlderTwin = NSApp.windows.contains {
                            $0 !== window && $0.isVisible && $0.windowNumber < window.windowNumber
                                && $0.representedURL?.standardizedFileURL == mine
                        }
                        if hasOlderTwin { window.close() }
                    }
                }
            }
        }
    }
}

/// A filter field with the search glass and a clear button once there is text.
struct FilterField: View {
    let placeholder: String
    @Binding var text: String
    var accessibilityLabel: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
                .accessibilityLabel(accessibilityLabel ?? placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear \(placeholder.lowercased())")
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A disclosure whose whole header toggles it, not only the chevron.
struct HeaderDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isExpanded ? [.isSelected] : [])
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }
}


/// A button that fires only after being held, like Delete in Photos. Used
/// where a preview would replace or remove something (Exploration C).
struct HoldToConfirmButton: View {
    let title: String
    var holdSeconds: Double = 1.2
    let action: () -> Void
    @State private var progress = 0.0
    @State private var holding = false
    @State private var timer: Timer?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
            }
            Text(holding ? "Keep holding…" : title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(maxWidth: .infinity)
        }
        .frame(height: 24).fixedSize(horizontal: true, vertical: false)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .gesture(LongPressGesture(minimumDuration: holdSeconds).onEnded { _ in finish() }
            .simultaneously(with: DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { start() } }
                .onEnded { _ in if progress < 1 { cancel() } }))
        .help("Press and hold to \(title.lowercased())")
        .accessibilityLabel(title)
        .accessibilityHint("Press and hold")
        .accessibilityAction { action() }
    }

    private func start() {
        holding = true
        progress = 0
        timer?.invalidate()
        let step = 0.02 / holdSeconds
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            Task { @MainActor in
                progress = min(1, progress + step)
                withAnimation(.linear(duration: 0.02)) {}
            }
        }
    }

    private func cancel() {
        timer?.invalidate(); timer = nil
        withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
        holding = false
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        progress = 1
        holding = false
        action()
        withAnimation(.easeOut(duration: 0.3)) { progress = 0 }
    }
}

/// The workspace's name and where it lives, at the start of every workspace
/// window's title bar (INFORMATION-ARCHITECTURE.md §A). The window's own title
/// is hidden; this control is the title. Neutral folder for this Mac, blue cloud
/// for HCP Terraform, in the same spot in both windows.
struct WorkspaceTitleControl: View {
    enum Kind: Equatable { case thisMac, cloud }
    let kind: Kind
    let name: String
    let subtitle: String
    /// A chevron marks a control that switches workspaces.
    var switches = false

    private var symbol: String { kind == .thisMac ? "folder.fill" : "cloud.fill" }
    private var tint: Color { kind == .thisMac ? Color.secondary : Color(red: 0.16, green: 0.45, blue: 0.95) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if switches { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(subtitle)")
    }
}

/// A link that leaves the app, with the outbound arrow so nobody is surprised
/// (WRITING.md: say where a control goes). Used for every link into HCP
/// Terraform, the Registry and GitHub.
struct ExternalLink: View {
    let title: String
    let url: URL
    var font: Font = .system(size: 13)

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
            }
            .font(font)
        }
        .buttonStyle(.link)
        .help(url.absoluteString)
        .accessibilityLabel("\(title), opens in your browser")
    }
}

/// A mode announces itself: its title on the left and one way out on the right,
/// always in the same place (INFORMATION-ARCHITECTURE.md §E).
struct ModeBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let exitTitle: String
    let onExit: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, exitTitle: String, onExit: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.exitTitle = exitTitle; self.onExit = onExit; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            trailing()
            Button(exitTitle, action: onExit).buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// "Ask Claude" (design: "Claude, built in"): hands a question about a resource
/// to Claude with the prompt on the clipboard, in the Claude app when it is
/// installed and otherwise at claude.ai. Claude can read the workspace through
/// Habitable's agent access when that is on; its code changes come back as a
/// Preview you review on the Map like any other.
enum ClaudeHandoff {
    static let appBundleID = "com.anthropic.claudefordesktop"

    static var isAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) != nil
    }

    static func ask(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            var components = URLComponents(string: "https://claude.ai/new")!
            components.queryItems = [URLQueryItem(name: "q", value: prompt)]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
    }

    /// The question, built from what the Inspector knows. Values stay out: Claude
    /// gets addresses, types and the shape of the change, never secrets.
    static func prompt(workspace: String, source: String, address: String, type: String,
                       change: String?, drift: String?, agentAccess: Bool) -> String {
        var lines = ["I'm looking at the Terraform resource `\(address)` (`\(type)`) in the workspace \(workspace) (\(source)) in Habitable."]
        if let change { lines.append("Preview Changes says: \(change).") }
        if let drift { lines.append("It drifted: \(drift).") }
        lines.append(change?.contains("replace") == true
                     ? "Explain why Terraform wants to replace it and draft the code change that avoids the replacement, if one exists."
                     : "Explain what this resource does here and anything I should know before changing it.")
        if agentAccess {
            lines.append("You can read this workspace's declarations, state metadata and runs through Habitable's agent access (MCP server \"habitable\"). If you change files, ask Habitable to plan so I can review the change on the Map; never apply.")
        } else {
            lines.append("Keep suggestions as code I can paste; nothing is applied from this conversation.")
        }
        return lines.joined(separator: "\n")
    }
}
