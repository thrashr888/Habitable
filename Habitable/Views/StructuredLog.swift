//
//  StructuredLog.swift
//  Habitable
//

import SwiftUI

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
    @State private var resourceQuery = ""
    @State private var resourceOperation = "All"

    private var visibleResources: [ResourceState] {
        logs.resources.filter { resource in
            let matchesAddress = resourceQuery.isEmpty || resource.address.localizedCaseInsensitiveContains(resourceQuery)
            let operation = resource.action.rawValue.localizedCapitalized
            return matchesAddress && (resourceOperation == "All" || operation == resourceOperation)
        }
    }

    var body: some View {
        if !logs.diagnostics.isEmpty {
            Section("Diagnostics") {
                ForEach(logs.diagnostics, id: \.id) { log in
                    DiagnosticView(diagnostic: log.diagnostic)
                }
            }
        }
        if !logs.versions.isEmpty {
            Section {
                DisclosureGroup("Terraform version") {
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
                DisclosureGroup("Change summary") {
                ForEach(logs.changeSummaries, id: \.id) { summary in
                    ChangeSummaryView(changes: summary.changes)
                }
                }
            }
        }
        if !logs.outputs.isEmpty {
            Section {
                DisclosureGroup("Outputs") {
                ForEach(logs.outputs, id: \.id) { output in
                    OutputView(outputs: output.outputs)
                }
                }
            }
        }
        if !logs.logs.isEmpty {
            Section {
                DisclosureGroup("Activity · \(logs.logs.count) events") {
                ForEach(logs.logs, id: \.id) { log in
                    if let message = log.message { LogView(message: message) }
                }
                }
            }
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
