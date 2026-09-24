//
//  ContentView.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Foundation
import SwiftUI

struct ContentView: View {
    enum NavigationItem: String {
        case workspace
        case runs
        case resources
        case outputs
        case variables
        case envVariables
        case settings
    }

//    @AppStorage("workingDirectory") private var workingDirectory: URL?
    @StateObject var workspace = Workspace()
//    @SceneStorage("menuSelection") private var selection = NavigationItem.workspace

//    @SceneStorage("selection") var selection: String?
//    @SceneStorage("menuSelection") var menuSelection: Set<NavigationItem> = [.workspace]
    @State private var selection: Set<NavigationItem> = [.workspace]
    var showThirdColumn: Bool {
        selection != [NavigationItem.settings]
    }
    
    var body: some View {
        if workspace.workingDirectory == nil {
            BlankSlateView().environmentObject(workspace)
                .onAppear {
//                    if let dir = workingDirectory {
//                        workspace.updateWorkingDirectory(dir: dir)
//                    }
                }
        } else {
            NavigationView {
                sidebar
                
                Text("Content List")
                
                if showThirdColumn {
                    Text("")
                }
            }.environmentObject(workspace)
        }
    }
    
    struct Pocket: View {
        @EnvironmentObject var workspace: Workspace
        var body: some View {
            VStack {
                if workspace.locked {
                    Label("Locked", systemImage: "lock.fill")
                        .help("Locked")
                } else {
                    Label("Unlocked", systemImage: "lock.open.fill")
                        .help("Unlocked")
                }
            }.padding()
        }
    }
    
    var sidebar: some View {
        List(selection: $selection) {
            NavigationLink(destination: WorkspacePage()) {
                Label("Workspace", systemImage: "folder")
            }
            .accessibility(label: Text("Workspace"))
            .tag(NavigationItem.workspace)

            NavigationLink(destination: RunListPage()) {
                Label("Runs (\(workspace.runs.count))", systemImage: "list.bullet.rectangle")
            }
            .accessibility(label: Text("Runs"))
            .tag(NavigationItem.runs)

            NavigationLink(destination: ResourceListPage()) {
                Label("Resources (\(workspace.state?.resources.count ?? 0))", systemImage: "globe")
            }
            .accessibility(label: Text("Resources"))
            .tag(NavigationItem.resources)
            
            NavigationLink(destination: OutputsListPage()) {
                Label("Outputs (\(workspace.state?.outputs.count ?? 0))", systemImage: "chevron.right.square")
            }
            .accessibility(label: Text("Outputs"))
            .tag(NavigationItem.outputs)

            NavigationLink(destination: VariableListPage()) {
                Label("Variables (\(workspace.terraformVariables.count))", systemImage: "dollarsign.circle")
            }
            .accessibility(label: Text("Terraform Variables"))
            .tag(NavigationItem.variables)
            
            NavigationLink(destination: EnvVarListPage()) {
                Label("Env Vars (\(workspace.environmentVariables.count))", systemImage: "dollarsign.circle")
            }
            .accessibility(label: Text("Environment Variables"))
            .tag(NavigationItem.envVariables)

            NavigationLink(destination: SettingsListPage()) {
                Label("Settings", systemImage: "gear")
            }
            .accessibility(label: Text("Settings"))
            .tag(NavigationItem.settings)
        }
        .overlay(Pocket(), alignment: .bottom)
        .listStyle(SidebarListStyle())
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
