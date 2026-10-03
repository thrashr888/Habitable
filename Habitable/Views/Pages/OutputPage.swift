//
//  OutputPage.swift
//  Habitable
//

import AppKit
import SwiftUI

struct OutputPageView: View {
    var output: Output

    private var displayedValue: String {
        guard !output.sensitive else { return "(sensitive value)" }
        guard let value = output.value else { return "Value unavailable" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else { return value }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow(alignment: .top) {
                        Text("Name").foregroundStyle(.secondary)
                        Text(output.key).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
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
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(displayedValue, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy output value")
                        .accessibilityLabel("Copy value for output \(output.key)")
                    }
                }
                Text(displayedValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}
