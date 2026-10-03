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
        for variable in variables where variable.sensitive {
            Self.collect(variable.value, structured: variable.hcl, strings: &values,
                         numbers: &numbers, booleans: &booleans)
            if !variable.isUserInput, variable.discoveredSource == nil,
               let defaultJSON = variable.declaration?.defaultJSON,
               let defaultValue = String(data: defaultJSON, encoding: .utf8) {
                Self.collect(defaultValue, structured: true, strings: &values,
                             numbers: &numbers, booleans: &booleans)
            }
        }
        for variable in environmentVariables where variable.sensitive {
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

enum RunDisplayPhase: Int {
    case plan = 1, apply = 2, errors = 3

    static func current(status: RunStatus, hasApply: Bool, hasError: Bool) -> Self {
        if hasError { return .errors }
        if hasApply || status == .confirmed || status == .applying || status == .applied { return .apply }
        return .plan
    }
}

enum RunLogSection: Hashable { case version, summary, outputs, activity }

/// Reveal a live section once, without undoing a user's later collapse on each event.
struct LiveRunDisclosureState {
    private(set) var expanded: Set<RunLogSection> = []
    private var revealed: Set<RunLogSection> = []

    mutating func receive(_ available: Set<RunLogSection>, isLive: Bool) {
        guard isLive else { return }
        expanded.formUnion(available.subtracting(revealed))
        revealed.formUnion(available)
    }

    mutating func setExpanded(_ section: RunLogSection, _ value: Bool) {
        if value { expanded.insert(section) } else { expanded.remove(section) }
    }
}

@MainActor
class TerraformRun: ObservableObject, Identifiable {
    nonisolated let id: UUID
    var number = 0
    private weak var workspace: Workspace?
    var createdAt = Date()
    @Published private(set) var planStartedAt: Date?
    @Published private(set) var planFinishedAt: Date?
    @Published private(set) var applyStartedAt: Date?
    @Published private(set) var applyFinishedAt: Date?
    private(set) var gitBranch: String?
    private(set) var gitCommit: String?

    var planDuration: TimeInterval? {
        guard let start = planStartedAt, let finish = planFinishedAt, finish >= start else { return nil }
        return finish.timeIntervalSince(start)
    }
    var applyDuration: TimeInterval? {
        guard let start = applyStartedAt, let finish = applyFinishedAt, finish >= start else { return nil }
        return finish.timeIntervalSince(start)
    }
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
    private var planWorkspaceFingerprint: String?
    private var planInputsFingerprint: String?
    @Published private(set) var isCheckingContext = false
    private var contextVerificationTask: Task<Void, Never>?
    private var contextFingerprintTask: Task<String, Error>?
    private var selectedTerraformWorkspace = "default"
    private var backendIdentity = "unknown backend"
    private var sensitiveInputRedactor = SensitiveInputRedactor(variables: [], environmentVariables: [])

    @Published var status: RunStatus = .pending
    @Published private var activeCommand: TerraformCommandHandle?
    @Published private(set) var isCanceling = false

    var isPersisted: Bool { stored }

    var canCancel: Bool {
        (activeCommand != nil && [.planning, .applying].contains(status))
            || (isCheckingContext && [.planning, .planned].contains(status))
    }

    func cancel() {
        guard canCancel, !isCanceling else { return }
        isCanceling = true
        if isCheckingContext, activeCommand == nil {
            status = .canceled
            contextFingerprintTask?.cancel()
            contextVerificationTask?.cancel()
            return
        }
        activeCommand?.cancel()
    }

    private func appendHistoryEvent(_ event: JSON, phase: RunStatus) {
        guard let line = event.rawString(options: [.sortedKeys]) else { return }
        if event["@message"].string == "[Earlier live output omitted; consult the completed run events]" {
            if phase == .planning { planHistoryOutputTruncated = true }
            else { applyHistoryOutputTruncated = true }
        }
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
        case .expired: return isRestored
            ? "This plan is from an earlier session. Queue a new plan before applying."
            : "This plan is no longer valid. Create a new plan before applying."
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
        !isRestored && !isCheckingContext && status == .planned && apply == nil && workspace?.locked == false
            && workspace?.historyError == nil
            && workspace?.hasUnavailableRememberedInputs == false
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
        planStartedAt = record.planStartedAt; planFinishedAt = record.planFinishedAt
        applyStartedAt = record.applyStartedAt; applyFinishedAt = record.applyFinishedAt
        gitBranch = record.gitBranch; gitCommit = record.gitCommit
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
                               added: added, changed: changed, destroyed: destroyed,
                               planStartedAt: planStartedAt, planFinishedAt: planFinishedAt,
                               applyStartedAt: applyStartedAt, applyFinishedAt: applyFinishedAt,
                               gitBranch: gitBranch, gitCommit: gitCommit)
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
              !workspace.hasUnavailableRememberedInputs,
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
        sensitiveInputRedactor = SensitiveInputRedactor(variables: workspace.terraformVariables,
                                                        environmentVariables: workspace.environmentVariables)
        status = .planning
        guard persist() else {
            status = .errored
            lease.release()
            completion(nil, workspace.historyError)
            return
        }
        workspace.lock(self)
        let inputsFingerprint = WorkspaceContextFingerprint.inputsFingerprint(
            terraformVariables: variables, environmentVariables: environmentVariables
        )
        let context = WorkspaceContextCaptureContext(
            directory: directory, terraformWorkspace: selectedTerraformWorkspace,
            backendIdentity: backendIdentity, terraformVersion: terraformVersion,
            terraformExecutable: workspace.runner.executableURL, inputsFingerprint: inputsFingerprint
        )
        planWorkspaceFingerprint = nil
        planInputsFingerprint = inputsFingerprint
        isCheckingContext = true
        contextVerificationTask = Task { [self, workspace] in
            do {
                guard !Task.isCancelled, status == .planning else {
                    finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                let capture = WorkspaceContextFingerprint.captureOffMainActor(context)
                contextFingerprintTask = capture
                let fingerprint = try await capture.value
                contextFingerprintTask = nil
                guard !Task.isCancelled, status == .planning else {
                    finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                guard currentInputsFingerprint(in: workspace) == context.inputsFingerprint else {
                    failContextCheck(workspace: workspace, lease: lease, status: .errored,
                                     message: "Terraform variable inputs changed before planning started. Try planning again.",
                                     completion: completion)
                    return
                }
                isCheckingContext = false
                contextVerificationTask = nil
                launchPlan(variables: variables, environmentVariables: environmentVariables,
                           workspace: workspace, lease: lease, context: context,
                           fingerprint: fingerprint, completion: completion)
            } catch {
                if Task.isCancelled || status == .canceled {
                    finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                contextFingerprintTask = nil
                contextVerificationTask = nil
                isCheckingContext = false
                workspace.unlock()
                lease.release()
                finishCommand()
                status = .errored
                errorMessage = error.localizedDescription
                workspace.isValid = false
                workspace.runner.discardPlan(runId: id.uuidString)
                persist()
                completion(nil, errorMessage)
            }
        }
    }

    private func launchPlan(variables: [TerraformVariable], environmentVariables: [EnvironmentVariable],
                            workspace: Workspace, lease: WorkspaceCommandCoordinator.Lease,
                            context: WorkspaceContextCaptureContext, fingerprint: String,
                            completion: @escaping (StructuredLog?, String?) -> Void) {
        let runner = workspace.runner
        textOutput = ""
        planHistoryOutput = nil
        planHistoryOutputTruncated = false
        planHistoryVersionEvent = nil
        let liveLog = StructuredLog()
        let decoder = NDJSONStreamDecoder()
        plan = liveLog
        let git = RunGitContext.capture(directory: context.directory)
        gitBranch = git?.branch; gitCommit = git?.commit
        planStartedAt = Date()
        guard persist() else {
            planStartedAt = nil
            failContextCheck(workspace: workspace, lease: lease, status: .errored,
                             message: workspace.historyError ?? "Unable to save run start time.", completion: completion)
            return
        }
        activeCommand = runner.plan(workingDirectory: context.directory, runId: id.uuidString,
                    variables: variables,
                    environmentVariables: environmentVariables,
                    onOutput: { [self] stream, text in appendOutput(text, stream: stream, decoder: decoder, log: liveLog, phase: .planning) }) { [self, workspace] output, error in
            planFinishedAt = Date()
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
            if let schemaError = plan?.schemaError ?? liveLog.schemaError {
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
            finishCommand()
            isCheckingContext = true
            contextVerificationTask = Task { [self, workspace] in
                do {
                    guard !Task.isCancelled, status == .planning else {
                        finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion, result: plan)
                        return
                    }
                    let capture = WorkspaceContextFingerprint.captureOffMainActor(context)
                    contextFingerprintTask = capture
                    let currentFingerprint = try await capture.value
                    contextFingerprintTask = nil
                    guard !Task.isCancelled, status == .planning else {
                        finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion, result: plan)
                        return
                    }
                    guard currentInputsFingerprint(in: workspace) == context.inputsFingerprint else {
                        failContextCheck(workspace: workspace, lease: lease, status: .expired,
                                         message: "Terraform variable inputs changed while planning. Create a new plan before applying.",
                                         completion: completion, result: plan)
                        return
                    }
                    guard currentFingerprint == fingerprint else {
                        isCheckingContext = false
                        contextVerificationTask = nil
                        finishCommand()
                        workspace.unlock()
                        lease.release()
                        status = .expired
                        errorMessage = "Terraform configuration, variables, state, or workspace context changed while planning. Create a new plan before applying."
                        workspace.isValid = false
                        runner.discardPlan(runId: id.uuidString)
                        persist()
                        completion(plan, errorMessage)
                        return
                    }
                    isCheckingContext = false
                    contextVerificationTask = nil
                    reviewSavedPlan(runner: runner, workspace: workspace, lease: lease,
                                    context: context, fingerprint: fingerprint, completion: completion)
                } catch {
                    if Task.isCancelled || status == .canceled {
                        finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion, result: plan)
                        return
                    }
                    contextFingerprintTask = nil
                    contextVerificationTask = nil
                    isCheckingContext = false
                    finishCommand()
                    workspace.unlock()
                    lease.release()
                    status = .expired
                    errorMessage = error.localizedDescription
                    workspace.isValid = false
                    runner.discardPlan(runId: id.uuidString)
                    persist()
                    completion(plan, errorMessage)
                }
            }
        }
    }

    private func reviewSavedPlan(runner: Runner, workspace: Workspace,
                                 lease: WorkspaceCommandCoordinator.Lease,
                                 context: WorkspaceContextCaptureContext, fingerprint: String,
                                 completion: @escaping (StructuredLog?, String?) -> Void) {
        // Review exactly the saved plan that apply will receive. A plan that cannot
        // be inspected is retired instead of becoming confirmable.
        activeCommand = runner.showPlan(workingDirectory: context.directory, runId: id.uuidString) { [self, workspace] showOutput, showError in
            finishCommand()
            workspace.unlock()
            if showError == nil, let showOutput = sensitiveInputRedactor.redact(showOutput),
               let reviewedPlan = parseTerraformPlan(showOutput) {
                planDiff = reviewedPlan
                planGeneration = lease.generation
                planExecutionContext = workspace.executionContextIdentifier
                planWorkspaceFingerprint = fingerprint
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

    func doApply(_ completion: @escaping (StructuredLog?, String?) -> Void) {
        guard canConfirm, let workspace, let directory = workspaceDirectory,
              !workspace.hasUnavailableRememberedInputs,
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
        let variables = workspace.terraformVariables.filter(\.isUserInput)
        let environmentVariables = workspace.environmentVariables.filter(\.isUserInput)
        let inputsFingerprint = WorkspaceContextFingerprint.inputsFingerprint(
            terraformVariables: variables, environmentVariables: environmentVariables
        )
        let currentContext = WorkspaceContextCaptureContext(
            directory: directory, terraformWorkspace: workspace.selectedTerraformWorkspace,
            backendIdentity: workspace.backendIdentity, terraformVersion: terraformVersion,
            terraformExecutable: workspace.runner.executableURL, inputsFingerprint: inputsFingerprint
        )
        isCheckingContext = true
        workspace.lock(self)
        contextVerificationTask = Task { [self, workspace] in
            do {
                guard !Task.isCancelled, status == .planned else {
                    finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                let capture = WorkspaceContextFingerprint.captureOffMainActor(currentContext)
                contextFingerprintTask = capture
                let currentFingerprint = try await capture.value
                contextFingerprintTask = nil
                guard !Task.isCancelled, status == .planned else {
                    finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                guard currentFingerprint == planWorkspaceFingerprint,
                      inputsFingerprint == planInputsFingerprint,
                      currentInputsFingerprint(in: workspace) == inputsFingerprint,
                      planGeneration == lease.generation,
                      planExecutionContext == workspace.executionContextIdentifier else {
                    expirePlanForContextChange(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                isCheckingContext = false
                contextVerificationTask = nil
                startApply(directory: directory, workspace: workspace, lease: lease, completion: completion)
            } catch {
                if Task.isCancelled || status == .canceled {
                    finishCanceledContextCheck(workspace: workspace, lease: lease, completion: completion)
                    return
                }
                contextFingerprintTask = nil
                contextVerificationTask = nil
                isCheckingContext = false
                expirePlanForVerificationFailure(error, workspace: workspace, lease: lease, completion: completion)
            }
        }
    }

    private func finishCanceledContextCheck(workspace: Workspace, lease: WorkspaceCommandCoordinator.Lease,
                                            completion: @escaping (StructuredLog?, String?) -> Void,
                                            result: StructuredLog? = nil) {
        contextFingerprintTask?.cancel()
        contextFingerprintTask = nil
        contextVerificationTask = nil
        isCheckingContext = false
        finishCommand()
        workspace.unlock()
        lease.release()
        status = .canceled
        errorMessage = "Canceled before Terraform started the command."
        workspace.runner.discardPlan(runId: id.uuidString)
        persist()
        completion(result, errorMessage)
    }

    private func failContextCheck(workspace: Workspace, lease: WorkspaceCommandCoordinator.Lease,
                                  status: RunStatus, message: String,
                                  completion: @escaping (StructuredLog?, String?) -> Void,
                                  result: StructuredLog? = nil) {
        contextFingerprintTask?.cancel()
        contextFingerprintTask = nil
        contextVerificationTask = nil
        isCheckingContext = false
        workspace.unlock()
        lease.release()
        self.status = status
        errorMessage = message
        workspace.isValid = false
        workspace.runner.discardPlan(runId: id.uuidString)
        persist()
        completion(result, errorMessage)
    }

    private func currentInputsFingerprint(in workspace: Workspace) -> String {
        WorkspaceContextFingerprint.inputsFingerprint(
            terraformVariables: workspace.terraformVariables,
            environmentVariables: workspace.environmentVariables
        )
    }

    private func expirePlanForContextChange(workspace: Workspace, lease: WorkspaceCommandCoordinator.Lease,
                                            completion: @escaping (StructuredLog?, String?) -> Void) {
        isCheckingContext = false
        workspace.unlock()
        lease.release()
        status = .expired
        errorMessage = "Terraform configuration, variables, local state, or workspace context changed after this plan was reviewed. Create a new plan before applying."
        workspace.isValid = false
        workspace.runner.discardPlan(runId: id.uuidString)
        persist()
        completion(nil, errorMessage)
    }

    private func expirePlanForVerificationFailure(_ error: Error, workspace: Workspace,
                                                  lease: WorkspaceCommandCoordinator.Lease,
                                                  completion: @escaping (StructuredLog?, String?) -> Void) {
        isCheckingContext = false
        workspace.unlock()
        lease.release()
        status = .expired
        errorMessage = error.localizedDescription
        workspace.isValid = false
        workspace.runner.discardPlan(runId: id.uuidString)
        persist()
        completion(nil, errorMessage)
    }

    private func startApply(directory: URL, workspace: Workspace,
                            lease: WorkspaceCommandCoordinator.Lease,
                            completion: @escaping (StructuredLog?, String?) -> Void) {
        status = .applying
        applyStartedAt = Date()
        guard persist() else {
            applyStartedAt = nil
            status = .planned
            workspace.unlock()
            lease.release()
            completion(nil, workspace.historyError)
            return
        }
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
            applyFinishedAt = Date()
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
