//
//  Log.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct LogView: View {
    var message: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(message)")
        }
    }
}
