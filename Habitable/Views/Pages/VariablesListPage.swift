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
            TerraformVariableEditor(
                variable: newTV,
                existingKeys: Set(workspace.terraformVariables.filter(\.isUserInput).map(\.key)),
                onCancel: {
                    newTV = TerraformVariable()
                    terraformVariableModal = false
                },
                onSave: {
                    let isDuplicate = workspace.terraformVariables.contains { $0.isUserInput && $0.key == newTV.key }
                    guard newTV.validationError == nil, !isDuplicate else { return }
                    newTV.isUserInput = true
                    workspace.addTerraformVariable(newTV)
                    newTV = TerraformVariable()
                    terraformVariableModal = false
                }
            )
        }
    }
}

private struct TerraformVariableEditor: View {
    @ObservedObject var variable: TerraformVariable
    let existingKeys: Set<String>
    let onCancel: () -> Void
    let onSave: () -> Void

    private var isDuplicate: Bool { existingKeys.contains(variable.key) }

    var body: some View {
        Form {
            Section(header: Text("Save a Terraform variable").font(.headline)) {
                Text("Saved values apply to plans started in this app session.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("Key", text: $variable.key)
                Text("Value")
                if variable.sensitive {
                    SecureField("Value", text: $variable.value)
                } else {
                    TextEditor(text: $variable.value)
                        .frame(minHeight: 72)
                        .multilineTextAlignment(.leading)
                }
                Toggle("Value is JSON (list, map, number, boolean, or null)", isOn: $variable.hcl)
                Toggle("Sensitive", isOn: $variable.sensitive)
                Text("Hides this value and redacts matching input values from Habitable run logs and reviews. Also mark it sensitive in your Terraform configuration for Terraform’s own output.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("Description", text: $variable.description)
                    .multilineTextAlignment(.leading)
                if let validationError = variable.validationError {
                    Text(validationError).foregroundColor(.red)
                } else if isDuplicate {
                    Text("A variable with this key already exists.").foregroundColor(.red)
                }
                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Save variable", action: onSave)
                        .disabled(variable.validationError != nil || isDuplicate)
                }
            }
        }
        .padding(.all)
    }
}

struct VariableListPage_Previews: PreviewProvider {
    static var previews: some View {
        VariableListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
