//
//  StructuredLogModel.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/5/21.
//

import Combine
import Foundation
import SwiftyJSON

@MainActor
class StructuredLog: ObservableObject {
    var id = UUID()
    var logs: [LogMessage] = [] { willSet { objectWillChange.send() } }
    var changeSummaries: [ChangeSummaryMessage] = [] { willSet { objectWillChange.send() } }
    var versions: [VersionMessage] = [] { willSet { objectWillChange.send() } }
    var diagnostics: [DiagnosticMessage] = [] { willSet { objectWillChange.send() } }
    var resources: [ResourceState] = [] { willSet { objectWillChange.send() } }
    var outputs: [OutputsMessage] = [] { willSet { objectWillChange.send() } }
    var isComplete = false { willSet { objectWillChange.send() } }
    var schemaError: String? { willSet { objectWillChange.send() } }
    var createdAt = Date()

    func appendLog(_ message: LogMessage) {
        logs.append(message)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    func appendDiagnostic(_ message: DiagnosticMessage) {
        diagnostics.append(message)
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
    }

    func appendSummary(_ message: ChangeSummaryMessage) {
        changeSummaries = [message]
    }

    func appendVersion(_ message: VersionMessage) {
        versions = [message]
    }

    func appendOutputs(_ message: OutputsMessage) {
        outputs = [message]
    }

    func appendResource(_ resource: ResourceState) {
        resources.append(resource)
        if resources.count > 500 { resources.removeFirst(resources.count - 500) }
    }
}

enum PlanReviewedValue: Equatable, Sendable {
    case absent
    case value(String)
    case unknown
    case sensitive

    var displayValue: String {
        switch self {
        case .absent: return "—"
        case .value(let value): return value
        case .unknown: return "(known after apply)"
        case .sensitive: return "(sensitive value)"
        }
    }
}

struct PlanAttributeChange: Identifiable, Equatable, Sendable {
    let path: String
    let before: PlanReviewedValue
    let after: PlanReviewedValue

    var id: String { path }
}

struct PlanResourceChange: Identifiable, Equatable, Sendable {
    let address: String
    let action: String
    let actionOrder: [String]
    let attributes: [PlanAttributeChange]
    let replacementPaths: [String]
    let originalAddress: String?
    let importingID: String?

    var id: String { address }
    var isReplacement: Bool { action == "replace" || (actionOrder.contains("create") && actionOrder.contains("delete")) }

    init(address: String, action: String, attributes: [PlanAttributeChange], replacementPaths: [String],
         actionOrder: [String] = [], originalAddress: String? = nil, importingID: String? = nil) {
        self.address = address
        self.action = action
        self.actionOrder = actionOrder
        self.attributes = attributes
        self.replacementPaths = replacementPaths
        self.originalAddress = originalAddress
        self.importingID = importingID
    }
}

struct PlanOutputChange: Identifiable, Equatable, Sendable {
    let name: String
    let action: String
    let attributes: [PlanAttributeChange]

    var id: String { name }
}

struct TerraformPlan: Equatable, Sendable {
    let resourceChanges: [PlanResourceChange]
    let outputChanges: [PlanOutputChange]
    let formatVersion: String?
    let terraformVersion: String?

    var consequences: PlanConsequences { PlanConsequences(plan: self) }

    init(resourceChanges: [PlanResourceChange], outputChanges: [PlanOutputChange],
         formatVersion: String? = nil, terraformVersion: String? = nil) {
        self.resourceChanges = resourceChanges
        self.outputChanges = outputChanges
        self.formatVersion = formatVersion
        self.terraformVersion = terraformVersion
    }
}

/// Replacement is its own action, avoiding duplicate create/destroy totals.
struct PlanConsequences: Equatable, Sendable {
    var create = 0
    var update = 0
    var replace = 0
    var destroy = 0
    var read = 0
    var imports = 0
    var moves = 0
    var outputs = 0

    init(plan: TerraformPlan) {
        for change in plan.resourceChanges {
            if change.isReplacement { replace += 1 }
            else if change.action == "create" { create += 1 }
            else if change.action == "update" { update += 1 }
            else if change.action == "delete" { destroy += 1 }
            else if change.action == "read" { read += 1 }
            if change.importingID != nil { imports += 1 }
            if change.originalAddress != nil { moves += 1 }
        }
        outputs = plan.outputChanges.filter { $0.action != "no-op" }.count
    }

