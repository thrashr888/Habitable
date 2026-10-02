//
//  JsonLog.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Combine
import Foundation
import SwiftyJSON

enum ChangeActions: String, Sendable {
    case NoOp = "noop"
    case Create = "create"
    case Read = "read"
    case Update = "update"
    case Replace = "replace"
    case Delete = "delete"
}

enum MessageTypes: String, Sendable {
    // Generic messages
    case Version = "version"
    case Log = "log"
    case Diagnostic = "diagnostic"

    // Operation results
    case PlannedChange = "planned_change"
    case ChangeSummary = "change_summary"
    case Outputs = "outputs"

    // Hook-driven messages
    case ApplyStart = "apply_start"
    case ApplyProgress = "apply_progress"
    case ApplyComplete = "apply_complete"
    case ApplyErrored = "apply_errored"
    case ProvisionStart = "provision_start"
    case ProvisionProgress = "provision_progress"
    case ProvisionComplete = "provision_complete"
    case ProvisionErrored = "provision_errored"
    case RefreshStart = "refresh_start"
    case RefreshComplete = "refresh_complete"
}

func isResourceMessage(_ message: JSON) -> Bool {
    if !message["type"].exists() { return false }
    return message["type"].string == MessageTypes.PlannedChange.rawValue || isHookMessage(message)
}

func isHookMessage(_ message: JSON) -> Bool {
    if !message["type"].exists() { return false }
    guard let mType = message["type"].string, let type = MessageTypes(rawValue: mType) else { return false }

    return [
        MessageTypes.ApplyStart,
        MessageTypes.ApplyProgress,
        MessageTypes.ApplyComplete,
        MessageTypes.ApplyErrored,
        MessageTypes.ProvisionStart,
        MessageTypes.ProvisionProgress,
        MessageTypes.ProvisionComplete,
        MessageTypes.ProvisionErrored,
        MessageTypes.RefreshStart,
        MessageTypes.RefreshComplete,
    ].contains(type)
}

protocol tfMessage {
    var id: UUID { get }
    var type: MessageTypes { get }
    var message: String? { get }
}

struct LogMessage: tfMessage, Sendable {
    var id = UUID()
    var type: MessageTypes = .Log
    var message: String?
}

func transformLog(_ log: JSON) -> LogMessage {
    return LogMessage(
        message: log["@message"].string ?? log.rawString()
    )
}

struct VersionMessage: tfMessage, Sendable {
    var id = UUID()
    var type: MessageTypes = .Version
    var message: String?
    var version: String?
}

func transformVersion(_ log: JSON) -> VersionMessage {
    return VersionMessage(
        message: log["@message"].string,
        version: log["terraform"].string
    )
}

struct ChangeSummaryChanges: Sendable {
    var add: Int
    var change: Int
    var remove: Int
    var operation: String?
}

struct ChangeSummaryMessage: tfMessage, Sendable {
    var id = UUID()
    var type: MessageTypes = .ChangeSummary
    var message: String?
    var changes: ChangeSummaryChanges
}

func transformChangeSummary(_ log: JSON) -> ChangeSummaryMessage {
    return ChangeSummaryMessage(
        message: log["@message"].string,
        changes: ChangeSummaryChanges(
            add: log["changes"]["add"].int ?? 0,
            change: log["changes"]["change"].int ?? 0,
            remove: log["changes"]["remove"].int ?? 0,
            operation: log["changes"]["operation"].string
        )
    )
}

class Output: Identifiable {
    var id = UUID()
    var key: String
    var type: String?
    var value: String?
    var sensitive = false
    init(key: String, type: String?, value: String?, sensitive: Bool) {
        self.key = key
        self.type = type
        self.value = value
        self.sensitive = sensitive
    }
}

extension Output: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    static func ==(lhs: Output, rhs: Output) -> Bool {
        return lhs === rhs
    }
}

struct OutputsMessage: tfMessage {
    var id = UUID()
    var type: MessageTypes = .Outputs
    var message: String?
    var outputs: [Output] = []
}

