//
//  Run.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct RunPageView: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var run: TerraformRun
    
    @State private var phaseSelection = RunPhaseSelection()
    private var selection: Int { phaseSelection.phase.rawValue }
    
    static let taskDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var statusSymbol: String {
        switch run.status {
        case .pending, .planning: return "hourglass"
        case .planned: return "doc.text.magnifyingglass"
        case .confirmed, .applying: return "arrow.triangle.2.circlepath"
        case .applied: return "checkmark.circle.fill"
        case .discarded, .canceled, .expired: return "xmark.circle"
        case .errored, .interrupted: return "exclamationmark.triangle.fill"
        }
    }
    
    var planView: some View {
        Group {
            if let plan = run.plan {
                PlanReviewSections(plan: plan, diff: run.planDiff)
            } else {
                Text(run.isFinished ? "No plan output was captured for this run." : "Planning…")
            }
        }
    }
    
    var applyView: some View {
        Group {
            if let apply = run.apply {
                StructuredLogSections(logs: apply)
            } else {
                Text(run.isFinished ? "No apply output was captured for this run." : "Applying…")
            }
        }
    }
    
    var errorView: some View {
        Group {
            if let errorMessage = run.errorMessage {
                let diagnostics = handleNDJsonSuccess(errorMessage).diagnostics
                if diagnostics.isEmpty {
                    ErrorView(message: errorMessage)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(diagnostics, id: \.id) { diagnostic in
                        DiagnosticView(diagnostic: diagnostic.diagnostic,
                                       workingDirectory: workspace.workingDirectory)
                    }
                }
            }
        }
    }
    
    var body: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Run #\(run.number)").font(.title2.weight(.semibold))
                        if let message = run.message {
                            Text(message).lineLimit(2)
                        }
                        Text("\(run.createdAt, formatter: Self.taskDateFormat)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let duration = run.planDuration {
                            Text("Plan duration: \(duration.formatted(.number.precision(.fractionLength(1)))) seconds")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let duration = run.applyDuration {
                            Text("Apply duration: \(duration.formatted(.number.precision(.fractionLength(1)))) seconds")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let commit = run.gitCommit {
                            Text("\(run.gitBranch ?? "Detached HEAD") · \(commit.prefix(8))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .help(commit)
                        }
                        Text(run.executionContextDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(run.status.rawValue.localizedCapitalized, systemImage: statusSymbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let notice = run.historyNotice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if run.canCancel {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(run.isCanceling ? "Stopping Terraform…" : "Terraform is running…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(run.usesHCPBackend ? "Stop streaming" : "Cancel", action: run.cancel)
                            .disabled(run.isCanceling)
                    }
                    if run.usesHCPBackend {
                        Text("Stopping the local command may leave the run active in HCP Terraform.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if run.status == .canceled && run.usesHCPBackend {
                    Text("The local command stopped. The remote run may still be active in HCP Terraform.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if run.canDiscard || run.canConfirm {
                    if run.canConfirm {
                        if let plan = run.planDiff {
                            let consequences = plan.consequences
                            VStack(alignment: .leading, spacing: 6) {
                                Text(consequences.summary).font(.callout.weight(.medium))
                                if consequences.replace > 0 || consequences.destroy > 0 {
                                    Label(consequences.replace > 0
                                          ? "Replacements destroy and recreate resources. Review these changes before applying."
                                          : "This plan destroys resources.", systemImage: "exclamationmark.triangle")
                                        .font(.callout).foregroundStyle(.orange)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Apply the changes in this run’s plan.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        if run.canDiscard {
                            Button("Discard plan", action: run.doDiscard)
                        }
                        if run.canConfirm {
                            Button("Confirm and apply") {
                                run.doApply { _, error in
                                    phaseSelection.receive(error == nil ? .apply : .errors)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .controlSize(.regular)
                }
                if run.status == .planned && run.isUnchangedHCPPlan {
                    Text("This workspace is up to date. No apply is needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if run.apply != nil || run.errorMessage != nil || run.status == .confirmed || run.status == .applying {
                    Picker("Run phase", selection: Binding(get: { selection }, set: { phaseSelection.inspect(RunDisplayPhase(rawValue: $0) ?? .plan) })) {
                        Text("Plan").tag(1)
                        if run.apply != nil || run.status == .confirmed || run.status == .applying { Text("Apply").tag(2) }
                        if run.errorMessage != nil { Text("Errors").tag(3) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if run.canCancel && !phaseSelection.followsLive {
                        Button("Follow active phase") {
                            phaseSelection.resume(currentPhase)
                        }
                    }
                }

            }
            Group {
                if run.canCancel && selection == 1 && run.status != .confirmed && run.status != .applying {
                    if let plan = run.plan {
                        StructuredLogSections(logs: plan)
                    } else {
                        TextLogView(text: run.textOutput ?? "Waiting for Terraform output…")
                            .frame(minHeight: 240)
                    }
                } else {
                    switch selection {
                    case 2: applyView
                    case 3: errorView
                    default: planView
                    }
                }
            }
        }
        .listStyle(.inset)

        .onAppear { followCurrentPhase() }
        .onChange(of: run.id) { _ in followCurrentPhase() }
        .onChange(of: run.status) { _ in followCurrentPhase() }
        .onChange(of: run.apply != nil) { _ in followCurrentPhase() }
        .onChange(of: run.errorMessage) { _ in followCurrentPhase() }
    }

    private var currentPhase: RunDisplayPhase {
        RunDisplayPhase.current(status: run.status, hasApply: run.apply != nil, hasError: run.errorMessage != nil)
    }

    private func followCurrentPhase() {
        phaseSelection.receive(currentPhase)
    }
}

private struct ScopedPlanAttribute: Identifiable {
    let owner: String
    let attribute: PlanAttributeChange

    // List flattens nested ForEach content; paths alone collide across sections.
    var id: String { "\(owner)\u{0}\(attribute.path)" }
}

private struct PlanReviewSections: View {
    let plan: StructuredLog
    let diff: TerraformPlan?
    @State private var addressFilter = ""
    @State private var operationFilter = "All"

    private var visibleChanges: [PlanResourceChange] {
        let changes = (diff?.resourceChanges ?? []).filter {
            $0.action != "no-op" || $0.originalAddress != nil || $0.importingID != nil
        }
        return changes.filter { change in
            let operation = change.isReplacement ? "replace" :
                (change.importingID != nil ? "import" : (change.originalAddress != nil ? "move" : change.action))
            return (addressFilter.isEmpty || change.address.localizedCaseInsensitiveContains(addressFilter)) &&
                (operationFilter == "All" || operation.localizedCaseInsensitiveContains(operationFilter))
        }
    }

    private var counts: (add: Int, change: Int, destroy: Int, replace: Int, read: Int) {
        let changes = diff?.resourceChanges ?? []
        return changes.reduce(into: (0, 0, 0, 0, 0)) { result, item in
            if item.isReplacement { result.3 += 1 }
            else if item.action == "create" { result.0 += 1 }
            else if item.action == "delete" { result.2 += 1 }
            else if item.action == "update" { result.1 += 1 }
            else if item.action == "read" { result.4 += 1 }
        }
    }

    var body: some View {
        Group {
            if diff != nil {
                Section {
                    let totals = counts
                    HStack(spacing: 18) {
                        planCount("Create", value: totals.add, color: .green)
                        planCount("Update", value: totals.change, color: .blue)
                        planCount("Replace", value: totals.replace, color: .orange)
                        planCount("Destroy", value: totals.destroy, color: .red)
                        if totals.read > 0 { planCount("Read", value: totals.read, color: .secondary) }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                } header: { Text("Planned actions") }
            }
            if let diff {
                if visibleChanges.isEmpty && diff.outputChanges.allSatisfy({ $0.action == "no-op" }) {
                    Text(addressFilter.isEmpty && operationFilter == "All"
                         ? "No changes in this plan." : "No resources match this filter.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack(spacing: 8) {
                        TextField("Filter by resource address", text: $addressFilter)
                            .textFieldStyle(.roundedBorder)
                        Picker("Operation", selection: $operationFilter) {
                            ForEach(["All", "create", "update", "replace", "delete", "read", "import", "move"], id: \.self) { operation in
                                Text(operationLabel(operation)).tag(operation)
                            }
                        }
                        .frame(width: 130)
                    }
                } header: { Text("Resource changes · \(visibleChanges.count) of \(diff.resourceChanges.filter { $0.action != "no-op" || $0.originalAddress != nil || $0.importingID != nil }.count)") }
                ForEach(visibleChanges) { change in
                    Section {
                        DisclosureGroup {
                            if let originalAddress = change.originalAddress {
                                LabeledContent("Moved from") {
                                    Text(originalAddress).textSelection(.enabled)
                                }
                            }
                            if let importingID = change.importingID {
                                LabeledContent("Import ID") {
                                    Text(importingID).textSelection(.enabled)
                                }
                            }
                            if change.actionOrder == ["create", "delete"] {
                                Text("Creates the replacement before destroying the existing resource.")
                                    .foregroundStyle(.secondary)
                            } else if change.actionOrder == ["delete", "create"] {
                                Text("Destroys the existing resource before creating the replacement.")
                                    .foregroundStyle(.secondary)
                            }
                            if change.attributes.isEmpty {
                                Text("Terraform reported no attribute changes.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(change.attributes.map {
                                ScopedPlanAttribute(owner: "resource:\(change.address)", attribute: $0)
                            }) { row in
                                let attribute = row.attribute
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(attribute.path == "$" || attribute.path.isEmpty ? "Value" : attribute.path)
                                        .font(.headline)
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Before").foregroundStyle(.secondary)
                                        Text(attribute.before.displayValue)
                                            .textSelection(.enabled)
                                    }
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("After").foregroundStyle(.secondary)
                                        Text(attribute.after.displayValue)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            if !change.replacementPaths.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Replacement required by")
                                        .font(.headline)
                                    Text(change.replacementPaths.joined(separator: ", "))
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 3)
                            }
                        } label: {
                            HStack {
                                Text(change.address)
                                Spacer()
                                Text(change.action == "no-op"
                                     ? (change.importingID != nil ? "Import" : "Move")
                                     : change.action.capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(diff.outputChanges.filter { $0.action != "no-op" }) { output in
                    Section {
                        DisclosureGroup {
                            ForEach(output.attributes.map {
                                ScopedPlanAttribute(owner: "output:\(output.name)", attribute: $0)
                            }) { row in
                                let attribute = row.attribute
                                VStack(alignment: .leading, spacing: 5) {
                                    if !attribute.path.isEmpty && attribute.path != "$" {
                                        Text(attribute.path).font(.headline)
                                    }
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Before").foregroundStyle(.secondary)
                                        Text(attribute.before.displayValue).textSelection(.enabled)
                                    }
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("After").foregroundStyle(.secondary)
                                        Text(attribute.after.displayValue).textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        } label: {
                            HStack {
                                Text("Output: \(output.name)")
                                Spacer()
                                Text(output.action.capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            StructuredLogSections(logs: plan)
            if diff == nil && plan.diagnostics.isEmpty && plan.versions.isEmpty && plan.resources.isEmpty &&
                plan.changeSummaries.isEmpty && plan.outputs.isEmpty && plan.logs.isEmpty {
                Text(plan.isComplete
                     ? "Terraform did not return structured events for this plan."
                     : "Waiting for Terraform events…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func planCount(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func operationLabel(_ operation: String) -> String {
        switch operation {
        case "delete": return "Destroy"
        case "All": return "All"
        default: return operation.capitalized
        }
    }
}

struct RunSummaryView: View {
    @ObservedObject var run: TerraformRun

    private var statusSymbol: String {
        switch run.status {
        case .pending, .planning: return "hourglass"
        case .planned: return "doc.text.magnifyingglass"
        case .confirmed, .applying: return "arrow.triangle.2.circlepath"
        case .applied: return "checkmark.circle.fill"
        case .discarded, .canceled, .expired: return "xmark.circle"
        case .errored, .interrupted: return "exclamationmark.triangle.fill"
        }
    }
    
    static let taskDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                HStack {
                    Label("#\(run.number) \(run.message ?? "run")", systemImage: statusSymbol)
                        .font(.headline)
                        .lineLimit(2)
                }
                Text("\(run.createdAt, formatter: Self.taskDateFormat)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(alignment: .center) {
                    if let add = run.added {
                        Text("+\(add)")
                            .accessibilityLabel("\(add) resources to add")
                            .foregroundColor(.green)
                    }
                    if let change = run.changed {
                        Text("~\(change)")
                            .accessibilityLabel("\(change) resources to change")
                            .foregroundColor(.blue)
                    }
                    if let destroy = run.destroyed {
                        Text("-\(destroy)")
                            .accessibilityLabel("\(destroy) resources to destroy")
                            .foregroundColor(.red)
                    }
                    Spacer()
                    Text("\(run.status.rawValue.localizedCapitalized)")
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 64, alignment: .topLeading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .id("\(run.id.uuidString)-\(run.status.rawValue)")
    }
}

struct RunPageView_Previews: PreviewProvider {
    static let workspace: Workspace = {
        let model = Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable"))
        return model
    }()
    static let run: TerraformRun = {
        let model = TerraformRun(workspace: workspace)
        let log = StructuredLog()
        log.resources = [
            ResourceState(PlannedChangeSummary(address: "test-addr", resource: Resource(addr: "test-addr"))),
        ]
        model.plan = log
        model.apply = log
        return model
    }()
    
    static var previews: some View {
        RunPageView(run: run)
            .environmentObject(workspace)
        RunSummaryView(run: run)
            .environmentObject(workspace)
    }
}
