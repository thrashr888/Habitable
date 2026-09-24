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
                StructuredLogView(logs: plan)
            } else {
                Text("Planning...")
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
                ErrorView(message: errorMessage)
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
                }
                Spacer()
                Text(run.status.rawValue.localizedCapitalized)
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

            if run.apply != nil || run.errorMessage != nil {
                Picker("Run phase", selection: $selection) {
                    Text("Plan").tag(1)
                    if run.apply != nil { Text("Apply").tag(2) }
                    if run.errorMessage != nil { Text("Errors").tag(3) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Group {
                switch selection {
                case 2: applyView
                case 3: errorView
                default: planView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .navigationTitle("Runs")
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
        .accessibilityElement(children: .combine)
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
