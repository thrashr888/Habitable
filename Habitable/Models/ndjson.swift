//
//  ndjson.swift
//  Habitable
//

import Foundation
import SwiftyJSON

private func parseNDJsonLine(_ data: Data) -> JSON {
    if let json = try? JSON(data: data) { return json }
    let message = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return JSON(["type": "log", "@message": message])
}

func parseNDJsonOutput(_ output: String) -> [JSON] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return parseNDJsonLine(data)
    }
}

/// Frames JSON Lines even when a producer divides records across callbacks.
/// Incomplete lines are capped to avoid retaining a malformed unbounded event.
@MainActor
final class NDJSONStreamDecoder {
    private var pending = Data()
    private var discardingOversizedLine = false
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 64 * 1024) { self.maximumLineBytes = maximumLineBytes }

    func append(_ chunk: String) -> [JSON] {
        var events: [JSON] = []
        for byte in chunk.utf8 {
            if byte == 0x0A {
                if discardingOversizedLine {
                    events.append(JSON(["type": "log", "@message": "[Terraform output line omitted: line exceeded 64 KiB]"]))
                    discardingOversizedLine = false
                    pending.removeAll(keepingCapacity: true)
                } else if !pending.isEmpty {
                    pending.append(byte)
                    events.append(parseNDJsonLine(pending))
                    pending.removeAll(keepingCapacity: true)
                }
            } else if !discardingOversizedLine {
                pending.append(byte)
                if pending.count > maximumLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                }
            }
        }
        return events
    }

    func finish() -> [JSON] {
        defer { pending.removeAll(keepingCapacity: true); discardingOversizedLine = false }
        guard !discardingOversizedLine, !pending.isEmpty else { return [] }
        return [parseNDJsonLine(pending)]
    }
}

@MainActor
func handleNDJsonSuccess(_ output: String) -> StructuredLog {
    let result = StructuredLog()
    parseNDJsonOutput(output).forEach { consumeTerraformEvent($0, into: result) }
    result.isComplete = true
    return result
}

@MainActor
func consumeTerraformEvent(_ line: JSON, into log: StructuredLog) {
    guard let mType = line["type"].string, let type = MessageTypes(rawValue: mType) else {
        log.appendLog(transformLog(line))
        return
    }

    if isResourceMessage(line) {
        if [.RefreshStart, .RefreshComplete, .ProvisionStart, .ProvisionProgress,
            .ProvisionComplete, .ProvisionErrored].contains(type) {
            log.appendLog(transformLog(line))
            return
        }
        if type == .PlannedChange {
            let change = transformPlannedChange(line)
            if let existing = log.resources.first(where: { $0.address == change.change.address }) {
                existing.objectWillChange.send()
                existing.resource = change.change.resource
                existing.action = change.change.action
                existing.targetState = actionToState[change.change.action] ?? .NoOp
                log.objectWillChange.send()
            } else {
                log.appendResource(ResourceState(change.change))
            }
        } else if let hook = transformHook(line) {
            if let existing = log.resources.first(where: { $0.address == hook.address }) {
                if hook.type == .ApplyStart, existing.stages.count >= 8 {
                    existing.stages.removeFirst(existing.stages.count - 7)
                }
                existing.update(hook)
                log.objectWillChange.send()
            } else {
                let resource = ResourceState(PlannedChangeSummary(address: hook.address, resource: hook.resource, action: hook.action))
                resource.update(hook)
                log.appendResource(resource)
            }
        } else {
            log.appendLog(transformLog(line))
        }
        return
    }

    switch type {
    case .Version: log.appendVersion(transformVersion(line))
    case .Log: log.appendLog(transformLog(line))
    case .ChangeSummary: log.appendSummary(transformChangeSummary(line))
    case .Diagnostic: log.appendDiagnostic(transformDiagnostic(line))
    case .Outputs: log.appendOutputs(transformOutputs(line))
    default: log.appendLog(transformLog(line))
    }
}

func parseJsonOutput(_ output: String) -> JSON {
    guard let data = output.data(using: .utf8) else {
        return JSON(["type": "log", "@message": output.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
    return (try? JSON(data: data)) ?? JSON(["type": "log", "@message": output.trimmingCharacters(in: .whitespacesAndNewlines)])
}
