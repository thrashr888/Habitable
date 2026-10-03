//
//  HabitableApp.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import SwiftUI

@main
struct HabitableApp: App {
    var body: some Scene {
        WindowGroup("Workspace", id: "Workspace.viewer") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands { WorkspaceCommands() }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceWindowActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button { actions?.openFolder() } label: { Label("Open…", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil)
            Menu("Open Recent") {
                if let actions, !actions.recentFolders.isEmpty {
                    ForEach(actions.recentFolders, id: \.path) { url in
                        Button("\(url.lastPathComponent) — \(url.path)") { actions.openRecent(url) }
                    }
                    Divider()
                    Button("Clear Recent Folders") { actions.clearRecents() }
                } else {
                    Text("No Recent Folders").disabled(true)
                }
            }
            .disabled(actions == nil)
        }
        CommandMenu("Terraform") {
            Button(actions?.planTitle ?? "Plan") { actions?.plan() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.canPlan != true)
            Divider()
            Button("Initialize Terraform") { actions?.initialize() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.canInitialize != true)
            Button("Validate Configuration") { actions?.validate() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.canValidate != true)
        }
    }
}
