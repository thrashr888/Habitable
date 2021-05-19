//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct EnvironmentVariableSummaryView: View {
    @ObservedObject var variable: EnvironmentVariable
    var body: some View {
        Text("\(variable.key) = \(variable.value)\(variable.sensitive ? " (sensitive)" : "")")
        Text("\(variable.description)")
    }
}

struct EnvVarListPage: View {
    @EnvironmentObject var workspace: Workspace
    
    @State var environmentVariableModal: Bool = false
    @State var newEV: EnvironmentVariable = EnvironmentVariable()

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(workspace.environmentVariables, id: \.id) { variable in
                    EnvironmentVariableSummaryView(variable: variable)
                }
            }
        }
        .navigationTitle("Environment Variables")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { workspace.checkVariables() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .help("Refresh variables")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    self.environmentVariableModal = true
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                        Text("Add")
                    }
                }
            }
        }
        .sheet(isPresented: $environmentVariableModal) {
            Form {
                Section(header: Text("Add an environment variable")
                            .font(.headline)) {
                    TextField("Key", text: $newEV.key)
                    TextField("Value", text: $newEV.value)
                    
                    HStack {
                        Button("Cancel") {
                            newEV = EnvironmentVariable()
                            environmentVariableModal = false
                        }
                        Spacer()
                        Button("Add") {
                            workspace.addEnvironmentVariable(newEV)
                            newEV = EnvironmentVariable()
                            environmentVariableModal = false
                        }
                    }
                }
            }.padding(.all)
        }
    }
}

struct EnvVarListPage_Previews: PreviewProvider {
    static var previews: some View {
        EnvVarListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
