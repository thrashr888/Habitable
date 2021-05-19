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
        VStack(alignment: .leading) {
            Text("Name")
                .font(.headline)
            Text("\(output.key)")
            
            if let type = output.type {
                Text("Type")
                    .font(.headline)
                    .padding(.top)
                Text("\(type)")
            }
            
            Text("Value")
                .font(.headline)
                .padding(.top)
            if output.sensitive {
                Text("(sensitive)")
            } else {
                Text("\(output.value ?? "")")
            }
            
            Spacer()
        }
        .padding(.all)
        .frame(minWidth: 0, idealWidth: 100, maxWidth: .infinity, minHeight: 0, idealHeight: 100, maxHeight: .infinity, alignment: .leading)
    }
}
