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
    func makeNSView(context: Context) -> MembershipView { MembershipView() }
    func updateNSView(_ view: MembershipView, context: Context) { view.apply() }

    final class MembershipView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window else { return }
            if window.isExcludedFromWindowsMenu { window.isExcludedFromWindowsMenu = false }
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
