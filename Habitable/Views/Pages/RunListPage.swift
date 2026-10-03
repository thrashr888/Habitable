//
//  Run.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RunListPage: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var selection: UUID?
    @State private var showDeleteConfirmation = false
    @State private var showRetentionConfirmation = false
    @State private var retentionDays = 90

    private var selectedSavedRun: TerraformRun? {
        guard let selection else { return nil }
        return workspace.runs.first { $0.id == selection && $0.isPersisted }
    }

    private var canDeleteSelectedRun: Bool {
        guard workspace.historyError == nil, let run = selectedSavedRun else { return false }
        return [.applied, .discarded, .errored, .canceled].contains(run.status)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.isValid, workspace.workingDirectory != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Planning needs a valid configuration", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("After fixing any input or configuration errors, validate and create a fresh plan.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = workspace.errorMessage {
                        Text(error).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Validate and plan") {
                            workspace.validateAndQueueRun { selection = $0 }
                        }
                        .disabled(workspace.locked || workspace.historyLoading || workspace.historyError != nil)
                        if !workspace.isInitialized {
                            Button("Initialize workspace", action: workspace.initialize)
                                .disabled(workspace.locked)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                Divider()
            }
            if let error = workspace.historyError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Button("Reload history", action: workspace.reloadRunHistory)
                        .disabled(workspace.locked)
                }
                .padding()
            }
            List(selection: $selection) {
                if workspace.historyLoading && workspace.runs.isEmpty {
                    ProgressView("Loading saved runs…")
                } else if workspace.runs.isEmpty {
                    Text(workspace.historyTotalCount == 0
                         ? "No runs yet. Queue a plan to view potential changes."
                         : "No saved runs on this page.")
                }
                ForEach(workspace.runs.sorted { $0.number > $1.number }) { run in
                    RunSummaryView(run: run)
                        .tag(run.id)
                }
            }
            HStack(spacing: 12) {
                Text(workspace.historyTotalCount == 0 ? "No saved runs" : "Saved runs \(workspace.historyPageOffset + 1)–\(min(workspace.historyPageOffset + workspace.historyPageSize, workspace.historyTotalCount)) of \(workspace.historyTotalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if workspace.historyLoading { ProgressView().controlSize(.small) }
                Button(action: {
                    selection = nil
                    workspace.loadPreviousRunHistoryPage()
                }) {
                    Label("Previous", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Previous run history page")
                .controlSize(.small)
                .help("Previous page")
                .disabled(workspace.locked || workspace.historyLoading || workspace.historyPageOffset == 0)
                Button(action: {
                    selection = nil
                    workspace.loadNextRunHistoryPage()
                }) {
                    Label("Next", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Next run history page")
                .controlSize(.small)
                .help("Next page")
                .disabled(workspace.locked || workspace.historyLoading || workspace.historyPageOffset + workspace.historyPageSize >= workspace.historyTotalCount)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("Runs")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: workspace.reloadRunHistory) {
                    Label("Reload history", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Reload saved run history")
                .help("Reload saved run history")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace.locked)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    workspace.queueRun { selection = $0 }
                }) {
                    Label("Queue plan", systemImage: "text.badge.plus")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Queue a Terraform plan")
                .help("Queue a Terraform plan")
                .disabled(workspace.locked || workspace.historyLoading || !workspace.isValid || workspace.historyError != nil)
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Export selected run…", systemImage: "square.and.arrow.up", action: exportSelectedRun)
                        .disabled(selectedSavedRun == nil || workspace.historyLoading || workspace.historyError != nil)
                    Button("Delete selected saved run…", systemImage: "trash") {
                        showDeleteConfirmation = true
                    }
                    .disabled(!canDeleteSelectedRun || workspace.historyLoading || workspace.locked)
                    Divider()
                    Menu("Delete completed saved runs older than…") {
                        retentionButton(days: 30, label: "30 days")
                        retentionButton(days: 90, label: "90 days")
                        retentionButton(days: 365, label: "1 year")
                    }
                    .disabled(workspace.historyLoading || workspace.locked || workspace.historyError != nil)
                } label: {
                    Label("Run history actions", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Run history actions")
                .help("Export or remove saved run history")
            }
        }
        .confirmationDialog("Delete this saved run?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete saved run", role: .destructive) {
                if let selectedSavedRun { workspace.deleteSavedRun(selectedSavedRun.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The persisted record will be removed from this Mac. Active runs and saved plans cannot be deleted here.")
        }
        .confirmationDialog("Apply run-history retention?", isPresented: $showRetentionConfirmation, titleVisibility: .visible) {
            Button("Delete eligible runs", role: .destructive) {
                workspace.applyRunHistoryRetention(days: retentionDays)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes completed saved records older than \(retentionDays) days. Active or uncertain runs are preserved. This action cannot be undone.")
        }
    }

    private func retentionButton(days: Int, label: String) -> some View {
        Button(label) {
            retentionDays = days
            showRetentionConfirmation = true
        }
    }

    private func exportSelectedRun() {
        guard let selectedSavedRun else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Habitable-Run-\(selectedSavedRun.number).json"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            workspace.exportSavedRun(selectedSavedRun.id, to: destination)
        }
    }
}

struct RunListPage_Previews: PreviewProvider {
    static let workspace: Workspace = {
        let model = Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable"))
        model.runs = [
            TerraformRun(workspace: model),
            TerraformRun(workspace: model),
        ]
        return model
    }()
    
    static var previews: some View {
        RunListPage(selection: .constant(nil))
            .environmentObject(workspace)
    }
}
