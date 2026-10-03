//
//  StructuredLog.swift
//  Habitable
//

import SwiftUI

/// A single native button makes the arrow, title and remaining header one target.
struct FullHeaderDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Collapse section" : "Expand section")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Presents Terraform's structured event stream as one readable, scrollable timeline.
struct StructuredLogView: View {
    @ObservedObject var logs: StructuredLog

    var body: some View {
        List {
            StructuredLogSections(logs: logs)
        }
        .overlay {
            if !logs.isComplete && logs.resources.isEmpty && logs.diagnostics.isEmpty &&
                logs.logs.isEmpty && logs.changeSummaries.isEmpty && logs.outputs.isEmpty && logs.versions.isEmpty {
                Text("Waiting for Terraform events…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else if logs.isComplete && logs.resources.isEmpty && logs.diagnostics.isEmpty &&
                logs.logs.isEmpty && logs.changeSummaries.isEmpty && logs.outputs.isEmpty && logs.versions.isEmpty {
                Text("Terraform did not return structured events for this phase.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Sections can be embedded beside plan changes so review and events share one scroll area.
struct StructuredLogSections: View {
    @ObservedObject var logs: StructuredLog
    var workspaceDirectory: URL? = nil
    var onOpenDeclaration: ((String, Int) -> Void)? = nil
    @State private var resourceQuery = ""
    @State private var resourceOperation = "All"
    @State private var disclosureState = LiveRunDisclosureState()
    @State private var wasLive = false

    private var availableSections: Set<RunLogSection> {
        var sections: Set<RunLogSection> = []
        if !logs.versions.isEmpty { sections.insert(.version) }
        if !logs.changeSummaries.isEmpty { sections.insert(.summary) }
        if !logs.outputs.isEmpty { sections.insert(.outputs) }
        if !logs.logs.isEmpty { sections.insert(.activity) }
        return sections
    }

    private func expansion(_ section: RunLogSection) -> Binding<Bool> {
        Binding(get: { disclosureState.expanded.contains(section) },
                set: { disclosureState.setExpanded(section, $0) })
    }

    private func followIncomingSections() {
        // A final output and phase completion can arrive in the same UI update.
        disclosureState.receive(availableSections, isLive: !logs.isComplete || wasLive)
        wasLive = !logs.isComplete
    }

    private var visibleResources: [ResourceState] {
        logs.resources.filter { resource in
            let matchesAddress = resourceQuery.isEmpty || resource.address.localizedCaseInsensitiveContains(resourceQuery)
            let operation = resource.action.rawValue.localizedCapitalized
            return matchesAddress && (resourceOperation == "All" || operation == resourceOperation)
        }
    }

    var body: some View {
        Group {
            if !logs.diagnostics.isEmpty {
                Section("Diagnostics") {
                    ForEach(logs.diagnostics, id: \.id) { log in
                        VStack(alignment: .leading, spacing: 8) {
                            DiagnosticView(diagnostic: log.diagnostic)
                            if let sourceFile = TerraformDiagnosticSource.currentWorkspaceFile(
                                filename: log.diagnostic.range?.filename,
                                workspaceDirectory: workspaceDirectory) {
                                let line = log.diagnostic.range?.start?.line ?? 0
                                HStack {
                                    SafeCopyButton(value: line > 0 ? "\(sourceFile):\(line)" : sourceFile,
                                                   label: "Copy diagnostic source location", showsTitle: true)
                                    if let onOpenDeclaration, line > 0 {
                                        OpenCurrentTerraformSourceButton(filename: sourceFile, line: line,
                                                                         workspaceDirectory: workspaceDirectory,
                                                                         onOpen: onOpenDeclaration)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !logs.versions.isEmpty {
                Section {
                    DisclosureGroup("Terraform version", isExpanded: expansion(.version)) {
                    ForEach(logs.versions, id: \.id) { log in
                        if let version = log.version { VersionView(version: version) }
                    }
                    }
                }
            }
            if !logs.resources.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        TextField("Filter resource address", text: $resourceQuery)
                            .textFieldStyle(.roundedBorder)
                        Picker("Operation", selection: $resourceOperation) {
                            ForEach(["All"] + Array(Set(logs.resources.map { $0.action.rawValue.localizedCapitalized })).sorted(), id: \.self) { operation in
                                Text(operation == "Delete" ? "Destroy" : operation).tag(operation)
                            }
                        }
                        .frame(width: 130)
                    }
                    if visibleResources.isEmpty {
                        Text("No resources match this filter.").foregroundStyle(.secondary)
                    }
                    ForEach(visibleResources, id: \.id) { resource in
                        ResourceView(resourceState: resource)
                    }
                } header: { Text("Resources · \(visibleResources.count) of \(logs.resources.count)") }
            }
            if !logs.changeSummaries.isEmpty {
                Section {
                    DisclosureGroup("Change summary", isExpanded: expansion(.summary)) {
                    ForEach(logs.changeSummaries, id: \.id) { summary in
                        ChangeSummaryView(changes: summary.changes)
                    }
                    }
                }
            }
            if !logs.outputs.isEmpty {
                Section {
                    DisclosureGroup("Outputs", isExpanded: expansion(.outputs)) {
                    ForEach(logs.outputs, id: \.id) { output in
                        OutputView(outputs: output.outputs)
                    }
                    }
                }
            }
            if !logs.logs.isEmpty {
                Section {
                    DisclosureGroup("Activity · \(logs.logs.count) events", isExpanded: expansion(.activity)) {
                    ForEach(logs.logs, id: \.id) { log in
                        if let message = log.message { LogView(message: message) }
                    }
                    }
                }
            }
        }
        .onAppear { followIncomingSections() }
        .onChange(of: availableSections) { _ in followIncomingSections() }
        .onChange(of: logs.isComplete) { _ in followIncomingSections() }
        .onChange(of: logs.id) { _ in
            disclosureState = LiveRunDisclosureState()
            wasLive = false
            followIncomingSections()
        }
    }
}

struct StructuredLogView_Previews: PreviewProvider {
    static let log: StructuredLog = {
        let model = StructuredLog()
        model.resources = [ResourceState(PlannedChangeSummary(address: "test-addr", resource: Resource(addr: "test-addr")))]
        model.changeSummaries = [ChangeSummaryMessage(changes: ChangeSummaryChanges(add: 1, change: 2, remove: 3))]
        model.logs = [LogMessage(message: "Testing")]
        return model
    }()

    static var previews: some View { StructuredLogView(logs: log) }
}
