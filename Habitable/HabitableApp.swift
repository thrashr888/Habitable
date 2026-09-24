//
//  HabitableApp.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import SwiftUI

@main
struct HabitableApp: App {
    @AppStorage("lastWorkingDirectory") var lastWorkingDirectory: URL?
    
    var body: some Scene {
        WindowGroup("Workspace", id: "Workspace.viewer") {
            ContentView()
                .frame(minWidth: 900, minHeight: 480)
        }
    }
}
