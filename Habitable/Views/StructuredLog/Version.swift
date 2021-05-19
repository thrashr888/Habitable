//
//  Version.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct VersionView: View {
    var version: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("Version: \(version)")
        }
    }
}
