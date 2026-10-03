import SwiftUI

struct DescriptionDraftControls: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var draft = WorkspaceDescriptionDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(draft.unavailableReason == nil ? "Suggest description" : "Draft from configuration") {
                    draft.generate(for: workspace)
                }
                .disabled(workspace.workingDirectory == nil || draft.isGenerating)
                if draft.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: draft.cancel)
                }
            }
            if !draft.suggestion.isEmpty {
                Text("Suggested description").font(.subheadline.weight(.medium))
                TextEditor(text: $draft.suggestion)
                    .frame(minHeight: 60, maxHeight: 100)
                    .accessibilityLabel("Suggested workspace description")
                    .padding(4)
                    .background(.background)
                HStack {
                    Button("Use suggestion") { draft.use(in: workspace) }
                        .disabled(!draft.canUse(in: workspace) || workspace.locked)
                    SafeCopyButton(value: draft.suggestion, label: "Copy suggested description")
                    Button("Dismiss", action: draft.reset)
                }
                if !draft.canUse(in: workspace) && !draft.isGenerating {
                    Text("Your description changed. Copy the suggestion or generate a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = draft.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: workspace.workingDirectory) { _ in draft.reset() }
        .onDisappear { draft.cancel() }
    }
}
