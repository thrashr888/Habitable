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
    
    @State var selection: Int?
    
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
        VStack(alignment: .leading) {
            HStack {
                Text("RUN #\(run.number)")
                if run.message != nil {
                    Text("\(run.message!)")
                }
                Spacer()
                Text("\(run.createdAt, formatter: Self.taskDateFormat)")
                    .foregroundColor(.secondary)
            }
            
            TabView(selection: $selection,
                content:  {
                    planView.tabItem {
                        Label("Plan", systemImage: "questionmark.folder")
                    }.tag(1)
                    if run.apply != nil {
                        applyView.tabItem {
                            Label("Apply", systemImage: "doc.text")
                        }.tag(2)
                    }
                    if run.errorMessage != nil {
                        errorView.tabItem {
                            Label("Errors", systemImage: "xmark.octagon")
                        }.tag(3)
                    }
                })
        }
        .padding(.all)
        .navigationTitle("Run #\(run.id)")
        .navigationSubtitle(run.status.rawValue.localizedCapitalized)
        .toolbar {
            ToolbarItem(placement: .status) {
                Text("\(run.status.rawValue.localizedCapitalized)")
            }
            ToolbarItem(placement: .cancellationAction) {
                if run.canDiscard {
                    Button("Discard plan") {
                        run.doDiscard()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if run.canConfirm {
                    Button("Confirm and apply") {
                        run.doApply({ apply, error in
                            self.selection = error == nil ? 3 : 2
                        })
                    }
                    .foregroundColor(.accentColor)
                }
            }
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
                    Spacer()
                    Text("\(run.createdAt, formatter: Self.taskDateFormat)")
                        .foregroundColor(.secondary)
                }
                
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
