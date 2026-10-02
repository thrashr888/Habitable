//
//  StructuredLog.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct StructuredLogView: View {
    @ObservedObject var logs: StructuredLog
    @State var showLogs = false
    @State private var selection = 2

    var body: some View {
        if !logs.isComplete {
            liveProgress
        } else {
        VStack(alignment: .leading) {
            TabView(selection: $selection,
                content:  {
                    if logs.diagnostics.count > 0 {
                        List(logs.diagnostics, id: \.id) { log in
                            DiagnosticView(diagnostic: log.diagnostic)
                        }.tabItem {
                            Label("Diagnostics", systemImage: "doc.text")
                        }.tag(1)
                    }
                    if logs.versions.count > 0 {
                        List(logs.versions, id: \.id) { log in
                            VersionView(version: log.version!)
                        }.tabItem {
                            Label("Version", systemImage: "doc.text")
                        }.tag(4)
                    }
                    if logs.logs.count > 0 {
                        List(logs.logs, id: \.id) { log in
                            if let message = log.message {
                                LogView(message: message)
                            }
                        }.tabItem {
                            Label("Logs", systemImage: "doc.text")
                        }.tag(3)
                    }
                    if logs.resources.count > 0 {
                        List(logs.resources, id: \.id) { log in
                            ResourceView(resourceState: log)
                        }.tabItem {
                            Label("Resources", systemImage: "doc.text")
                        }.tag(5)
                    }
                    if logs.changeSummaries.count > 0 {
                        List(logs.changeSummaries, id: \.id) { log in
                            ChangeSummaryView(changes: log.changes)
                        }.tabItem {
                            Label("Change Summary", systemImage: "doc.text")
                        }.tag(2)
                    }
                    if logs.outputs.count > 0 {
                        List(logs.outputs, id: \.id) { log in
                            OutputView(outputs: log.outputs)
                        }.tabItem {
                            Label("Outputs", systemImage: "doc.text")
                        }.tag(6)
                    }
                })
            

        }
        .onAppear {
            if !logs.diagnostics.isEmpty { selection = 1 }
            else if !logs.changeSummaries.isEmpty { selection = 2 }
            else if !logs.resources.isEmpty { selection = 5 }
            else if !logs.outputs.isEmpty { selection = 6 }
            else if !logs.logs.isEmpty { selection = 3 }
            else { selection = 4 }
        }
        }
    }

    private var liveProgress: some View {
        List {
            if logs.resources.isEmpty && logs.diagnostics.isEmpty && logs.logs.isEmpty {
                Text("Waiting for Terraform events…").foregroundStyle(.secondary)
            }
            if !logs.diagnostics.isEmpty {
                Section("Diagnostics") {
                    ForEach(logs.diagnostics, id: \.id) { log in
                        DiagnosticView(diagnostic: log.diagnostic)
                    }
                }
            }
            if !logs.resources.isEmpty {
                Section("Resources") {
                    ForEach(logs.resources, id: \.id) { resource in
                        ResourceView(resourceState: resource)
                    }
                }
            }
            if let summary = logs.changeSummaries.last {
                Section("Change summary") {
                    ChangeSummaryView(changes: summary.changes)
                }
            }
            if !logs.outputs.isEmpty {
                Section("Outputs") {
                    ForEach(logs.outputs, id: \.id) { output in
                        OutputView(outputs: output.outputs)
                    }
                }
            }
            if !logs.logs.isEmpty {
                Section("Activity") {
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
        model.resources = [
            ResourceState(PlannedChangeSummary(address: "test-addr", resource: Resource(addr: "test-addr"))),
        ]
        model.changeSummaries = [
            ChangeSummaryMessage(changes: ChangeSummaryChanges(add: 1, change: 2, remove: 3))
        ]
        model.logs = [
            LogMessage(message: "Testing"),
        ]
        return model
    }()
    
    static var previews: some View {
//        StructuredLogView(logs: StructuredLog())
        StructuredLogView(logs: log)
    }
}
