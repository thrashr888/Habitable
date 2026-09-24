import Combine
import Foundation

enum RunStatus: String, Codable {
    case pending = "PENDING", planning = "PLANNING", planned = "PLANNED"
    case confirmed = "CONFIRMED", applying = "APPLYING", applied = "APPLIED"
    case discarded = "DISCARDED", errored = "ERRORED", canceled = "CANCELED"
    case expired = "EXPIRED", interrupted = "INTERRUPTED"
}

class TerraformRun: ObservableObject, Identifiable {
    var id = UUID()
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
    private var updatedAt = Date()

    @Published var status: RunStatus = .pending
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var plan: StructuredLog?
    @Published var apply: StructuredLog?
    @Published var added: Int?
    @Published var changed: Int?
    @Published var destroyed: Int?

    var historyNotice: String? {
        switch status {
        case .expired: return "This plan is from an earlier session. Queue a new plan before applying."
        case .interrupted: return "This run was recorded before its command finished. Its outcome is unknown; refresh state and review a new plan. It may still be running in another session."
        default: return isRestored ? "Saved run history · Terraform \(terraformVersion)" : nil
        }
    }

    var isFinished: Bool {
        [.applied, .errored, .discarded, .canceled, .expired, .interrupted].contains(status)
    }
    var canConfirm: Bool {
        !isRestored && status == .planned && apply == nil && workspace?.locked == false
            && workspace?.historyError == nil
    }
    var canDiscard: Bool {
        !isRestored && status == .planned && apply == nil && workspace?.locked == false
    }

    // Construction never launches a command: queueRun saves the initial record first.
    init(workspace: Workspace) {
        self.workspace = workspace
        workspaceDirectory = workspace.workingDirectory
        terraformVersion = workspace.terraformVersion
    }

    init(workspace: Workspace, record: RunRecord, restored: Bool) {
        self.workspace = workspace
        id = record.id; number = record.number; createdAt = record.createdAt
        updatedAt = record.updatedAt; message = record.message
        terraformVersion = record.terraformVersion
        workspaceDirectory = URL(fileURLWithPath: record.workspacePath)
        status = record.status; errorMessage = record.errorMessage
        planOutput = record.planOutput; applyOutput = record.applyOutput
        plan = record.planOutput.map(handleNDJsonSuccess)
        apply = record.applyOutput.map(handleNDJsonSuccess)
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
                               terraformVersion: terraformVersion, message: message,
                               planOutput: planOutput, applyOutput: applyOutput, errorMessage: errorMessage,
                               added: added, changed: changed, destroyed: destroyed)
        return workspace.persistRun(record, directory: directory)
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
        status = .planning
        guard persist() else { status = .errored; completion(nil, workspace.historyError); return }
        workspace.lock(self)
        let runner = workspace.runner
        runner.plan(workingDirectory: directory, runId: id.uuidString) { [self, workspace] output, error in
            workspace.unlock()
            planOutput = RunHistoryStore.redactSensitiveOutputs(output ?? error?.output)
            plan = planOutput.map(handleNDJsonSuccess)
            errorMessage = error?.message
            status = error == nil ? .planned : .errored
            workspace.isValid = error == nil
            if let changes = plan?.changeSummaries.last {
                added = changes.changes.add; changed = changes.changes.change; destroyed = changes.changes.remove
            }
            if error != nil { runner.discardPlan(runId: id.uuidString) }
            let saved = persist()
            if saved, error == nil, let plan { workspace.didPlan(run: self, plan: plan) }
            completion(plan, errorMessage)
        }
    }

    func doApply(_ completion: @escaping (StructuredLog?, String?) -> Void) {
        guard canConfirm, let workspace, let directory = workspaceDirectory,
              workspace.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
        status = .applying
        guard persist() else { status = .planned; completion(nil, workspace.historyError); return }
        workspace.lock(self)
        let runner = workspace.runner
        runner.apply(workingDirectory: directory, runId: id.uuidString) { [self, workspace] output, error in
            workspace.unlock()
            applyOutput = RunHistoryStore.redactSensitiveOutputs(output ?? error?.output)
            apply = applyOutput.map(handleNDJsonSuccess)
            errorMessage = error?.message
            status = error == nil ? .applied : .errored
            workspace.isValid = error == nil
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
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    static func ==(lhs: TerraformRun, rhs: TerraformRun) -> Bool { lhs === rhs }
}
