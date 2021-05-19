//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct TerraformVariableSummaryView: View {
    @ObservedObject var variable: TerraformVariable
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("\(variable.key)")
                Spacer()
                if variable.sensitive {
                    Text("(sensitive)")
                        .foregroundColor(.secondary)
                }
                if variable.hcl {
                    Text("(HCL)")
                        .foregroundColor(.secondary)
                }
            }
            Text("\(variable.value)")
                .foregroundColor(.secondary)
        }
    }
}

struct VariableListPage: View {
    @EnvironmentObject var workspace: Workspace
    
    @State var terraformVariableModal: Bool = false
    @State var environmentVariableModal: Bool = false
    
    @State var newTV: TerraformVariable = TerraformVariable()
    @State var newEV: EnvironmentVariable = EnvironmentVariable()

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(workspace.terraformVariables, id: \.id) { variable in
                    TerraformVariableSummaryView(variable: variable)
                }
            }
        }
        .navigationTitle("Terraform Variables")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { workspace.checkVariables() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .help("Refresh variables")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // TODO move to footer
                Button(action: {
                    self.terraformVariableModal = true
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                        Text("Add")
                    }
                }
            }
        }
        .sheet(isPresented: $terraformVariableModal) {
            Form {
                Section(header: Text("Add a Terraform variable")
                            .font(.headline)) {
                    TextField("Key", text: $newTV.key)
                    TextField("Value", text: $newTV.value)
                    
                    HStack {
                        Button("Cancel") {
                            newTV = TerraformVariable()
                            terraformVariableModal = false
                        }
                        Spacer()
                        Button("Add variable") {
                            workspace.addTerraformVariable(newTV)
                            newTV = TerraformVariable()
                            terraformVariableModal = false
                        }
                    }
                }
            }.padding(/*@START_MENU_TOKEN@*/.all/*@END_MENU_TOKEN@*/)
        }
    }
}

struct VariableListPage_Previews: PreviewProvider {
    static var previews: some View {
        VariableListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
