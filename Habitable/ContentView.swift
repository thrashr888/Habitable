//
//  ContentView.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import SwiftUI

struct TextView: View {
    @State var text: String?
    @State var ansi: Text?
    
    var body: some View {
        VStack(alignment: .leading) {
            if text != nil {
                Text(text!)
            }
            if ansi != nil {
//                ansi
            }
        }
    }
}

struct ChangeSummaryView: View {
    @State var changes: ChangeSummaryChanges
    var body: some View {
        HStack {
            Text("\(changes.add) created")
            Text("\(changes.change) changed")
            Text("\(changes.remove) destroyed")
        }
    }
}

struct DiagnosticView: View {
    @State var diagnostic: DiagnosticSummary
    var body: some View {
        VStack(alignment: .leading) {
            if (diagnostic.severity != nil){
                Text("\(diagnostic.severity!)")
            }
            if (diagnostic.summary != nil){
                Text("\(diagnostic.summary!)")
            }
            if (diagnostic.detail != nil){
                Text("\(diagnostic.detail!)")
            }
        }
    }
}

struct LogView: View {
    var message: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(message)")
        }
    }
}

struct VersionView: View {
    var version: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("Version: \(version)")
        }
    }
}

struct OutputView: View {
    var outputs: [Output]
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(outputs, id: \.id) { output in
                HStack {
                    Text("\(output.key): ")
                    if output.sensitive {
                        Text("(sensitive)")
                    } else {
                        Text("\(output.value ?? "n/a")")
                    }
                }
            }
        }
    }
}

struct ResourceView: View {
    var resourceState: ResourceState
    var resource: Resource {
        resourceState.resource
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(" \(resourceState.action.rawValue)")
                Text(" \(resource.implied_provider ?? "terraform")")
                Text(" \(resource.addr)")
            }
            ForEach(resourceState.stages, id: \.id) { stage in
                HStack {
                    Text("stage: \(stage.state.rawValue)")
                    if stage.identifier != nil {
                        Text("\(stage.identifier!)")
                    }
                    if stage.elapsed != nil {
                        Text("\(stage.elapsed!) seconds")
                    }
                    if stage.done {
                        Text("done")
                    }
                    if stage.errored {
                        Text("errored")
                    }
                }
            }
        }
    }
}

struct StructuredLogView: View {
    var logs: StructuredLog
    @State var showLogs = false
    
    var body: some View {
        VStack(alignment: .leading) {
            List(logs.diagnostics, id: \.id) { log in
                DiagnosticView(diagnostic: log.diagnostic)
            }
            List(logs.changeSummaries, id: \.id) { log in
                ChangeSummaryView(changes: log.changes)
            }
            if !logs.logs.isEmpty {
                Button("show logs") {
                    showLogs = !showLogs
                }
            }
            if showLogs {
                List(logs.logs, id: \.id) { log in
                    if let message = log.message {
                        LogView(message: message)
                    } else {
                        LogView(message: "no message")
                    }
                }
            }
            List(logs.versions, id: \.id) { log in
                VersionView(version: log.version!)
            }
            if logs.resources.count > 0 {
                Text("Resources")
                    .fontWeight(.bold)
                List(logs.resources, id: \.id) { log in
                    ResourceView(resourceState: log)
                }
            }
            if logs.outputs.count > 0 {
                Text("Outputs")
                    .fontWeight(.bold)
                List(logs.outputs, id: \.id) { log in
                    OutputView(outputs: log.outputs)
                }
            }
        }
    }
}

struct ErrorView: View {
    @State var message: String = ""
    var body: some View {
        VStack(alignment: .leading) {
            Text(message)
                .foregroundColor(.red)
        }
    }
}

struct ContentView: View {
    @ObservedObject var runner = TerraformRunner(workingDirectory: "/Users/thrashr888/workspace/Habitable")
    
    func addUrl() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            if response == NSApplication.ModalResponse.OK, let fileUrl = panel.url {
                runner.workingDirectory = fileUrl.path
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(runner.workingDirectory)")
            Button("Load folder", action: addUrl)
            
            if runner.locked {
                Text("(locked)")
            } else {
                Text("(unlocked)")
                HStack {
                    Button("init") {
                        runner.initialize()
                    }
                    Button("plan") {
                        runner.plan()
                    }
                    Button("apply") {
                        runner.apply()
                    }
                    Button("show") {
                        runner.show()
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading) {
                if runner.structuredLog != nil {
                    Text("Logs")
                        .font(.title)
                    StructuredLogView(logs: runner.structuredLog!)
                }
                if runner.ansiOutput != nil {
                    Text("Ansi")
                        .font(.title)
                    TextView(ansi: runner.ansiOutput)
                }
                if runner.textOutput != nil {
                    Text("Text")
                        .font(.title)
                    TextView(text: runner.textOutput)
                }
                if runner.errorMessage != nil {
                    Text("Error")
                        .font(.title)
                    ErrorView(message: runner.errorMessage!)
                }
            }
            
            Spacer()
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
