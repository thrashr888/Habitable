//
//  OutputPage.swift
//  Habitable
//

import SwiftUI

struct OutputPageView: View {
    var output: Output

    private var displayedValue: String {
        output.displayValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow(alignment: .top) {
                        Text("Name").foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(output.key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            SafeCopyButton(value: output.key, label: "Copy output name \(output.key)")
                        }
                    }
                    if let type = output.type {
                        GridRow(alignment: .top) {
                            Text("Type").foregroundStyle(.secondary)
                            Text(type).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Value").font(.headline)
                    Spacer()
                    if !output.sensitive, output.value != nil {
                        SafeCopyButton(value: displayedValue, label: "Copy value for output \(output.key)", showsTitle: true)
                    }
                }
                Text(displayedValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}