    var summary: String {
        let parts = [(create, "create"), (update, "update"), (replace, "replace"),
                     (destroy, "destroy"), (read, "read"), (imports, "import"), (moves, "move")]
            .filter { $0.0 > 0 }.map { "\($0.0) to \($0.1)" }
        let resources = parts.isEmpty ? "No resource changes" : parts.joined(separator: " · ")
        return outputs > 0 ? "\(resources) · \(outputs) output\(outputs == 1 ? "" : "s") to change" : resources
    }
}

func planResourceChangesEmptyMessage(hasVisibleChanges: Bool, hasAddressFilter: Bool,
                                     hasOperationFilter: Bool) -> String? {
    guard !hasVisibleChanges else { return nil }
    return hasAddressFilter || hasOperationFilter
        ? "No resources match this filter."
        : "No resource changes in this plan."
}

func transformPlan(_ source: JSON) -> TerraformPlan {
    let log = redactEchoedPlanValues(source)
    return TerraformPlan(
        resourceChanges: log["resource_changes"].arrayValue.map(transformPlanResourceChange),
        outputChanges: log["output_changes"].dictionaryValue.keys.sorted().map { name in
            transformPlanOutputChange(name: name, change: log["output_changes"][name])
        },
        formatVersion: log["format_version"].string,
        terraformVersion: log["terraform_version"].string
    )
}

/// A provider can echo a marked secret into an unmarked attribute, another
/// resource, or an output. Sanitize payloads before flattening so every review
/// consumer receives safe strings, including composite values and paths.
private func redactEchoedPlanValues(_ source: JSON) -> JSON {
    var strings = Set<String>()
    var scalars = Set<String>()
    func collectAll(_ value: JSON) {
        if let text = value.string, !text.isEmpty { strings.insert(text) }
        else if let object = value.dictionary {
            strings.formUnion(object.keys.filter { !$0.isEmpty })
            object.values.forEach(collectAll)
        }
        else if let array = value.array { array.forEach(collectAll) }
        else if value.type != .null { scalars.insert(value.rawString() ?? "") }
    }
    func collect(_ value: JSON, _ mask: JSON) {
        if mask.bool == true { collectAll(value); return }
        if let object = value.dictionary {
            for (key, child) in object { collect(child, mask[key]) }
        } else if let array = value.array {
            for (index, child) in array.enumerated() { collect(child, mask[index]) }
        }
    }
    let changes = source["resource_changes"].arrayValue.map { $0["change"] }
        + Array(source["output_changes"].dictionaryValue.values)
    for change in changes {
        collect(change["before"], change["before_sensitive"])
        collect(change["after"], change["after_sensitive"])
    }
    let literals = strings.sorted { $0.count > $1.count }
    func safeText(_ text: String) -> String {
        let safe = literals.reduce(text) { $0.replacingOccurrences(of: $1, with: "(sensitive value)") }
        return scalars.sorted { $0.count > $1.count }.reduce(safe) { result, token in
            guard !token.isEmpty,
                  let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])\(NSRegularExpression.escapedPattern(for: token))(?![A-Za-z0-9_.])") else { return result }
            return regex.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result), withTemplate: "(sensitive value)")
        }
    }
    func sanitize(_ value: JSON) -> JSON {
        if let text = value.string { return JSON(safeText(text)) }
        if let object = value.dictionary {
            // Redacted keys can collide. Do not re-expose either value.
            var safe: [String: JSON] = [:]
            for (key, child) in object {
                let key = safeText(key)
                safe[key] = safe[key] == nil ? sanitize(child) : JSON("(sensitive value)")
            }
            return JSON(safe)
        }
        if let array = value.array { return JSON(array.map(sanitize)) }
        return scalars.contains(value.rawString() ?? "") ? JSON("(sensitive value)") : value
    }
    var result = source
    for index in result["resource_changes"].arrayValue.indices {
        for field in ["address", "previous_address"] {
            if let text = source["resource_changes"][index][field].string {
                result["resource_changes"][index][field] = JSON(safeText(text))
            }
        }
        let paths = source["resource_changes"][index]["change"]["replace_paths"]
        if let paths = paths.array {
            result["resource_changes"][index]["change"]["replace_paths"] = JSON(paths.map { path in
                JSON(path.arrayValue.map { component in
                    component.string.map { JSON(safeText($0)) } ?? component
                })
            })
        }
        if let importingID = source["resource_changes"][index]["change"]["importing"]["id"].string {
            result["resource_changes"][index]["change"]["importing"]["id"] = JSON(safeText(importingID))
        }
        for field in ["before", "after"] {
            result["resource_changes"][index]["change"][field] = sanitize(source["resource_changes"][index]["change"][field])
        }
    }
    for name in result["output_changes"].dictionaryValue.keys {
        for field in ["before", "after"] {
            result["output_changes"][name][field] = sanitize(source["output_changes"][name][field])
        }
    }
    return result
}

