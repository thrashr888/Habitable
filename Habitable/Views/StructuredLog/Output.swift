//
//  Output.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct OutputView: View {
    var outputs: [Output]
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(outputs, id: \.id) { output in
                HStack {
                    if let type = output.type {
                        Text("\(output.key) [\(type)]: ")
                    } else {
                        Text("\(output.key): ")
                    }
                    if output.sensitive {
                        Text("(sensitive)")
                    } else {
                        Text("\(output.value ?? "n/a")")
                    }
                }
            }
        }
    }
}
