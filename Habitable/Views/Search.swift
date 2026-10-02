//
//  File.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/15/21.
//

import SwiftUI

struct SearchField: NSViewRepresentable {

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                print("Unexpected control in update notification")
                return
            }
            self.parent.search = searchField.stringValue
        }

    }

    @Binding var search: String
    var accessibilityLabel: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.setAccessibilityLabel(accessibilityLabel)
        searchField.placeholderString = accessibilityLabel
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        searchField.stringValue = search
        searchField.delegate = context.coordinator
        searchField.setAccessibilityLabel(accessibilityLabel)
        searchField.placeholderString = accessibilityLabel
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

}
