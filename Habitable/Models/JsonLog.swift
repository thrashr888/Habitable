//
//  JsonLog.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Combine
import Foundation
import SwiftyJSON

enum ChangeActions: String {
    case NoOp = "noop"
    case Create = "create"
    case Read = "read"
    case Update = "update"
    case Replace = "replace"
    case Delete = "delete"
}

enum MessageTypes: String {
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

struct LogMessage: tfMessage {
    var id = UUID()
    var type: MessageTypes = .Log
    var message: String?
}

func transformLog(_ log: JSON) -> LogMessage {
    return LogMessage(
        message: log["@message"].string
    )
}

struct VersionMessage: tfMessage {
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

struct ChangeSummaryChanges {
    var add: Int
    var change: Int
    var remove: Int
    var operation: String?
}

struct ChangeSummaryMessage: tfMessage {
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

func transformOutputs(_ log: JSON) -> OutputsMessage {
    var outputs: [Output] = []
    for (k, out) in log["outputs"] {
        let add = Output(
            key: k,
            type: out["type"].string,
            value: out["value"].rawString([.castNilToNSNull: true]),
            sensitive: out["sensitive"].boolValue
        )
        outputs.append(add)
    }
    return OutputsMessage(
        message: log["@message"].string,
        outputs: outputs
    )
}

struct DiagnosticRangeSnippet {
    var context: String?
    var code: String?
    var startLine: Int
    var highlightStartOffset: Int
    var highlightEndOffset: Int
    var values: [String] = []
}

struct DiagnosticRangeLocation {
    var line: Int
    var column: Int
    var byte: Int
}

struct DiagnosticRange {
    var filename: String?
    var start: DiagnosticRangeLocation?
    var end: DiagnosticRangeLocation?
}

struct DiagnosticSummary {
    var severity: String?
    var summary: String?
    var detail: String?
    var range: DiagnosticRange?
    var snippet: DiagnosticRangeSnippet?
}

struct DiagnosticMessage: tfMessage {
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
                startLine: r["snippet"]["start_line"].int ?? 0,
                highlightStartOffset: s["highlight_start_offset"].int ?? 0,
                highlightEndOffset: s["highlight_end_offset"].int ?? 0,
                values: s["values"].map({ (v, _) in
                    v
                })
            )
        )
    )
}

struct HookMessage: tfMessage {
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

struct Resource {
    var addr: String
    var module: String?
    var resource: String?
    var implied_provider: String?
    var resource_type: String?
    var resource_name: String?
    var resource_key: String?
}

struct PlannedChangeSummary {
    var address: String
    var resource: Resource
    var action: ChangeActions = .NoOp
}

struct PlannedChangeMessage: tfMessage {
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
class ShowResource: ObservableObject, Identifiable {
    var id = UUID()
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
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    static func ==(lhs: ShowResource, rhs: ShowResource) -> Bool {
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

func transformShow(_ log: JSON) -> ShowMessage {
    var outputs: [Output] = []
    for (k, out) in log["values"]["outputs"] {
        let add = Output(
            key: k,
            type: nil, // show has no type
            value: out["value"].rawString([.castNilToNSNull: true]),
            sensitive: out["sensitive"].boolValue
        )
        outputs.append(add)
    }

    var resources: [ShowResource] = []
    for (_, res) in log["values"]["root_module"]["resources"] {
        let add = ShowResource(
            address: res["address"].string,
            mode: res["mode"].string,
            type: res["type"].string,
            name: res["name"].string,
            provider_name: res["provider_name"].string,
            schema_version: res["schema_version"].int,
            values: res["values"].dictionary
        )
        resources.append(add)
    }

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
