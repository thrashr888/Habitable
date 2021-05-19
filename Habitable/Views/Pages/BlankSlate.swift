//
//  BlankSlate.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/9/21.
//

import SwiftUI

struct BlankSlateView: View {
    @EnvironmentObject var workspace: Workspace
    var body: some View {
        Text("Working directory")
            .font(.headline)
            .padding(.top)
        Button("Choose folder", action: workspace.addUrl)
    }
}
