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
    
    @State var selection: Int = 1
    
    static let taskDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    var planView: some View {
        Group {
            if let plan = run.plan {
                PlanReviewView(plan: plan, diff: run.planDiff)
            } else {
                Text(run.isFinished ? "No plan output was captured for this run." : "Planning…")
            }
        }
    }
    
    var applyView: some View {
        Group {
            if let apply = run.apply {
                StructuredLogView(logs: apply)
            } else {
                Text("Applying...")
            }
        }
    }
    
    var errorView: some View {
        Group {
            if let errorMessage = run.errorMessage {
                let diagnostics = handleNDJsonSuccess(errorMessage).diagnostics
                if diagnostics.isEmpty {
                    ScrollView {
                        ErrorView(message: errorMessage)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    List(diagnostics, id: \.id) { diagnostic in
                        DiagnosticView(diagnostic: diagnostic.diagnostic,
                                       workingDirectory: workspace.workingDirectory)
                    }
                }
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run #\(run.number)").font(.title2.weight(.semibold))
                    if let message = run.message {
                        Text(message)
                    }
                    Text("\(run.createdAt, formatter: Self.taskDateFormat)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(run.executionContextDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(run.status.rawValue.localizedCapitalized)
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
                HStack {
                    Spacer()
                    if run.canDiscard {
                        Button("Discard plan", action: run.doDiscard)
                    }
                    if run.canConfirm {
                        Button("Confirm and apply") {
                            run.doApply { _, error in
                                selection = error == nil ? 2 : 3
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

            if !run.canCancel && (run.apply != nil || run.errorMessage != nil) {
                Picker("Run phase", selection: $selection) {
                    Text("Plan").tag(1)
                    if run.apply != nil { Text("Apply").tag(2) }
                    if run.errorMessage != nil { Text("Errors").tag(3) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Group {
                if run.canCancel {
                    if run.status == .applying, let apply = run.apply {
                        StructuredLogView(logs: apply)
                    } else if let plan = run.plan {
                        StructuredLogView(logs: plan)
                    } else {
                        TextLogView(text: run.textOutput ?? "Waiting for Terraform output…")
                    }
                } else {
                    switch selection {
                    case 2: applyView
                    case 3: errorView
                    default: planView
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .navigationTitle("Runs")
        .onAppear { selection = run.errorMessage != nil ? 3 : (run.apply != nil ? 2 : 1) }
    }
}

private struct ScopedPlanAttribute: Identifiable {
    let owner: String
    let attribute: PlanAttributeChange

    // List flattens nested ForEach content; paths alone collide across sections.
    var id: String { "\(owner)\u{0}\(attribute.path)" }
}

private struct PlanReviewView: View {
    let plan: StructuredLog
    let diff: TerraformPlan?
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            if let diff {
                List {
                    if diff.resourceChanges.allSatisfy({ $0.action == "no-op" }) &&
                        diff.outputChanges.allSatisfy({ $0.action == "no-op" }) {
                        Text("No changes in this plan.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(diff.resourceChanges.filter { $0.action != "no-op" }) { change in
                        Section {
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
                        } header: {
                            HStack {
                                Text(change.address)
                                Spacer()
                                Text(change.action.capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(diff.outputChanges.filter { $0.action != "no-op" }) { output in
                        Section {
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
                        } header: {
                            HStack {
                                Text("Output: \(output.name)")
                                Spacer()
                                Text(output.action.capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .tabItem { Label("Review", systemImage: "arrow.left.arrow.right") }
                .tag(0)
            }

            StructuredLogView(logs: plan)
                .tabItem { Label("Events", systemImage: "list.bullet") }
                .tag(1)
        }
        .onAppear { selection = diff == nil ? 1 : 0 }
        .onChange(of: diff != nil) { available in
            if available { selection = 0 }
        }
    }
}

struct RunSummaryView: View {
    @ObservedObject var run: TerraformRun
    
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
                    Label("#\(run.number) \(run.message ?? "run")", systemImage: run.isFinished ? "circle.fill" : "circle")
                        .font(.headline)
                        .lineLimit(1)
                }
                Text("\(run.createdAt, formatter: Self.taskDateFormat)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(alignment: .center) {
                    if let add = run.added {
                        Text("+\(add)")
                            .foregroundColor(.green)
                    }
                    if let change = run.changed {
                        Text("~\(change)")
                            .foregroundColor(.blue)
                    }
                    if let destroy = run.destroyed {
                        Text("-\(destroy)")
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
        .frame(height: 64, alignment: .topLeading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct RunPageView_Previews: PreviewProvider {
    static let workspace: Workspace = {
        let model = Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable"))
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
