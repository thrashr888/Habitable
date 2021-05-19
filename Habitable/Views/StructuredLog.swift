//
//  StructuredLog.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct StructuredLogView: View {
    var logs: StructuredLog
    @State var showLogs = false
    @State var selection: Int?

    var body: some View {
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
            
//            List {
//                // TODO try using tabs here too!
//
//                if logs.diagnostics.count > 0 {
//                    ForEach(logs.diagnostics, id: \.id) { log in
//                        DiagnosticView(diagnostic: log.diagnostic)
//                    }
//                    Divider()
//                }
//                if logs.changeSummaries.count > 0 {
//                    ForEach(logs.changeSummaries, id: \.id) { log in
//                        ChangeSummaryView(changes: log.changes)
//                    }
//                }
//                if !logs.logs.isEmpty {
//                    Button("show logs") {
//                        showLogs = !showLogs
//                    }
//                }
//                if showLogs {
//                    Divider()
//                    ForEach(logs.logs, id: \.id) { log in
//                        if let message = log.message {
//                            LogView(message: message)
//                        } else {
//                            LogView(message: "no message")
//                        }
//                    }
//                }
//                if logs.versions.count > 0 {
//                    Divider()
//                    ForEach(logs.versions, id: \.id) { log in
//                        VersionView(version: log.version!)
//                    }
//                }
//                if logs.resources.count > 0 {
//                    Divider()
//                    Text("Resources")
//                        .fontWeight(.bold)
//                    ForEach(logs.resources, id: \.id) { log in
//                        ResourceView(resourceState: log)
//                    }
//                }
//                if logs.outputs.count > 0 {
//                    Divider()
//                    Text("Outputs")
//                        .fontWeight(.bold)
//                    ForEach(logs.outputs, id: \.id) { log in
//                        OutputView(outputs: log.outputs)
//                    }
//                }
//            }
        }
    }
}

struct StructuredLogView_Previews: PreviewProvider {
    static let log: StructuredLog = {
        let model = StructuredLog()
        log.resources = [
            ResourceState(PlannedChangeSummary(address: "test-addr", resource: Resource(addr: "test-addr"))),
        ]
        log.changeSummaries = [
            ChangeSummaryMessage(changes: ChangeSummaryChanges(add: 1, change: 2, remove: 3))
        ]
        log.logs = [
            LogMessage(message: "Testing"),
        ]
        return model
    }()
    
    static var previews: some View {
//        StructuredLogView(logs: StructuredLog())
        StructuredLogView(logs: log)
    }
}
