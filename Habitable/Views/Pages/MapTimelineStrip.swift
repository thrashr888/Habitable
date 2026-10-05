import SwiftUI

/// Timeline of recorded changes along the bottom of the workspace window.
/// Shows run provenance only; it never implies historical map state.
struct MapTimelineStrip: View {
    let clips: [MapChangeClip]
    let selectedID: String?
    let hint: String
    let onSelect: (MapChangeClip) -> Void
    var onShowAll: (() -> Void)? = nil

    private static let height: CGFloat = 142

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if clips.isEmpty {
                Text("No changes recorded yet. Preview Changes starts the first one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                strip
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: Self.height)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Changes").font(.headline)
            Text(MapTimelinePresentation.summary(for: clips)).foregroundStyle(.secondary)
            Spacer()
            Text(hint).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            if let onShowAll {
                Button("All changes", action: onShowAll)
                    .buttonStyle(.link)
                    .font(.system(size: 13))
            }
        }
    }

    private var strip: some View {
        let groups = MapTimelinePresentation.dateGroups(for: clips)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Every card carries its day so a label stays visible wherever the
                // strip is scrolled; repeats within a day are dimmed.
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                        ForEach(Array(group.clips.enumerated()), id: \.element.id) { clipIndex, clip in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                    .opacity(clipIndex == 0 ? 1 : 0.7)
                                card(for: clip)
                            }
                            .id(clip.id)
                            .padding(.leading, groupIndex > 0 && clipIndex == 0 ? 8 : 0)
                        }
                    }
                }
            }
            .onAppear { scrollToSelection(proxy) }
            .onChange(of: selectedID) { _ in scrollToSelection(proxy) }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        proxy.scrollTo(selectedID, anchor: .trailing)
    }

    private func card(for clip: MapChangeClip) -> some View {
        let selected = clip.id == selectedID
        return Button { onSelect(clip) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .opacity(clip.isApplied ? 1 : 0.75)
                countsLine(for: clip)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 92, maxWidth: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: clip))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func countsLine(for clip: MapChangeClip) -> some View {
        let parts = clip.countParts
        HStack(spacing: 5) {
            if !clip.hasRecordedCounts {
                Text(clip.status)
                    .foregroundStyle(clip.status == RunStatus.errored.displayTitle ? Color.red : Color.secondary)
            } else if parts.isEmpty {
                Text("No changes").foregroundStyle(.secondary)
            } else {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Text(part.text).foregroundStyle(color(for: part.kind))
                }
            }
            if let author = clip.author, !author.isEmpty {
                Text("· by \(author)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    private func color(for kind: MapChangeClip.CountKind) -> Color {
        switch kind {
        case .added: .green
        case .changed: .orange
        case .destroyed: .red
        }
    }

    private func accessibilityLabel(for clip: MapChangeClip) -> String {
        var parts = ["Change: \(clip.title)"]
        parts.append(clip.hasRecordedCounts ? clip.countsSummary : clip.status)
        if let date = clip.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: ", ")
    }
}

/// The Changes face of the Map's right pane: the same recorded runs as the
/// Timeline strip, newest first, one row each.
struct MapChangesList: View {
    let clips: [MapChangeClip]          // chronological, oldest first (same input as the strip)
    let selectedID: String?
    let onSelect: (MapChangeClip) -> Void
    var onShowAll: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if clips.isEmpty {
                Text("No changes recorded yet. Preview Changes starts the first one.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(clips.reversed()) { clip in
                            Button { onSelect(clip) } label: { row(clip) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Change: \(clip.title), \(clip.countsSummary.isEmpty ? clip.status : clip.countsSummary)")
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            if let onShowAll {
                Divider()
                Button("All changes", action: onShowAll).buttonStyle(.link).font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private func row(_ clip: MapChangeClip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(statusColor(clip)).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let date = clip.date { Text(date, format: .relative(presentation: .named)) }
                    if clip.hasRecordedCounts { Text("·"); Text(clip.countsSummary) } else { Text("·"); Text(clip.status) }
                }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedID == clip.id ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
    }

    private func statusColor(_ clip: MapChangeClip) -> Color {
        if clip.isApplied { return .green }
        switch clip.status.lowercased() {
        case let s where s.contains("error"): return .red
        case let s where s.contains("planning") || s.contains("applying") || s.contains("pending") || s.contains("confirmed"): return .orange
        default: return .secondary
        }
    }
}
