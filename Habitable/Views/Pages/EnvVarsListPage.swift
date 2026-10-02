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
        Text("\(variable.key) = \(variable.sensitive ? "(sensitive value)" : variable.value)")
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
            EnvironmentVariableEditor(
                variable: newEV,
                existingKeys: Set(workspace.environmentVariables.filter(\.isUserInput).map(\.key)),
                onCancel: {
                    newEV = EnvironmentVariable()
                    environmentVariableModal = false
                },
                onSave: {
                    let isDuplicate = workspace.environmentVariables.contains { $0.isUserInput && $0.key == newEV.key }
                    guard newEV.validationError == nil, !isDuplicate else { return }
                    newEV.isUserInput = true
                    workspace.addEnvironmentVariable(newEV)
                    newEV = EnvironmentVariable()
                    environmentVariableModal = false
                }
            )
        }
    }
}

private struct EnvironmentVariableEditor: View {
    @ObservedObject var variable: EnvironmentVariable
    let existingKeys: Set<String>
    let onCancel: () -> Void
    let onSave: () -> Void

    private var isDuplicate: Bool { existingKeys.contains(variable.key) }

    var body: some View {
        Form {
            Section(header: Text("Save an environment variable").font(.headline)) {
                Text("Saved values apply to plans started in this app session.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("Key", text: $variable.key)
                Toggle("Sensitive", isOn: $variable.sensitive)
                Text("Hides this value in Habitable. Terraform plan output follows the sensitivity declared in your Terraform configuration.")
                    .font(.caption).foregroundColor(.secondary)
                if variable.sensitive {
                    SecureField("Value", text: $variable.value)
                } else {
                    TextField("Value", text: $variable.value)
                        .multilineTextAlignment(.leading)
                }
                TextField("Description", text: $variable.description)
                    .multilineTextAlignment(.leading)
                if let validationError = variable.validationError {
                    Text(validationError).foregroundColor(.red)
                } else if isDuplicate {
                    Text("An environment variable with this key already exists.").foregroundColor(.red)
                }
                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Save", action: onSave)
                        .disabled(variable.validationError != nil || isDuplicate)
                }
            }
        }
        .padding(.all)
    }
}

struct EnvVarListPage_Previews: PreviewProvider {
    static var previews: some View {
        EnvVarListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
