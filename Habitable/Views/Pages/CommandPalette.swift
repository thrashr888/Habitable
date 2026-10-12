import AppKit
import SwiftUI

/// One thing ⌘K can reach: a resource, a section or an action.
struct CommandPaletteItem: Identifiable {
    enum Group: String, CaseIterable { case resources = "Resources", sections = "Sections", actions = "Actions" }
    let id: String
    let group: Group
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var shortcut: String? = nil
    let action: () -> Void
}

/// ⌘K: reaches every resource, section and action from the keyboard
/// (Exploration E, "List view and ⌘K for power users"). Type to filter,
/// arrows to move, Return to go, Escape to leave.
struct CommandPalette: View {
    let items: [CommandPaletteItem]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var visible: [CommandPaletteItem] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return Array(items.prefix(40)) }
        return items.filter { item in
            let haystack = (item.title + " " + (item.subtitle ?? "") + " " + item.group.rawValue).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.prefix(40).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a resource, section or action", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { choose(highlighted) }
                    .accessibilityLabel("Go to anything")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if visible.isEmpty {
                Text("Nothing matches. Try a resource name, a section like Outputs, or an action like Preview.")
                    .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(CommandPaletteItem.Group.allCases, id: \.self) { group in
                                let rows = visible.enumerated().filter { $0.element.group == group }
                                if !rows.isEmpty {
                                    Text(group.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                                    ForEach(rows, id: \.offset) { index, item in
                                        Button { choose(index) } label: { row(item, highlighted: index == highlighted) }
                                            .buttonStyle(.plain).id(index)
                                            .onHover { if $0 { highlighted = index } }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: highlighted) { index in proxy.scrollTo(index) }
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _ in highlighted = 0 }
        .background(KeyMonitor { event in
            switch event.keyCode {
            case 125: move(1); return true       // down arrow
            case 126: move(-1); return true      // up arrow
            case 53: dismiss(); return true      // escape
            default: return false
            }
        })
    }

    private func row(_ item: CommandPaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol ?? (item.group == .resources ? "square.dashed" : "arrow.right"))
                .font(.system(size: 13)).foregroundStyle(highlighted ? Color.white : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 11, design: item.group == .resources ? .monospaced : .default))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut).font(.system(size: 11)).foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func choose(_ index: Int) {
        guard visible.indices.contains(index) else { return }
        let item = visible[index]
        dismiss()
        item.action()
    }
}

/// Arrow keys and Escape while the palette is up (the deployment target predates
/// `onKeyPress`). The monitor lives only as long as the view.
private struct KeyMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }
    final class Coordinator {
        var handle: (NSEvent) -> Bool
        private var monitor: Any?
        init(handle: @escaping (NSEvent) -> Bool) {
            self.handle = handle
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Reaching the palette from the View menu

private struct OpenCommandPaletteKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    /// Set by each workspace window; View › Go to Anything… (⌘K) calls it.
    var openCommandPalette: (() -> Void)? {
        get { self[OpenCommandPaletteKey.self] }
        set { self[OpenCommandPaletteKey.self] = newValue }
    }
}
