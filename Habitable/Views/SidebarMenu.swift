//
//  SidebarMenu.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct AppSidebarNavigation: View {
    enum NavigationItem {
        case workspace
        case runs
        case states
        case variables
        case settings
    }

    @ObservedObject var model: TerraformRunner
    @ObservedObject var workspace: Workspace
    @State private var selection: Set<NavigationItem> = [.workspace]

    var body: some View {
        NavigationView {
            List(selection: $selection) {
                NavigationLink(destination: WorkspacePage(workspace: workspace)) {
                    Label("Workspace", systemImage: "folder")
                }
                .accessibility(label: Text("Workspace"))
                .tag(NavigationItem.workspace)

                NavigationLink(destination: RunsListPage(workspace: workspace, runs: workspace.runs)) {
                    Label("Runs", systemImage: "list.bullet.rectangle")
                }
                .accessibility(label: Text("Runs"))
                .tag(NavigationItem.runs)

                NavigationLink(destination: ResourceListPage(workspace: workspace)) {
                    Label("Resources", systemImage: "globe")
                }
                .accessibility(label: Text("Resources"))
                .tag(NavigationItem.states)

                NavigationLink(destination: VariableListPage(workspace: workspace, variables: workspace.variables)) {
                    Label("Variables", systemImage: "dollarsign.circle")
                }
                .accessibility(label: Text("Variables"))
                .tag(NavigationItem.variables)

                NavigationLink(destination: SettingsListPage(workspace: workspace)) {
                    Label("Settings", systemImage: "gear")
                }
                .accessibility(label: Text("Settings"))
                .tag(NavigationItem.settings)
            }
            .listStyle(SidebarListStyle())
        }
    }
}

struct AppSidebarNavigation_Previews: PreviewProvider {
    static var previews: some View {
        AppSidebarNavigation(model: TerraformRunner(dir: URL(fileURLWithPath: "~/workspace/Habitable")), workspace: Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
