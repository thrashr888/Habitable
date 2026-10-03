import Combine
import CoreFoundation
import Foundation
import SwiftyJSON

/// Captures app-marked inputs at the start of a run and removes their literal
/// representations from every user-visible or persisted Terraform result.
/// The snapshot is immutable so edits made while a command is running cannot
/// change which values are protected.
@MainActor
struct SensitiveInputRedactor {
    private let literals: [(value: String, replacement: String)]
    private let numbers: Set<String>
    private let booleans: Set<Bool>
    private let numberTokens: Set<String>
    private let booleanTokens: Set<String>

    init(variables: [TerraformVariable], environmentVariables: [EnvironmentVariable]) {
        var values: [String] = []
        var numbers: Set<String> = []
        var booleans: Set<Bool> = []
        for variable in variables where variable.isUserInput && variable.sensitive {
            Self.collect(variable.value, structured: variable.hcl, strings: &values,
                         numbers: &numbers, booleans: &booleans)
        }
        for variable in environmentVariables where variable.isUserInput && variable.sensitive {
            values.append(variable.value)
        }
        let valuesAndLineFragments = values.flatMap { value in
            [value] + value.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        self.literals = Array(Set(valuesAndLineFragments.filter { !$0.isEmpty })).map { value in
            (value, "(sensitive)")
        }.sorted { $0.value.count > $1.value.count }
        self.numbers = numbers
        self.booleans = booleans
        self.numberTokens = numbers
        self.booleanTokens = Set(booleans.map { $0 ? "true" : "false" })
    }

    func redact(_ text: String) -> String {
        let outputSafe = RunHistoryStore.redactSensitiveOutputs(text) ?? text
        return outputSafe.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let source = String(line)
            if let data = source.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let sanitized = sanitizeJSON(json, inPayload: false),
               let encoded = try? JSONSerialization.data(withJSONObject: sanitized,
                                                          options: [.sortedKeys, .fragmentsAllowed]),
               let result = String(data: encoded, encoding: .utf8) {
                return result
            }
            return redactScalarTokens(redactLiterals(source))
        }.joined(separator: "\n")
    }

    private func redactLiterals(_ text: String) -> String {
        literals.reduce(text) { result, literal in
            result.replacingOccurrences(of: literal.value, with: literal.replacement)
        }
    }

    func redact(_ text: String?) -> String? {
        text.map(redact)
    }

    private func sanitizeJSON(_ value: Any, inPayload: Bool) -> Any? {
        if let string = value as? String {
            let sanitized = redactLiterals(string)
            return inPayload ? redactScalarTokens(sanitized) : sanitized
        }
        if let object = value as? [String: Any] {
            let metadataKeys: Set<String> = [
                "type", "changes", "add", "change", "remove", "operation", "address", "actions",
                "format_version", "terraform_version", "sensitive", "before_sensitive", "after_sensitive",
                "after_unknown", "resource_changes", "filename", "range", "start", "end", "line",
                "column", "byte", "severity"
            ]
            var sanitized: [String: Any] = [:]
            for (key, value) in object {
                let safeKey = redactLiterals(key)
                let payloadKey = ["value", "before", "after", "input", "output", "detail", "code", "context", "message", "@message"].contains(key)
                let childIsMetadata = metadataKeys.contains(key)
                sanitized[safeKey] = sanitizeJSON(value, inPayload: !childIsMetadata && (inPayload || !metadataKeys.contains(key) || payloadKey)) ?? value
            }
            return sanitized
        }
        if let array = value as? [Any] { return array.map { sanitizeJSON($0, inPayload: inPayload) ?? $0 } }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                let boolean = number.boolValue
                return inPayload && booleans.contains(boolean) ? "(sensitive)" : number
            }
            return inPayload && numbers.contains(number.stringValue) ? "(sensitive)" : number
        }
        return value
    }

    private func redactScalarTokens(_ text: String) -> String {
        let tokens = numberTokens.union(booleanTokens).sorted { $0.count > $1.count }
        return tokens.reduce(text) { result, token in
            guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])\(NSRegularExpression.escapedPattern(for: token))(?![A-Za-z0-9_.])") else {
                return result
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "(sensitive)")
        }
    }

    private static func collect(_ value: String, structured: Bool, strings: inout [String],
                                numbers: inout Set<String>, booleans: inout Set<Bool>) {
        guard structured, let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            strings.append(value)
            return
        }

        strings.append(value)
        func collect(_ value: Any) {
            if let string = value as? String {
                strings.append(string)
            } else if let object = value as? [String: Any] {
                object.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    booleans.insert(number.boolValue)
                } else {
                    numbers.insert(number.stringValue)
                }
            }
        }
        collect(json)
    }
}

