//
//  OutputPage.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/14/21.
//

import SwiftUI

struct OutputPageView: View {
    var output: Output
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.headline)
                Text(output.key)

                if let type = output.type {
                    Text("Type")
                        .font(.headline)
                        .padding(.top)
                    Text(type)
                }

                Text("Value")
                    .font(.headline)
                    .padding(.top)
                if output.sensitive {
                    Text("(sensitive)")
                } else {
                    Text(output.value ?? "Value unavailable")
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
