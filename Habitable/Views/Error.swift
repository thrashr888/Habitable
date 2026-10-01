//
//  Error.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/9/21.
//

import SwiftUI

struct ErrorView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(message)
                .foregroundColor(.red)
        }
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ErrorView(message: """
        Test error:
        ok
        """)
    }
}