enum RunStatus: String, Codable, Sendable {
    case pending = "PENDING", planning = "PLANNING", planned = "PLANNED"
    case confirmed = "CONFIRMED", applying = "APPLYING", applied = "APPLIED"
    case discarded = "DISCARDED", errored = "ERRORED", canceled = "CANCELED"
    case expired = "EXPIRED", interrupted = "INTERRUPTED"
}

@MainActor
class TerraformRun: ObservableObject, Identifiable {
    nonisolated let id: UUID
    var number = 0
    private weak var workspace: Workspace?
    var createdAt = Date()
    var message: String?
    var terraformVersion = "Unknown"
    private(set) var isRestored = false
    private var stored = false
    private var workspaceDirectory: URL?
    private var planOutput: String?
    private var applyOutput: String?
    private var planHistoryOutput: String?
    private var planHistoryOutputTruncated = false
    private var planHistoryVersionEvent: String?
    private var applyHistoryOutput: String?
    private var applyHistoryOutputTruncated = false
    private var applyHistoryVersionEvent: String?
    private static let historyTailLimit = 256 * 1024
    private var updatedAt = Date()
    private var planGeneration: Int64?
    private var planExecutionContext: String?
    private var selectedTerraformWorkspace = "default"
    private var backendIdentity = "unknown backend"
    private var sensitiveInputRedactor = SensitiveInputRedactor(variables: [], environmentVariables: [])

    @Published var status: RunStatus = .pending
    @Published private var activeCommand: TerraformCommandHandle?
    @Published private(set) var isCanceling = false

    var isPersisted: Bool { stored }

    var canCancel: Bool { activeCommand != nil && [.planning, .applying].contains(status) }

    func cancel() {
        guard canCancel, !isCanceling else { return }
        isCanceling = true
        activeCommand?.cancel()
    }

    private func appendHistoryEvent(_ event: JSON, phase: RunStatus) {
        guard let line = event.rawString(options: [.sortedKeys]) else { return }
        if event["type"].string == "version" {
            if phase == .planning {
                planHistoryVersionEvent = line
                let (tail, didTrim) = trimmedHistoryTail(planHistoryOutput ?? "", version: line)
                planHistoryOutput = tail
                planHistoryOutputTruncated = planHistoryOutputTruncated || didTrim
            } else {
                applyHistoryVersionEvent = line
                let (tail, didTrim) = trimmedHistoryTail(applyHistoryOutput ?? "", version: line)
                applyHistoryOutput = tail
                applyHistoryOutputTruncated = applyHistoryOutputTruncated || didTrim
            }
            return
        }
        var output = phase == .planning ? (planHistoryOutput ?? "") : (applyHistoryOutput ?? "")
        var truncated = phase == .planning ? planHistoryOutputTruncated : applyHistoryOutputTruncated
        output.append(line); output.append("\n")
        let versionEvent = phase == .planning ? planHistoryVersionEvent : applyHistoryVersionEvent
        let (tail, didTrim) = trimmedHistoryTail(output, version: versionEvent)
        output = tail
        truncated = truncated || didTrim
        if phase == .planning {
            planHistoryOutput = output
            planHistoryOutputTruncated = truncated
        } else {
            applyHistoryOutput = output
            applyHistoryOutputTruncated = truncated
        }
    }

