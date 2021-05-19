//
//  Diagnostic.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/13/21.
//

import SwiftUI

struct DiagnosticCodeView: View {
    var text: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.all)
        .background(Color.black)
    }
}

struct DiagnosticView: View {
    @State var diagnostic: DiagnosticSummary
    
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
                // TODO add the working directory to this filename so the link works
                Link(filename, destination: URL(fileURLWithPath: filename, isDirectory: false))
                    .foregroundColor(.accentColor)
                if let context = diagnostic.snippet?.context {
                    Text(", in \(context):")
                }
            }
        }
        .multilineTextAlignment(/*@START_MENU_TOKEN@*/.leading/*@END_MENU_TOKEN@*/)
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            if let severity = diagnostic.severity {
                Text("\(severity.localizedCapitalized)")
                    .foregroundColor(.red)
            }
            if let summary = diagnostic.summary {
                Text("\(summary)")
            }
            if diagnostic.range?.filename != nil {
                location
            }
            if let code = diagnostic.snippet?.code {
                DiagnosticCodeView(text: code)
            }
            if let detail = diagnostic.detail {
                Text("\(detail)")
            }
        }
        .padding(.all)
        .border(Color.red, width: 1)
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
