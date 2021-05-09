//
//  ContentView.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Foundation
import SwiftTerm
import SwiftUI

struct ContentView: View {
    @State var workingDir = URL(fileURLWithPath: "~/workspace/Habitable")
    @ObservedObject var runner = TerraformRunner(dir: URL(fileURLWithPath: "~/workspace/Habitable"))
    @ObservedObject var workspace = Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable"))
//    @StateObject private var workspace = Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable"))

//    func addUrl() {
//        let panel = NSOpenPanel()
//        panel.allowsMultipleSelection = false
//        panel.canChooseFiles = false
//        panel.canChooseDirectories = true
//        panel.begin { response in
//            if response == NSApplication.ModalResponse.OK, let fileUrl = panel.url {
//                runner.updateWorkingDirectory(dir: fileUrl)
//                workspace.updateWorkingDirectory(dir: fileUrl)
//            }
//        }
//    }

    var body: some View {
        AppSidebarNavigation(model: runner, workspace: workspace)

//        VStack(alignment: .leading) {
//            HStack {
//                Button("Load folder", action: addUrl)
//                Text("\(runner.workingDirectory)")
//            }
//            .padding([.top, .leading, .trailing])
//
//            Divider()
//
//            HStack {
//                Button("Runs") {}
//                Button("State") {}
//                Button("Variables") {}
//                Button("Settings") {}
//                Spacer()
//                Button("Queue Run") {}
//            }
//            .padding(.horizontal)
//
//            Divider()
//
//            HStack {
//                Button("init") {
//                    runner.initialize(workingDirectory: runner.workingDirectory)
//                }.disabled(runner.locked)
//                Button("plan") {
//                    runner.plan(workingDirectory: runner.workingDirectory)
//                }.disabled(runner.locked)
//                Button("apply") {
//                    runner.apply(workingDirectory: runner.workingDirectory)
//                }.disabled(runner.locked)
//                Button("show") {
//                    runner.show(workingDirectory: runner.workingDirectory)
//                }.disabled(runner.locked)
//
//                if runner.locked {
//                    Text("(locked)")
//                } else {
//                    Text("(unlocked)")
//                }
//
//                if runner.isInitialized {
//                    Text("(initialized)")
//                } else {
//                    Text("(uninitialized)")
//                }
//
//                if runner.hasState {
//                    Text("(has state)")
//                } else {
//                    Text("(no state)")
//                }
//            }
//            .padding(.horizontal)
//
//            Divider()
//
//            VStack(alignment: .leading) {
//                if runner.locked {
//                    Text("Running...")
//                        .padding(.all)
//                }
//                if runner.structuredLog != nil {
//                    Text("Logs")
//                        .font(.title)
//                    StructuredLogView(logs: runner.structuredLog!)
//                }
//                if runner.showOutput != nil {
//                    ShowView(show: runner.showOutput!)
//                }
//                if runner.textOutput != nil {
//                    TextView(text: runner.textOutput!)
//                        .padding(.horizontal)
//                }
//                if runner.errorMessage != nil {
//                    Text("Error")
//                        .font(.title)
//                    ErrorView(message: runner.errorMessage!)
//                }
//                Spacer()
//            }
//
//            Spacer()
//        }
//        .frame(minWidth: 800, minHeight: 500)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