    private func trimmedHistoryTail(_ output: String, version: String?) -> (String, Bool) {
        let versionPrefix = version.map { $0 + "\n" } ?? ""
        let tailLimit = max(0, Self.historyTailLimit - versionPrefix.utf8.count)
        guard output.utf8.count > tailLimit else { return (output, false) }
        let excess = output.utf8.count - tailLimit
        let bytes = Array(output.utf8.dropFirst(excess))
        guard let newline = bytes.firstIndex(of: 0x0A) else { return ("", true) }
        return (String(decoding: bytes[(newline + 1)...], as: UTF8.self), true)
    }

    private func persistedHistoryOutput(tail: String?, version: String?) -> String? {
        guard let tail, !tail.isEmpty else { return nil }
        let prefix = version.map { $0 + "\n" } ?? ""
        return prefix + tail
    }

    private func appendOutput(_ text: String, stream: TerraformOutputStream,
                              decoder: NDJSONStreamDecoder, log: StructuredLog, phase: RunStatus) {
        let safe = sensitiveInputRedactor.redact(stripTerraformTerminalEscapes(text))
        guard stream == .stdout else {
            let current = textOutput ?? ""
            let stderr = "[stderr] " + safe
            textOutput = String((current + stderr).suffix(262_144))
            let event = JSON(["type": "log", "@message": stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
            appendHistoryEvent(event, phase: phase)
            consumeTerraformEvent(event, into: log)
            return
        }
        decoder.append(safe).forEach { event in
            appendHistoryEvent(event, phase: phase)
            appendLiveText(event)
            consumeTerraformEvent(event, into: log)
            updateChangeCounts(from: log)
        }
    }

    private func appendLiveText(_ event: JSON) {
        let visible = event["@message"].string ?? event.rawString() ?? ""
        guard !visible.isEmpty else { return }
        let current = textOutput ?? ""
        textOutput = String((current + visible + "\n").suffix(262_144))
    }

    private func finishLiveOutput(decoder: NDJSONStreamDecoder, log: StructuredLog, phase: RunStatus) {
        decoder.finish().forEach { event in
            appendHistoryEvent(event, phase: phase)
            appendLiveText(event)
            consumeTerraformEvent(event, into: log)
            updateChangeCounts(from: log)
        }
        log.isComplete = true
    }

    private func updateChangeCounts(from log: StructuredLog) {
        guard let changes = log.changeSummaries.last else { return }
        added = changes.changes.add
        changed = changes.changes.change
        destroyed = changes.changes.remove
    }

    private func finishCommand() {
        activeCommand = nil
        isCanceling = false
    }

    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var plan: StructuredLog?
    @Published var planDiff: TerraformPlan?
    @Published var apply: StructuredLog?
    @Published var added: Int?
    @Published var changed: Int?
    @Published var destroyed: Int?

    var historyNotice: String? {
        switch status {
        case .expired: return "This plan is from an earlier session. Queue a new plan before applying."
        case .interrupted: return "This run was recorded before its command finished. Its outcome is unknown; refresh state and review a new plan. It may still be running in another session."
        default:
            guard isRestored else { return nil }
            let truncated = planHistoryOutputTruncated || applyHistoryOutputTruncated
            return "Saved run history · Terraform \(terraformVersion)" + (truncated ? " · Earlier streamed events omitted" : "")
        }
    }

    var isFinished: Bool {
        [.applied, .errored, .discarded, .canceled, .expired, .interrupted].contains(status)
    }
    var canConfirm: Bool {
        !isRestored && status == .planned && apply == nil && workspace?.locked == false
            && workspace?.historyError == nil
            && !isUnchangedHCPPlan
    }
    var isUnchangedHCPPlan: Bool {
        guard usesHCPBackend, let planDiff else { return false }
        return planDiff.resourceChanges.allSatisfy { $0.action == "no-op" }
            && planDiff.outputChanges.allSatisfy { $0.action == "no-op" }
    }
    var canDiscard: Bool {
        !isRestored && status == .planned && apply == nil && workspace?.locked == false
    }
    var executionContextDescription: String {
        "Terraform workspace: \(selectedTerraformWorkspace) · Backend: \(backendIdentity)"
    }

    var usesHCPBackend: Bool {
        backendIdentity == "cloud" || backendIdentity.hasPrefix("cloud #")
            || backendIdentity == "remote" || backendIdentity.hasPrefix("remote #")
    }

    // Construction never launches a command: queueRun saves the initial record first.
    init(workspace: Workspace) {
        id = UUID()
        self.workspace = workspace
        workspaceDirectory = workspace.workingDirectory
        terraformVersion = workspace.terraformVersion
        selectedTerraformWorkspace = workspace.selectedTerraformWorkspace
        backendIdentity = workspace.backendIdentity
    }

    init(workspace: Workspace, record: RunRecord, restored: Bool) {
        id = record.id
        self.workspace = workspace
        number = record.number; createdAt = record.createdAt
        updatedAt = record.updatedAt; message = record.message
        terraformVersion = record.terraformVersion
        selectedTerraformWorkspace = record.selectedTerraformWorkspace ?? selectedTerraformWorkspace
        backendIdentity = record.backendIdentity ?? backendIdentity
        workspaceDirectory = URL(fileURLWithPath: record.workspacePath)
        status = record.status; errorMessage = record.errorMessage
        planOutput = record.planOutput; applyOutput = record.applyOutput
        planHistoryOutput = record.planHistoryOutput
        planHistoryOutputTruncated = record.planHistoryOutputTruncated ?? false
        applyHistoryOutput = record.applyHistoryOutput
        applyHistoryOutputTruncated = record.applyHistoryOutputTruncated ?? false
        plan = record.planHistoryOutput.map(handleNDJsonSuccess) ?? record.planOutput.map(handleNDJsonSuccess)
        apply = record.applyHistoryOutput.map(handleNDJsonSuccess) ?? record.applyOutput.map(handleNDJsonSuccess)
        added = record.added; changed = record.changed; destroyed = record.destroyed
        isRestored = restored; stored = true
        if restored {
            switch status {
            case .planned: status = .expired
            case .pending, .planning, .confirmed, .applying: status = .interrupted
            default: break
            }
        }
    }

    @discardableResult private func persist() -> Bool {
        guard stored, !isRestored, let workspace, let directory = workspaceDirectory else { return !stored }
        updatedAt = Date()
        let record = RunRecord(id: id, number: number, workspacePath: RunHistoryStore.workspacePath(directory),
                               createdAt: createdAt, updatedAt: updatedAt, status: status,
                               terraformVersion: terraformVersion,
                               selectedTerraformWorkspace: selectedTerraformWorkspace,
                               backendIdentity: backendIdentity, message: message,
                               planOutput: planOutput, applyOutput: applyOutput,
                               planHistoryOutput: persistedHistoryOutput(tail: planHistoryOutput, version: planHistoryVersionEvent),
                               planHistoryOutputTruncated: planHistoryOutputTruncated,
                               applyHistoryOutput: persistedHistoryOutput(tail: applyHistoryOutput, version: applyHistoryVersionEvent),
                               applyHistoryOutputTruncated: applyHistoryOutputTruncated,
                               errorMessage: errorMessage,
                               added: added, changed: changed, destroyed: destroyed)
        return workspace.persistRun(record, directory: directory)
    }

    private func redactOutput(_ output: String?) -> String? {
        RunHistoryStore.redactSensitiveOutputs(sensitiveInputRedactor.redact(output))
    }

    func doDiscard() {
        guard canDiscard, let workspace else { return }
        status = .discarded
        workspace.runner.discardPlan(runId: id.uuidString)
        persist()
    }

    func doPlan(_ completion: @escaping (StructuredLog?, String?) -> Void) {
        guard !isRestored, status == .pending, let workspace,
              !workspace.locked, let directory = workspaceDirectory,
              workspace.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
        let lease: WorkspaceCommandCoordinator.Lease
        do {
            lease = try workspace.acquireCommandLease()
        } catch {
            status = .errored
            errorMessage = error.localizedDescription
            persist()
            completion(nil, errorMessage)
            return
        }
        selectedTerraformWorkspace = workspace.selectedTerraformWorkspace
        backendIdentity = workspace.backendIdentity
        let variables = workspace.terraformVariables.filter(\.isUserInput)
        let environmentVariables = workspace.environmentVariables.filter(\.isUserInput)
        sensitiveInputRedactor = SensitiveInputRedactor(variables: variables,
                                                        environmentVariables: environmentVariables)
        status = .planning
        guard persist() else {
            status = .errored
            lease.release()
            completion(nil, workspace.historyError)
            return
        }
        workspace.lock(self)
        let runner = workspace.runner
        textOutput = ""
        planHistoryOutput = nil
        planHistoryOutputTruncated = false
        planHistoryVersionEvent = nil
        let liveLog = StructuredLog()
        let decoder = NDJSONStreamDecoder()
        plan = liveLog
        activeCommand = runner.plan(workingDirectory: directory, runId: id.uuidString,
                    variables: variables,
                    environmentVariables: environmentVariables,
                    onOutput: { [self] stream, text in appendOutput(text, stream: stream, decoder: decoder, log: liveLog, phase: .planning) }) { [self, workspace] output, error in
            finishLiveOutput(decoder: decoder, log: liveLog, phase: .planning)
            planOutput = redactOutput(output ?? error?.output)
            plan = error?.outputTruncated == true || error?.cancelled == true
                ? liveLog : planOutput.map(handleNDJsonSuccess)
            if error?.outputTruncated != true && error?.cancelled != true {
                planHistoryOutput = nil
                planHistoryOutputTruncated = false
                planHistoryVersionEvent = nil
            }
            guard error == nil else {
                workspace.unlock()
                lease.release()
                errorMessage = redactOutput(error?.message)
                finishCommand()
                status = error?.cancelled == true ? .canceled : .errored
                if error?.cancelled != true { workspace.isValid = false }
                runner.discardPlan(runId: id.uuidString)
                persist()
                completion(plan, errorMessage)
                return
            }
            if let schemaError = liveLog.schemaError {
                workspace.unlock()
                lease.release()
                errorMessage = sensitiveInputRedactor.redact(schemaError)
                finishCommand()
                status = .errored
                workspace.isValid = false
                runner.discardPlan(runId: id.uuidString)
                persist()
                completion(plan, errorMessage)
                return
            }
            // Review exactly the saved plan that apply will receive. A plan that cannot
            // be inspected is retired instead of becoming confirmable.
            activeCommand = runner.showPlan(workingDirectory: directory, runId: id.uuidString) { [self, workspace] showOutput, showError in
                finishCommand()
                workspace.unlock()
                if showError == nil, let showOutput = sensitiveInputRedactor.redact(showOutput),
                   let reviewedPlan = parseTerraformPlan(showOutput) {
                    planDiff = reviewedPlan
                    planGeneration = lease.generation
                    planExecutionContext = workspace.executionContextIdentifier
                    status = .planned
                    workspace.isValid = true
                } else {
                    let formatVersion = showOutput.flatMap { text -> String? in
                        guard let data = text.data(using: .utf8), let json = try? JSON(data: data) else { return nil }
                        return json["format_version"].string
                    }
                    if showError == nil, let formatVersion,
                       !supportsTerraformJSONMajor(formatVersion, supported: [1]) {
                        errorMessage = redactOutput("This saved plan uses unsupported Terraform JSON format version \(formatVersion). Habitable supports format version 1.x.")
                    } else {
                        errorMessage = redactOutput(showError?.message)
                            ?? "Terraform could not inspect the saved plan."
                    }
                    status = showError?.cancelled == true ? .canceled : .errored
                    if showError?.cancelled != true { workspace.isValid = false }
                    runner.discardPlan(runId: id.uuidString)
                }
                if let changes = plan?.changeSummaries.last {
                    added = changes.changes.add; changed = changes.changes.change; destroyed = changes.changes.remove
                }
                let saved = persist()
                lease.release()
                if saved, status == .planned, let plan { workspace.didPlan(run: self, plan: plan) }
                completion(plan, errorMessage)
            }
        }
    }

    func doApply(_ completion: @escaping (StructuredLog?, String?) -> Void) {
        guard canConfirm, let workspace, let directory = workspaceDirectory,
              workspace.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
        let lease: WorkspaceCommandCoordinator.Lease
        do {
            lease = try workspace.acquireCommandLease()
        } catch {
            errorMessage = error.localizedDescription
            completion(nil, errorMessage)
            return
        }
        guard planGeneration == lease.generation, planExecutionContext == workspace.executionContextIdentifier else {
            lease.release()
            status = .expired
            errorMessage = "The workspace changed after this plan was reviewed. Create a new plan before applying."
            workspace.runner.discardPlan(runId: id.uuidString)
            persist()
            completion(nil, errorMessage)
            return
        }
        status = .applying
        guard persist() else {
            status = .planned
            lease.release()
            completion(nil, workspace.historyError)
            return
        }
        workspace.lock(self)
        let runner = workspace.runner
        textOutput = ""
        applyHistoryOutput = nil
        applyHistoryOutputTruncated = false
        applyHistoryVersionEvent = nil
        let liveLog = StructuredLog()
        let decoder = NDJSONStreamDecoder()
        apply = liveLog
        activeCommand = runner.apply(workingDirectory: directory, runId: id.uuidString,
                                    onOutput: { [self] stream, text in appendOutput(text, stream: stream, decoder: decoder, log: liveLog, phase: .applying) }) { [self, workspace] output, error in
            finishLiveOutput(decoder: decoder, log: liveLog, phase: .applying)
            finishCommand()
            workspace.unlock()
            let coordinationError: String?
            do {
                try lease.invalidatePlans()
                coordinationError = nil
            } catch {
                coordinationError = "Terraform finished, but Habitable could not invalidate reviewed plans in other windows: \(error.localizedDescription)"
            }
            lease.release()
            applyOutput = redactOutput(output ?? error?.output)
            apply = error?.outputTruncated == true || error?.cancelled == true
                ? liveLog : applyOutput.map(handleNDJsonSuccess)
            if error?.outputTruncated != true && error?.cancelled != true {
                applyHistoryOutput = nil
                applyHistoryOutputTruncated = false
                applyHistoryVersionEvent = nil
            }
            errorMessage = redactOutput(coordinationError ?? error?.message)
            status = coordinationError != nil ? .errored : (error?.cancelled == true ? .canceled : (error == nil ? .applied : .errored))
            workspace.isValid = coordinationError == nil && error == nil
            if let changes = apply?.changeSummaries.last {
                added = changes.changes.add; changed = changes.changes.change; destroyed = changes.changes.remove
            }
            runner.discardPlan(runId: id.uuidString)
            persist()
            // Failed applies can partially change state too. Retire other plans and refresh.
            workspace.didApply(run: self, apply: apply ?? StructuredLog())
            completion(apply, errorMessage)
        }
    }
}

extension TerraformRun: Hashable {
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    nonisolated static func ==(lhs: TerraformRun, rhs: TerraformRun) -> Bool { lhs === rhs }
}
