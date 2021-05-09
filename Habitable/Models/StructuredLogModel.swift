//
//  StructuredLogModel.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/5/21.
//

import Foundation

class StructuredLog: ObservableObject {
    var logs: [LogMessage] = []
    var changeSummaries: [ChangeSummaryMessage] = []
    var versions: [VersionMessage] = []
    var diagnostics: [DiagnosticMessage] = []
    var resources: [ResourceState] = []
    var outputs: [OutputsMessage] = []
}
