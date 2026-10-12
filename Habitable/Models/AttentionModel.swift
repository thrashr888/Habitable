import Foundation

/// Something in the cloud that wants a person: a run in flight, a run waiting
/// for approval, or drift. Feeds the menu bar extra and notifications.
struct AttentionItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case running(status: String)
        case approval
        case drift(count: Int)
    }
    let workspaceID: String
    let workspaceName: String
    let kind: Kind
    var since: Date? = nil
    /// The run an approval is about; a notification confirms this one and no other.
    var runID: String? = nil

    var id: String {
        switch kind {
        case .running: return "running:\(workspaceID)"
        case .approval: return "approval:\(workspaceID):\(runID ?? "")"
        case .drift: return "drift:\(workspaceID)"
        }
    }

    /// "Applying", "Waiting for your approval", "Drift detected".
    var title: String {
        switch kind {
        case .running(let status): return status.replacingOccurrences(of: "_", with: " ").capitalized
        case .approval: return "Waiting for your approval"
        case .drift(let count): return count == 1 ? "1 resource drifted" : "\(count) resources drifted"
        }
    }
}

enum AttentionModel {
    static let inFlight: Set<String> = ["pending", "fetching", "fetching_completed", "pre_plan_running", "pre_plan_completed",
                                        "queuing", "plan_queued", "planning", "post_plan_running", "post_plan_completed",
                                        "cost_estimating", "policy_checking", "policy_soft_failed", "confirmed", "pre_apply_running",
                                        "pre_apply_completed", "apply_queued", "applying"]
    static let awaitingApproval: Set<String> = ["planned", "cost_estimated", "policy_checked", "policy_override"]

    /// Items for an organization's workspaces, approvals first, then runs, then drift.
    static func items(workspaces: [HCPWorkspace], explorer: [String: HCPExplorerWorkspace]) -> [AttentionItem] {
        var approvals: [AttentionItem] = []
        var running: [AttentionItem] = []
        var drift: [AttentionItem] = []
        for workspace in workspaces {
            if let status = workspace.currentRunStatus {
                if awaitingApproval.contains(status), !workspace.autoApply {
                    approvals.append(AttentionItem(workspaceID: workspace.id, workspaceName: workspace.name, kind: .approval,
                                                   since: workspace.currentRunCreatedAt, runID: workspace.currentRunID))
                } else if inFlight.contains(status) {
                    running.append(AttentionItem(workspaceID: workspace.id, workspaceName: workspace.name, kind: .running(status: status), since: workspace.currentRunCreatedAt))
                }
            }
            if let row = explorer[workspace.name], row.drifted == true {
                drift.append(AttentionItem(workspaceID: workspace.id, workspaceName: workspace.name, kind: .drift(count: row.resourcesDrifted ?? 0)))
            }
        }
        let byName: (AttentionItem, AttentionItem) -> Bool = { $0.workspaceName.localizedCaseInsensitiveCompare($1.workspaceName) == .orderedAscending }
        return approvals.sorted(by: byName) + running.sorted(by: byName) + drift.sorted(by: byName)
    }
}
