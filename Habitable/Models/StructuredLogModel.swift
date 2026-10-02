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
    let attributes: [PlanAttributeChange]
    let replacementPaths: [String]

    var id: String { address }
    var isReplacement: Bool { action == "replace" }
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
}

func transformPlan(_ log: JSON) -> TerraformPlan {
    TerraformPlan(
        resourceChanges: log["resource_changes"].arrayValue.map(transformPlanResourceChange),
        outputChanges: log["output_changes"].dictionaryValue.keys.sorted().map { name in
            transformPlanOutputChange(name: name, change: log["output_changes"][name])
        }
    )
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
          json.type == .dictionary, json["format_version"].string != nil else { return nil }
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
        replacementPaths: change["replace_paths"].arrayValue.map(planPath)
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
