//
//  StructuredLogModel.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/5/21.
//

import Combine
import Foundation
import SwiftyJSON

class StructuredLog: ObservableObject {
    var id = UUID()
    var logs: [LogMessage] = []
    var changeSummaries: [ChangeSummaryMessage] = []
    var versions: [VersionMessage] = []
    var diagnostics: [DiagnosticMessage] = []
    var resources: [ResourceState] = []
    var outputs: [OutputsMessage] = []
    var createdAt = Date()
}

enum PlanReviewedValue: Equatable {
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

struct PlanAttributeChange: Identifiable, Equatable {
    let path: String
    let before: PlanReviewedValue
    let after: PlanReviewedValue

    var id: String { path }
}

struct PlanResourceChange: Identifiable, Equatable {
    let address: String
    let action: String
    let attributes: [PlanAttributeChange]
    let replacementPaths: [String]

    var id: String { address }
    var isReplacement: Bool { action == "replace" }
}

struct TerraformPlan: Equatable {
    let resourceChanges: [PlanResourceChange]
}

func transformPlan(_ log: JSON) -> TerraformPlan {
    TerraformPlan(resourceChanges: log["resource_changes"].arrayValue.map(transformPlanResourceChange))
}

func parseTerraformPlan(_ output: String) -> TerraformPlan? {
    guard let data = output.data(using: .utf8), let json = try? JSON(data: data),
          json.type == .dictionary, json["format_version"].string != nil,
          json["resource_changes"].type == .array else { return nil }
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
    path.arrayValue.enumerated().map { index, component in
        if let string = component.string { return index == 0 ? string : ".\(string)" }
        if let number = component.int { return "[\(number)]" }
        return "[\(component.rawString() ?? "?")]"
    }.joined()
}

private func flattenPlanAttributes(before: JSON, after: JSON, beforeSensitive: JSON,
                                   afterSensitive: JSON, afterUnknown: JSON) -> [PlanAttributeChange] {
    var changes: [PlanAttributeChange] = []

    func value(_ json: JSON, sensitive: JSON, unknown: JSON) -> PlanReviewedValue {
        if sensitive.bool == true { return .sensitive }
        if unknown.bool == true { return .unknown }
        if json.type == .null { return .absent }
        return .value(json.rawString([.castNilToNSNull: true]) ?? "null")
    }

    func walk(_ path: String, _ before: JSON, _ after: JSON, _ beforeSensitive: JSON,
              _ afterSensitive: JSON, _ afterUnknown: JSON) {
        if beforeSensitive.bool == true || afterSensitive.bool == true || afterUnknown.bool == true {
            let beforeValue = value(before, sensitive: beforeSensitive, unknown: JSON.null)
            let afterValue = value(after, sensitive: afterSensitive, unknown: afterUnknown)
            changes.append(PlanAttributeChange(path: path, before: beforeValue, after: afterValue))
            return
        }

        let beforeObject = before.dictionary
        let afterObject = after.dictionary
        if beforeObject != nil || afterObject != nil {
            let keys = Set((beforeObject ?? [:]).keys).union((afterObject ?? [:]).keys).sorted()
            for key in keys {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                walk(childPath, beforeObject?[key] ?? JSON.null, afterObject?[key] ?? JSON.null,
                     beforeSensitive[key], afterSensitive[key], afterUnknown[key])
            }
            return
        }

        let beforeArray = before.array
        let afterArray = after.array
        if beforeArray != nil || afterArray != nil {
            let count = max(beforeArray?.count ?? 0, afterArray?.count ?? 0)
            for index in 0..<count {
                let childPath = "\(path)[\(index)]"
                walk(childPath, beforeArray?[safe: index] ?? JSON.null, afterArray?[safe: index] ?? JSON.null,
                     beforeSensitive[index], afterSensitive[index], afterUnknown[index])
            }
            return
        }

        let beforeValue = value(before, sensitive: beforeSensitive, unknown: JSON.null)
        let afterValue = value(after, sensitive: afterSensitive, unknown: afterUnknown)
        if beforeValue != afterValue || beforeSensitive.bool == true || afterSensitive.bool == true || afterUnknown.bool == true {
            changes.append(PlanAttributeChange(path: path, before: beforeValue, after: afterValue))
        }
    }

    walk("", before, after, beforeSensitive, afterSensitive, afterUnknown)
    return changes
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