private func transformPlanOutputChange(name: String, change: JSON) -> PlanOutputChange {
    let actions = change["actions"].arrayValue.compactMap(\.string)
    let action = actions.isEmpty ? "no-op" : actions.joined(separator: " → ")
    return PlanOutputChange(
        name: name,
        action: action,
        attributes: flattenPlanAttributes(
            before: change["before"], after: change["after"],
            beforeSensitive: change["before_sensitive"], afterSensitive: change["after_sensitive"],
            afterUnknown: change["after_unknown"]
        )
    )
}

func parseTerraformPlan(_ output: String) -> TerraformPlan? {
    guard let data = output.data(using: .utf8), let json = try? JSON(data: data),
          json.type == .dictionary, let formatVersion = json["format_version"].string,
          supportsTerraformJSONMajor(formatVersion, supported: [1]) else { return nil }
    if let resourceChanges = json.dictionaryObject?["resource_changes"] {
        guard JSON(resourceChanges).type == .array else { return nil }
    } else {
        // Terraform omits resource_changes for output-only plans. A planned_values
        // object is required to distinguish that valid empty resource plan from
        // incomplete `show -json` output.
        guard json["planned_values"].type == .dictionary else { return nil }
    }
    return transformPlan(json)
}

func supportsTerraformJSONMajor(_ version: String, supported: Set<Int>) -> Bool {
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2,
          components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
          let major = components.first.flatMap({ Int($0) }) else { return false }
    return supported.contains(major)
}

private func transformPlanResourceChange(_ resourceChange: JSON) -> PlanResourceChange {
    let change = resourceChange["change"]
    let actions = change["actions"].arrayValue.compactMap(\.string)
    let action = Set(actions) == Set(["create", "delete"]) ? "replace" : actions.joined(separator: " → ")
    let attributes = flattenPlanAttributes(
        before: change["before"], after: change["after"],
        beforeSensitive: change["before_sensitive"], afterSensitive: change["after_sensitive"],
        afterUnknown: change["after_unknown"]
    )
    return PlanResourceChange(
        address: resourceChange["address"].stringValue,
        action: action.isEmpty ? "no-op" : action,
        attributes: attributes,
        replacementPaths: change["replace_paths"].arrayValue.map(planPath),
        actionOrder: actions,
        originalAddress: resourceChange["previous_address"].string,
        importingID: change["importing"]["id"].string
    )
}

private func planPath(_ path: JSON) -> String {
    path.arrayValue.reduce("$") { result, component in
        if let string = component.string { return "\(result)[\(quotedPlanKey(string))]" }
        if let number = component.int { return "\(result)[\(number)]" }
        return "\(result)[\(component.rawString() ?? "?")]"
    }
}

private func quotedPlanKey(_ key: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"?\"" }
    return encoded
}

