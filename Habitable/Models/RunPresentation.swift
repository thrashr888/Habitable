import Foundation

extension RunStatus {
    /// Human status text for lists and the workspace Timeline.
    var displayTitle: String {
        switch self {
        case .pending: "Pending"
        case .planning: "Planning"
        case .planned: "Planned"
        case .confirmed: "Confirmed"
        case .applying: "Applying"
        case .applied: "Applied"
        case .discarded: "Discarded"
        case .errored: "Errored"
        case .canceled: "Canceled"
        case .expired: "Expired"
        case .interrupted: "Interrupted"
        }
    }
}

/// One change on the workspace Timeline. Built only from recorded run facts.
struct MapChangeClip: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let date: Date?
    let status: String
    let isApplied: Bool
    let added: Int?
    let changed: Int?
    let destroyed: Int?
    let author: String?
    /// Resources the run's refresh found changed outside Terraform.
    var drifted: Int? = nil

    var hasRecordedCounts: Bool { added != nil || changed != nil || destroyed != nil }

    /// e.g. "+14 ~2 −1" (U+2212 minus). Zero/nil parts are omitted.
    var countsSummary: String {
        guard hasRecordedCounts else { return "" }
        let parts = countParts.map(\.text)
        return parts.isEmpty ? "No changes" : parts.joined(separator: " ")
    }

    enum CountKind: Sendable { case added, changed, destroyed }

    /// Non-zero recorded counts, in display order, for colored rendering.
    var countParts: [(kind: CountKind, text: String)] {
        var parts: [(kind: CountKind, text: String)] = []
        if let added, added > 0 { parts.append((.added, "+\(added)")) }
        if let changed, changed > 0 { parts.append((.changed, "~\(changed)")) }
        if let destroyed, destroyed > 0 { parts.append((.destroyed, "\u{2212}\(destroyed)")) }
        return parts
    }

    static func == (lhs: MapChangeClip, rhs: MapChangeClip) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.date == rhs.date
            && lhs.status == rhs.status && lhs.isApplied == rhs.isApplied
            && lhs.added == rhs.added && lhs.changed == rhs.changed
            && lhs.destroyed == rhs.destroyed && lhs.author == rhs.author
    }
}

enum MapTimelinePresentation {
    private static func label(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    /// Header line, e.g. "12 applied since Sep 2".
    static func summary(for clips: [MapChangeClip], now: Date = Date(), calendar: Calendar = .current) -> String {
        let applied = clips.filter(\.isApplied)
        guard !applied.isEmpty else { return "No applied changes yet" }
        let count = "\(applied.count) applied"
        guard let earliest = applied.compactMap(\.date).min() else { return count }
        return "\(count) since \(label(for: earliest, calendar: calendar))"
    }

    /// Groups chronological clips under short date labels; same-day neighbours share one label.
    static func dateGroups(for clips: [MapChangeClip], calendar: Calendar = .current) -> [(label: String, clips: [MapChangeClip])] {
        var groups: [(label: String, clips: [MapChangeClip])] = []
        var lastDay: Date?
        var lastWasUndated = false
        for clip in clips {
            if let date = clip.date {
                let day = calendar.startOfDay(for: date)
                if let last = lastDay, last == day, !lastWasUndated, !groups.isEmpty {
                    groups[groups.count - 1].clips.append(clip)
                } else {
                    groups.append((label(for: date, calendar: calendar), [clip]))
                }
                lastDay = day
                lastWasUndated = false
            } else {
                if lastWasUndated, !groups.isEmpty {
                    groups[groups.count - 1].clips.append(clip)
                } else {
                    groups.append(("Undated", [clip]))
                }
                lastWasUndated = true
            }
        }
        return groups
    }
}
