//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct VariableListPage: View {
    var workspace: Workspace
    @State var variables: Variables
    var body: some View {
        VStack(alignment: .leading) {
            Text("Terraform variables (\(variables.terraformVariables.count))")
                .font(.title)
            List(variables.terraformVariables, id: \.id) { variable in
                Text("\(variable.key)=\(variable.value)\(variable.sensitive ? " (sensitive)" : "")\(variable.hcl ? " (hcl)" : "")")
                Text("\(variable.description)")
            }

            Text("Environment variables (\(variables.environmentVariables.count))")
                .font(.title)
            List(variables.environmentVariables, id: \.id) { variable in
                Text("\(variable.key)=\(variable.value)\(variable.sensitive ? " (sensitive)" : "")")
                Text("\(variable.description)")
            }
        }
        .navigationTitle("Variables")
        .toolbar {
            ToolbarItem(placement: .status) {
                if workspace.locked {
                    Label("Locked", systemImage: "lock.fill")
                        .help("Locked")
                } else {
                    Label("Unlocked", systemImage: "lock.open.fill")
                        .help("Unlocked")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    workspace.queueRun()
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                        Text("Queue plan")
                    }
                }
            }
        }
    }
}

struct VariableListPage_Previews: PreviewProvider {
    static var previews: some View {
        VariableListPage(workspace: Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")), variables: Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")).variables)
    }
}
