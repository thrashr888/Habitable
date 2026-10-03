import AppKit
import SwiftUI

struct SafeCopyButton: View {
    let value: String
    let label: String
    var showsTitle = false
    var title = "Copy"
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            if showsTitle {
                Label(copied ? "Copied" : title,
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(.borderless)
        .help(copyActionLabel)
        .accessibilityLabel(copied ? "Copied \(copySubject)" : copyActionLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private var copyActionLabel: String {
        label.hasPrefix("Copy ") ? label : "Copy \(label)"
    }

    private var copySubject: String {
        label.hasPrefix("Copy ") ? String(label.dropFirst("Copy ".count)) : label
    }
}
