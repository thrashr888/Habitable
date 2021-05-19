//
//  Settings.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct SettingsListPage: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section {
                    Text("Working directory")
                        .font(.headline)
                        .padding(.bottom, 1)
                    VStack(alignment: .leading) {
                        if let workingDirectory = workspace.workingDirectory {
                            Text("\(workingDirectory.path)")
                        }
                        Button("Choose folder", action: workspace.addUrl)
                    }
                    
                    Text("Terraform Version")
                        .font(.headline)
                        .padding(.top)
                    Picker("Terraform version", selection: $workspace.terraformVersion) {

                        Text("0.15.3 (latest)")
                            .accessibility(label: Text("0.15.3"))
                            .tag("0.15.3")

                    }.pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                    
                    Toggle("Auto apply", isOn: $workspace.autoApply)
                        .padding(.top)
                    
                    Text("Description")
                        .font(.headline)
                        .padding(.top)
                    ZStack {
                        TextEditor(text: $workspace.description)
                        Text(workspace.description)
                            .opacity(0)
                            .padding(.all, 8) // <- This will solve the issue if it is in the same ZStack
                    }
                }
            }
            .padding(.all)

            Spacer()
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("")
            }
        }
    }
}

struct SettingsListPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
