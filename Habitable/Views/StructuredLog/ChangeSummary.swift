//
//  ChangeSummary.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct ChangeSummaryView: View {
    var changes: ChangeSummaryChanges
    var body: some View {
        HStack(spacing: 20) {
            Label("Add: \(changes.add)", systemImage: "plus.circle")
            Label("Change: \(changes.change)", systemImage: "pencil.circle")
            Label("Destroy: \(changes.remove)", systemImage: "minus.circle")
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}
