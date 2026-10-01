//
//  ndjson.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/9/21.
//

import SwiftyJSON

func parseNDJsonOutput(_ output: String) -> [JSON] {
    var out: [JSON] = []
    for line in output.split(whereSeparator: \.isNewline) {
        if let dataFromString = line.data(using: .utf8, allowLossyConversion: false) {
            do {
                let json = try JSON(data: dataFromString)
                out.append(json)
            } catch {
                print("JSON parse error:", error)
                let json = JSON([
                    "type": "log",
                    "@message": line.trimmingCharacters(in: .whitespacesAndNewlines),
                ])
                out.append(json)
            }
        }
    }
    return out
}

@MainActor
func handleNDJsonSuccess(_ output: String) -> StructuredLog {
    let newLogs = StructuredLog()

    let json = parseNDJsonOutput(output)
    for line in json {
        guard let mType = line["type"].string, let type = MessageTypes(rawValue: mType) else {
            // no type, just log it
            newLogs.logs.append(transformLog(line))
            continue
        }

        if isResourceMessage(line) {
            if type == .PlannedChange {
                // doesn't exist yet
                let change = transformPlannedChange(line)
                newLogs.resources.append(ResourceState(change.change))
            } else {
                // already exists
                guard let hook = transformHook(line) else { continue }
                if let existing = newLogs.resources.first(where: { $0.address == hook.address }) {
                    existing.update(hook)
                } else {
                    let resource = ResourceState(PlannedChangeSummary(address: hook.address, resource: hook.resource, action: hook.action))
                    resource.update(hook)
                    newLogs.resources.append(resource)
                }
            }
            continue
        }

        switch type {
        case MessageTypes.Version:
            newLogs.versions.append(transformVersion(line))
        case MessageTypes.Log:
            newLogs.logs.append(transformLog(line))
        case MessageTypes.ChangeSummary:
            newLogs.changeSummaries.append(transformChangeSummary(line))
        case MessageTypes.Diagnostic:
            newLogs.diagnostics.append(transformDiagnostic(line))
        case MessageTypes.Outputs:
            newLogs.outputs.append(transformOutputs(line))
        default:
            newLogs.logs.append(transformLog(line))
        }
    }

    return newLogs
}


func parseJsonOutput(_ output: String) -> JSON {
    if let dataFromString = output.data(using: .utf8, allowLossyConversion: false) {
        do {
            return try JSON(data: dataFromString)
        } catch {
            print("JSON parse error:", error)
            return JSON([
                "type": "log",
                "@message": output.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }
    return JSON([
        "type": "log",
        "@message": output.trimmingCharacters(in: .whitespacesAndNewlines),
    ])
}
