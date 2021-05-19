//
//  ChangeSummary.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct ChangeSummaryView: View {
    @State var changes: ChangeSummaryChanges
    var body: some View {
        HStack {
            Text("\(changes.add) created")
            Text("\(changes.change) changed")
            Text("\(changes.remove) destroyed")
        }
    }
}