/// Terraform values are valid JSON. Foundation preserves deeply nested objects
/// and escapes their keys without SwiftyJSON's optional-value depth limit.
func terraformOutputValue(_ value: JSON) -> String? {
    if let string = value.string { return string }
    guard value.exists(),
          let data = try? JSONSerialization.data(withJSONObject: value.object,
                                                options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
}

func terraformOutputType(_ type: JSON) -> String? {
    type.string ?? type.arrayValue.first?.string
}

func transformOutputs(_ log: JSON) -> OutputsMessage {
    var outputs: [Output] = []
    for (k, out) in log["outputs"] {
        let add = Output(
            key: k,
            type: terraformOutputType(out["type"]),
            value: terraformOutputValue(out["value"]),
            sensitive: out["sensitive"].boolValue
        )
        outputs.append(add)
    }
    return OutputsMessage(
        message: log["@message"].string,
        outputs: outputs
    )
}

struct DiagnosticRangeSnippet: Sendable {
    var context: String?
    var code: String?
    var startLine: Int
    var highlightStartOffset: Int
    var highlightEndOffset: Int
    var values: [String] = []
}

struct DiagnosticSnippetLine: Sendable {
    var number: Int?
    var text: String
    /// Terraform 1.16.5 emits these as UTF-8 byte offsets into the snippet.
    /// Keep them as byte offsets until the renderer verifies UTF-8 boundaries.
    var highlight: Range<Int>?
}

func diagnosticSnippetLines(_ snippet: DiagnosticRangeSnippet) -> [DiagnosticSnippetLine] {
    guard let code = snippet.code else { return [] }
    let bytes = Array(code.utf8)
    let requestedStart = snippet.highlightStartOffset
    let requestedEnd = snippet.highlightEndOffset
    func isUTF8Boundary(_ offset: Int) -> Bool {
        guard offset >= 0, offset <= bytes.count else { return false }
        let index = code.utf8.index(code.utf8.startIndex, offsetBy: offset)
        return String.Index(index, within: code) != nil
    }
    let startIsBoundary = isUTF8Boundary(requestedStart)
    let endIsBoundary = isUTF8Boundary(requestedEnd)
    let validHighlight = startIsBoundary && endIsBoundary && requestedEnd > requestedStart
    let highlightStart = requestedStart
    let highlightEnd = requestedEnd

    var result: [DiagnosticSnippetLine] = []
    var lineStart = 0
    var lineNumber = 0
    for index in 0...bytes.count {
        guard index == bytes.count || bytes[index] == 0x0A else { continue }
        let lineText = String(decoding: bytes[lineStart..<index], as: UTF8.self)
        let overlapStart = max(lineStart, highlightStart)
        let overlapEnd = min(index, highlightEnd)
        let lineHighlight = validHighlight && overlapEnd > overlapStart
            ? (overlapStart - lineStart)..<(overlapEnd - lineStart) : nil
        let (candidateNumber, overflow) = snippet.startLine.addingReportingOverflow(lineNumber)
        let number = snippet.startLine > 0 && !overflow ? candidateNumber : nil
        result.append(DiagnosticSnippetLine(number: number, text: lineText, highlight: lineHighlight))
        lineNumber += 1
        lineStart = index + 1
    }
    return result
}

struct DiagnosticRangeLocation: Sendable {
    var line: Int
    var column: Int
    var byte: Int
}

struct DiagnosticRange: Sendable {
    var filename: String?
    var start: DiagnosticRangeLocation?
    var end: DiagnosticRangeLocation?
}

struct DiagnosticSummary: Sendable {
    var severity: String?
    var summary: String?
    var detail: String?
    var range: DiagnosticRange?
    var snippet: DiagnosticRangeSnippet?
}

struct DiagnosticMessage: tfMessage, Sendable {
    var id = UUID()
    var type: MessageTypes = .Diagnostic
    var message: String?
    var diagnostic: DiagnosticSummary
}

func transformDiagnostic(_ log: JSON) -> DiagnosticMessage {
    let r = log["diagnostic"]["range"]
    let s = log["diagnostic"]["snippet"]
    let range = DiagnosticRange(
        filename: r["filename"].string,
        start: DiagnosticRangeLocation(
            line: r["start"]["line"].int ?? 0,
            column: r["start"]["column"].int ?? 0,
            byte: r["start"]["byte"].int ?? 0
        ),
        end: DiagnosticRangeLocation(
            line: r["end"]["line"].int ?? 0,
            column: r["end"]["column"].int ?? 0,
            byte: r["end"]["byte"].int ?? 0
        )
    )
    return DiagnosticMessage(
        message: log["@message"].string,
        diagnostic: DiagnosticSummary(
            severity: log["diagnostic"]["severity"].string,
            summary: log["diagnostic"]["summary"].string,
            detail: log["diagnostic"]["detail"].string,
            range: range,
            snippet: DiagnosticRangeSnippet(
                context: s["context"].string,
                code: s["code"].string,
                startLine: s["start_line"].int ?? 0,
                highlightStartOffset: s["highlight_start_offset"].int ?? 0,
                highlightEndOffset: s["highlight_end_offset"].int ?? 0,
                values: s["values"].map({ (v, _) in
                    v
                })
            )
        )
    )
}

struct HookMessage: tfMessage, Sendable {
    var id = UUID()
    var type: MessageTypes
    var message: String?
    var address: String
    var resource: Resource
    var action: ChangeActions = .NoOp
    var elapsed_seconds: String?
    var provisioner: Provisioner?
    var output: [String] = []
    var id_key: String?
    var id_value: String?
}

func transformHook(_ log: JSON) -> HookMessage? {
    guard let mType = log["type"].string, let type = MessageTypes(rawValue: mType) else {
        return nil
    }

    let hook = log["hook"]

    var action: ChangeActions?
    if let value = hook["action"].string {
        action = ChangeActions(rawValue: value)
    }

    return HookMessage(
        type: type,
        message: log["@message"].string,
        address: hook["resource"]["addr"].string ?? "no address",
        resource: Resource(
            addr: hook["resource"]["addr"].string ?? "no address",
            module: hook["resource"]["module"].string,
            resource: hook["resource"]["resource"].string,
            implied_provider: hook["resource"]["implied_provider"].string,
            resource_type: hook["resource"]["resource_type"].string,
            resource_name: hook["resource"]["resource_name"].string,
            resource_key: hook["resource"]["resource_key"].string
        ),
        action: action ?? .NoOp,
        elapsed_seconds: hook["elapsed_seconds"].string,
        id_key: hook["id_key"].string,
        id_value: hook["id_value"].string
    )
}

struct Resource: Sendable {
    var addr: String
    var module: String?
    var resource: String?
    var implied_provider: String?
    var resource_type: String?
    var resource_name: String?
    var resource_key: String?
}

struct PlannedChangeSummary: Sendable {
    var address: String
    var resource: Resource
    var action: ChangeActions = .NoOp
}

struct PlannedChangeMessage: tfMessage, Sendable {
    var id = UUID()
    var type: MessageTypes = .PlannedChange
    var message: String?
    var change: PlannedChangeSummary
}

func transformPlannedChange(_ log: JSON) -> PlannedChangeMessage {
    let change = log["change"]
    let resource = change["resource"]

    var action: ChangeActions?
    if let value = change["action"].string {
        action = ChangeActions(rawValue: value)
    }
    return PlannedChangeMessage(
        message: log["@message"].string,
        change: PlannedChangeSummary(
            address: resource["addr"].string ?? "no address",
            resource: Resource(
                addr: resource["addr"].string ?? "no address",
                module: resource["module"].string,
                resource: resource["resource"].string,
                implied_provider: resource["implied_provider"].string,
                resource_type: resource["resource_type"].string,
                resource_name: resource["resource_name"].string,
                resource_key: resource["resource_key"].string
            ),
            action: action ?? .NoOp
        )
    )
}

// "Resources"
@MainActor
class ShowResource: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    var address: String?
    var mode: String?
    var type: String?
    var name: String?
    var provider_name: String?
    var schema_version: Int?
    var values: [String: JSON]?
    
    init(address: String?, mode: String?, type: String?, name: String?, provider_name: String?, schema_version: Int?, values: Dictionary<String, JSON>?) {
        self.address = address
        self.mode = mode
        self.type = type
        self.name = name
        self.provider_name = provider_name
        self.schema_version = schema_version
        self.values = values
    }
}

