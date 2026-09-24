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
            Text(variable.sensitive ? "(sensitive value)" : variable.value)
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

    private var variableDuplicate: Bool {
        workspace.terraformVariables.contains { $0.isUserInput && $0.key == newTV.key }
    }

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
                Section(header: Text("Save a Terraform variable")
                            .font(.headline)) {
                    Text("Saved values apply to plans started in this app session.")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("Key", text: $newTV.key)
                    Text("Value")
                    if newTV.sensitive {
                        SecureField("Value", text: $newTV.value)
                    } else {
                        TextEditor(text: $newTV.value)
                            .frame(minHeight: 72)
                            .multilineTextAlignment(.leading)
                    }
                    Toggle("Value is JSON (list, map, number, boolean, or null)", isOn: $newTV.hcl)
                    Toggle("Sensitive", isOn: $newTV.sensitive)
                    Text("Hides this value in Habitable. Mark the Terraform variable sensitive in your configuration to hide it from Terraform plan output.")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("Description", text: $newTV.description)
                        .multilineTextAlignment(.leading)
                    if let validationError = newTV.validationError {
                        Text(validationError).foregroundColor(.red)
                    } else if variableDuplicate {
                        Text("A variable with this key already exists.").foregroundColor(.red)
                    }
                    HStack {
                        Button("Cancel") {
                            newTV = TerraformVariable()
                            terraformVariableModal = false
                        }
                        Spacer()
                        Button("Save variable") {
                            guard newTV.validationError == nil, !variableDuplicate else { return }
                            newTV.isUserInput = true
                            workspace.addTerraformVariable(newTV)
                            newTV = TerraformVariable()
                            terraformVariableModal = false
                        }
                        .disabled(newTV.validationError != nil || variableDuplicate)
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
