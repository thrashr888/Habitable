//
//  Settings.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct SettingsListPage: View {
    @State var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section {
                    Text("Working directory")
                        .font(.headline)
                        .padding(.top)
                    HStack {
                        Button("Choose folder", action: workspace.addUrl)
                        if workspace.workingDirectory != nil {
                            Text("\(workspace.workingDirectory!)")
                        }
                    }
                    Text("Description")
                        .font(.headline)
                        .padding(.top)
                    ZStack {
                        TextEditor(text: $workspace.description)
                        Text(workspace.description).opacity(0).padding(.all, 8) // <- This will solve the issue if it is in the same ZStack
                    }
                    Text("Terraform Version")
                        .font(.headline)
                        .padding(.top)
                    Picker("Terraform version", selection: $workspace.terraformVersion) {
                        Text("0.15.2")
                    }.pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                    Toggle("Auto apply", isOn: $workspace.autoApply)
                }
            }
            .padding(/*@START_MENU_TOKEN@*/ .all/*@END_MENU_TOKEN@*/)

            Spacer()
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    workspace.save()
                }
            }
        }
    }
}

struct SettingsListPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsListPage(workspace: Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
