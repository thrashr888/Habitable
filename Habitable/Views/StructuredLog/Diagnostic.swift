//
//  Diagnostic.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct DiagnosticCodeView: View {
    var snippet: DiagnosticRangeSnippet

    private func renderedLine(_ line: DiagnosticSnippetLine) -> Text {
        guard let range = line.highlight,
              range.lowerBound >= 0, range.upperBound <= line.text.utf8.count,
              range.lowerBound < range.upperBound else {
            return Text(line.text).foregroundColor(.white)
        }
        let utf8 = line.text.utf8
        let lowerUTF8 = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let upperUTF8 = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        guard let lower = String.Index(lowerUTF8, within: line.text),
              let upper = String.Index(upperUTF8, within: line.text) else {
            return Text(line.text).foregroundColor(.white)
        }
        let before = String(line.text[..<lower])
        let marked = String(line.text[lower..<upper])
        let after = String(line.text[upper...])
        return Text(before).foregroundColor(.white)
            + Text(marked).foregroundColor(.yellow).bold().underline()
            + Text(after).foregroundColor(.white)
    }

    var body: some View {
        let lines = diagnosticSnippetLines(snippet)
        let lineNumberWidth = max(2, String(lines.compactMap(\.number).max() ?? 0).count)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let number = line.number {
                        Text(String(format: "%*d", lineNumberWidth, number))
                            .foregroundColor(.gray)
                            .accessibilityHidden(true)
                    }
                    renderedLine(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.all)
        .background(Color.black)
    }
}

struct DiagnosticView: View {
    var diagnostic: DiagnosticSummary
    var workingDirectory: URL? = nil

    private var sourceURL: URL? {
        guard let filename = diagnostic.range?.filename else { return nil }
        if filename.hasPrefix("/") { return URL(fileURLWithPath: filename) }
        return workingDirectory?.appendingPathComponent(filename)
    }

    @ViewBuilder
    private var severityIndicator: some View {
        switch diagnostic.severity?.lowercased() {
        case "error":
            Label("Error", systemImage: "xmark.octagon.fill")
                .foregroundColor(.red)
        case "warning":
            Label("Warning", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .some(let severity):
            Label(severity.localizedCapitalized, systemImage: "info.circle")
                .foregroundColor(.secondary)
        case .none:
            EmptyView()
        }
    }

    private var severityColor: Color {
        switch diagnostic.severity?.lowercased() {
        case "error": return .red
        case "warning": return .orange
        default: return .secondary
        }
    }
    
//    var sentence: String {
//        var out = ""
//        if let range = diagnostic.range {
//            // TODO link to file URL
//            out += "on \(range.filename ?? "no_filename") line \(range.start?.line ?? 0)"
//        }
//
//        if let context = diagnostic.snippet?.context {
//            out += ", in \(context):"
//        }
//        return out
//    }
    
    var location: some View {
        HStack {
            if let filename = diagnostic.range?.filename {
                Text("on")
                if let sourceURL {
                    Link(filename, destination: sourceURL)
                        .foregroundColor(.accentColor)
                } else {
                    Text(filename)
                }
                if let line = diagnostic.range?.start?.line, line > 0 {
                    Text("line \(line)")
                }
                if let context = diagnostic.snippet?.context {
                    Text(", in \(context):")
                }
            }
        }
        .multilineTextAlignment(/*@START_MENU_TOKEN@*/.leading/*@END_MENU_TOKEN@*/)
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            severityIndicator
            if let summary = diagnostic.summary {
                Text("\(summary)")
            }
            if diagnostic.range?.filename != nil {
                location
            }
            if let snippet = diagnostic.snippet, snippet.code != nil {
                DiagnosticCodeView(snippet: snippet)
            }
            if let detail = diagnostic.detail {
                Text("\(detail)")
            }
        }
        .textSelection(.enabled)
        .padding(.all)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(severityColor, lineWidth: 1)
        }
    }
}

//<div data-test-diagnostic-row ...attributes>
//  <V2::InlineNotification @type={{level}} @title={{title}}>
//    {{#if @diagnostic.address}}
//      <div data-test-address>with {{@diagnostic.address}}</div>
//    {{/if}}
//    {{#if @diagnostic.range}}
//      <span data-test-desc>on {{@diagnostic.range.filename}} line {{@diagnostic.range.start.line ~}}
//      {{~#if @diagnostic.snippet.context~}}, in {{@diagnostic.snippet.context}}{{~/if~}}:</span>
//      {{#if this.code}}
//        <pre class="has-border-left has-padding-none has-margin-vert"><code class="has-padding-left-sm is-text-prewrap" data-test-code>{{{this.code}}}</code></pre>
//      {{/if}}
//    {{/if}}
//    <p data-test-detail>{{@diagnostic.detail}}</p>
//  </V2::InlineNotification>
//</div>