private func flattenPlanAttributes(before: JSON, after: JSON, beforeSensitive: JSON,
                                   afterSensitive: JSON, afterUnknown: JSON) -> [PlanAttributeChange] {
    var changes: [PlanAttributeChange] = []

    func value(_ json: JSON, sensitive: JSON, unknown: JSON, present: Bool) -> PlanReviewedValue {
        if sensitive.bool == true { return .sensitive }
        if unknown.bool == true { return .unknown }
        if json.type == .null { return present ? .value("null") : .absent }
        return .value(json.rawString([.castNilToNSNull: true]) ?? "null")
    }

    func walk(_ path: String, _ before: JSON, _ after: JSON, _ beforeSensitive: JSON,
              _ afterSensitive: JSON, _ afterUnknown: JSON,
              beforePresent: Bool, afterPresent: Bool) {
        if beforeSensitive.bool == true || afterSensitive.bool == true || afterUnknown.bool == true {
            let beforeValue = value(before, sensitive: beforeSensitive, unknown: JSON.null, present: beforePresent)
            let afterValue = value(after, sensitive: afterSensitive, unknown: afterUnknown, present: afterPresent)
            changes.append(PlanAttributeChange(path: path, before: beforeValue, after: afterValue))
            return
        }

        let beforeObject = before.dictionary
        let afterObject = after.dictionary
        let beforeSensitiveObject = beforeSensitive.dictionary
        let afterSensitiveObject = afterSensitive.dictionary
        let afterUnknownObject = afterUnknown.dictionary
        if (beforeObject != nil) != (afterObject != nil), before.type != .null && after.type != .null {
            changes.append(PlanAttributeChange(
                path: path,
                before: structuredValue(before, sensitive: beforeSensitive, unknown: JSON.null),
                after: structuredValue(after, sensitive: afterSensitive, unknown: afterUnknown)
            ))
            return
        }
        if beforeObject != nil || afterObject != nil {
            let keys = Set((beforeObject ?? [:]).keys)
                .union((afterObject ?? [:]).keys)
                .union((beforeSensitiveObject ?? [:]).keys)
                .union((afterSensitiveObject ?? [:]).keys)
                .union((afterUnknownObject ?? [:]).keys)
                .sorted()
            if keys.isEmpty {
                changes.append(PlanAttributeChange(
                    path: path,
                    before: value(before, sensitive: beforeSensitive, unknown: JSON.null, present: beforePresent),
                    after: value(after, sensitive: afterSensitive, unknown: afterUnknown, present: afterPresent)
                ))
            }
            for key in keys {
                let childPath = "\(path)[\(quotedPlanKey(key))]"
                walk(childPath, beforeObject?[key] ?? JSON.null, afterObject?[key] ?? JSON.null,
                     beforeSensitive[key], afterSensitive[key], afterUnknown[key],
                     beforePresent: beforeObject?.keys.contains(key) == true,
                     afterPresent: afterObject?.keys.contains(key) == true)
            }
            return
        }

        let beforeArray = before.array
        let afterArray = after.array
        let beforeSensitiveArray = beforeSensitive.array
        let afterSensitiveArray = afterSensitive.array
        let afterUnknownArray = afterUnknown.array
        if beforeArray != nil || afterArray != nil {
            if (beforeArray != nil) != (afterArray != nil), before.type != .null && after.type != .null {
                changes.append(PlanAttributeChange(
                    path: path,
                    before: structuredValue(before, sensitive: beforeSensitive, unknown: JSON.null),
                    after: structuredValue(after, sensitive: afterSensitive, unknown: afterUnknown)
                ))
                return
            }
            let count = [beforeArray?.count ?? 0, afterArray?.count ?? 0,
                         beforeSensitiveArray?.count ?? 0, afterSensitiveArray?.count ?? 0,
                         afterUnknownArray?.count ?? 0].max() ?? 0
            if count == 0 {
                changes.append(PlanAttributeChange(
                    path: path,
                    before: value(before, sensitive: beforeSensitive, unknown: JSON.null, present: beforePresent),
                    after: value(after, sensitive: afterSensitive, unknown: afterUnknown, present: afterPresent)
                ))
            }
            for index in 0..<count {
                let childPath = "\(path)[\(index)]"
                walk(childPath, beforeArray?[safe: index] ?? JSON.null, afterArray?[safe: index] ?? JSON.null,
                     beforeSensitive[index], afterSensitive[index], afterUnknown[index],
                     beforePresent: beforeArray?.indices.contains(index) == true,
                     afterPresent: afterArray?.indices.contains(index) == true)
            }
            return
        }

        let beforeValue = value(before, sensitive: beforeSensitive, unknown: JSON.null, present: beforePresent)
        let afterValue = value(after, sensitive: afterSensitive, unknown: afterUnknown, present: afterPresent)
        if beforeValue != afterValue || beforeSensitive.bool == true || afterSensitive.bool == true || afterUnknown.bool == true {
            changes.append(PlanAttributeChange(path: path, before: beforeValue, after: afterValue))
        }
    }

    walk("$", before, after, beforeSensitive, afterSensitive, afterUnknown,
         beforePresent: before.type != .null, afterPresent: after.type != .null)
    return changes
}

private func structuredValue(_ json: JSON, sensitive: JSON, unknown: JSON) -> PlanReviewedValue {
    if sensitive.bool == true { return .sensitive }
    if unknown.bool == true { return .unknown }
    if json.type == .null { return .absent }
    guard let data = try? JSONSerialization.data(withJSONObject: redactedPlanObject(json, sensitive: sensitive, unknown: unknown),
                                                options: [.fragmentsAllowed, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        return .value("(value unavailable)")
    }
    return .value(string)
}

private func redactedPlanObject(_ json: JSON, sensitive: JSON, unknown: JSON) -> Any {
    if sensitive.bool == true { return "(sensitive value)" }
    if unknown.bool == true { return "(known after apply)" }
    if let object = json.dictionary {
        return Dictionary(uniqueKeysWithValues: object.map { key, child in
            (key, redactedPlanObject(child, sensitive: sensitive[key], unknown: unknown[key]))
        })
    }
    if let array = json.array {
        return array.enumerated().map { index, child in
            redactedPlanObject(child, sensitive: sensitive[index], unknown: unknown[index])
        }
    }
    return json.object
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
