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

    func makeNSView(context: Context) -> MembershipView { MembershipView() }
    func updateNSView(_ view: MembershipView, context: Context) { view.folder = folder; view.apply() }

    final class MembershipView: NSView {
        var folder: URL?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window else { return }
            if window.isExcludedFromWindowsMenu { window.isExcludedFromWindowsMenu = false }
            if window.representedURL != folder { window.representedURL = folder }
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

/// Where a workspace lives, at the start of every workspace window's title bar
/// (docs/design/INFORMATION-ARCHITECTURE.md §A). Neutral for this Mac, blue for
/// HCP Terraform; the same spot in both windows so the eye learns it once.
struct SourceBadge: View {
    enum Kind: Equatable {
        case thisMac
        case cloud(organization: String)
    }
    let kind: Kind
    var action: (() -> Void)? = nil

    private var title: String {
        switch kind {
        case .thisMac: "This Mac"
        case .cloud(let organization): organization.isEmpty ? "HCP Terraform" : organization
        }
    }
    private var symbol: String { kind == .thisMac ? "folder.fill" : "cloud.fill" }
    private var tint: Color { kind == .thisMac ? Color.secondary : Color(red: 0.16, green: 0.45, blue: 0.95) }
    private var help: String {
        switch kind {
        case .thisMac: "This workspace is a folder on this Mac. Open the Library to see every workspace."
        case .cloud: "This workspace lives in HCP Terraform. Open the Library to see every workspace."
        }
    }

    var body: some View {
        Button(action: { action?() }) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(tint.opacity(0.14), in: Capsule())
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .help(help)
        .accessibilityLabel("Workspace source: \(title)")
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