extension ShowResource: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    nonisolated static func ==(lhs: ShowResource, rhs: ShowResource) -> Bool {
        return lhs === rhs
    }
}

struct ShowModule {
    var resources: [ShowResource]
}

struct ShowValues {
    var outputs: [Output]
}

struct ShowMessage {
    var id = UUID()
    var format_version: String?
    var terraform_version: String?
    var values: ShowValues
    var outputs: [Output]
    var root_module: ShowModule
    var resources: [ShowResource]
    let created_at = Date()
}

@MainActor
func transformShow(_ log: JSON) -> ShowMessage {
    var outputs: [Output] = []
    for (k, out) in log["values"]["outputs"] {
        let add = Output(
            key: k,
            type: terraformOutputType(out["type"]),
            value: terraformOutputValue(out["value"]),
            sensitive: out["sensitive"].boolValue
        )
        outputs.append(add)
    }

    func collectResources(from module: JSON) -> [ShowResource] {
        var moduleResources: [ShowResource] = []
        for (_, res) in module["resources"] {
            let add = ShowResource(
                address: res["address"].string,
                mode: res["mode"].string,
                type: res["type"].string,
                name: res["name"].string,
                provider_name: res["provider_name"].string,
                schema_version: res["schema_version"].int,
                values: res["values"].dictionary
            )
            moduleResources.append(add)
        }

        for (_, childModule) in module["child_modules"] {
            moduleResources.append(contentsOf: collectResources(from: childModule))
        }
        return moduleResources
    }

    // Terraform's state JSON stores each module's resources at that module
    // level. Resource addresses already include the complete module path (and
    // any count/for_each key), so retain them as emitted while walking the tree.
    let resources = collectResources(from: log["values"]["root_module"])

    return ShowMessage(
        format_version: log["format_version"].string,
        terraform_version: log["terraform_version"].string,
        values: ShowValues(
            outputs: outputs
        ),
        outputs: outputs,
        root_module: ShowModule(
            resources: resources
        ),
        resources: resources
    )
}
