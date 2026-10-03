import Foundation
import Combine

/// Each enable action grants access to one selected local folder, until disabled
/// or the window changes folders. Old server callbacks cannot inherit a new grant.
@MainActor
final class HabitableAgentAccess: ObservableObject {
    @Published private(set) var server: HabitableMCPServer?
    @Published private(set) var isEnabled = false
    @Published private(set) var isStarting = false
    @Published private(set) var message: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var jobs: [String: UUID] = [:]
    private var pendingJobs = Set<String>()
    private weak var workspace: Workspace?
    private var grantedDirectory: String?

    func setEnabled(_ enabled: Bool, in workspace: Workspace) {
        generation = UUID(); task?.cancel(); task = nil
        let oldServer = server
        server = nil; isEnabled = false; isStarting = false
        grantedDirectory = nil; jobs = [:]; pendingJobs = []
        if let oldServer { Task { await oldServer.stop() } }
        guard enabled else { message = nil; return }
        guard let directory = workspace.workingDirectory else {
            message = "Open a local Terraform folder before enabling agent access."; return
        }
        self.workspace = workspace
        grantedDirectory = RunHistoryStore.workspacePath(directory)
        let id = generation
        let actions = HabitableMCPActions(
            workspaceStatus: { [weak self] in self?.status(generation: id) ?? "Agent access disabled." },
            declarations: { [weak self] in
                guard let workspace = self?.authorizedWorkspace(id), let directory = workspace.workingDirectory else { return "Agent access disabled." }
                let inspection = Task.detached(priority: .utility) { TerraformConfigurationInspector.inspectMetadata(directory: directory) }
                let metadata = await withTaskCancellationHandler(operation: { await inspection.value }, onCancel: { inspection.cancel() })
                guard self?.authorizedWorkspace(id) != nil else { return "Agent access disabled." }
                return metadata.inputs.prefix(100).map { "\($0.name): \($0.type ?? "unknown type") · \($0.required ? "required" : "optional") · sensitive=\($0.sensitive) · \($0.sourceLocation)" }.joined(separator: "\n")
            },
            resourceMetadata: { [weak self] in
                guard let workspace = self?.authorizedWorkspace(id) else { return "Agent access disabled." }
                return (workspace.state?.resources ?? []).prefix(100).map { "\($0.address ?? "Unknown address") · type=\($0.type ?? "unknown") · provider=\($0.provider_name ?? "unknown")" }.joined(separator: "\n")
            },
            outputMetadata: { [weak self] in
                guard let workspace = self?.authorizedWorkspace(id) else { return "Agent access disabled." }
                return (workspace.state?.outputs ?? []).prefix(100).map { "\($0.key) · type=\($0.type ?? "unknown") · sensitive=\($0.sensitive)" }.joined(separator: "\n")
            },
            runSummaries: { [weak self] in
                guard let workspace = self?.authorizedWorkspace(id) else { return "Agent access disabled." }
                return workspace.runs.prefix(50).map { "\($0.id.uuidString) · run #\($0.number) · \($0.status.rawValue) · plan-only=\($0.planOnly)" }.joined(separator: "\n")
            },
            diagnostics: { [weak self] in
                guard let workspace = self?.authorizedWorkspace(id) else { return "Agent access disabled." }
                // Raw CLI diagnostics may contain configuration literals. Share only
                // severity and source ranges; the app retains its redacted full review.
                guard let text = workspace.textOutput, let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let diagnostics = object["diagnostics"] as? [[String: Any]] else {
                    return workspace.isValid ? "Configuration is valid." : "Validate configuration and inspect diagnostics in Habitable."
                }
                return diagnostics.prefix(100).map { diagnostic in
                    let range = diagnostic["range"] as? [String: Any]
                    let start = range?["start"] as? [String: Any]
                    return "\(diagnostic["severity"] as? String ?? "diagnostic") · \(range?["filename"] as? String ?? "configuration"):\(start?["line"] as? Int ?? 1)"
                }.joined(separator: "\n")
            },
            validate: { [weak self] in
                guard let workspace = self?.authorizedWorkspace(id) else { return "Agent access disabled." }
                guard !workspace.locked, !workspace.historyLoading, !workspace.hasUnavailableRememberedInputs else { return "Workspace is busy or has unavailable inputs." }
                workspace.validate()
                return "Validation started. Poll workspace_status, then diagnostics."
            },
            requestPlan: { [weak self] in self?.plan(generation: id) ?? "Agent access disabled." },
            runStatus: { [weak self] job in await self?.runStatus(job, generation: id) ?? "Agent access disabled." })
        let server = HabitableMCPServer(actions: actions)
        self.server = server; isStarting = true; message = nil
        task = Task { [weak self] in
            do {
                try await server.startListening()
                guard let self, self.generation == id, self.authorizedWorkspace(id) != nil else { await server.stop(); return }
                self.isEnabled = true; self.isStarting = false
            } catch {
                guard let self, self.generation == id else { return }
                self.server = nil; self.isStarting = false
                self.message = "Could not start local agent access. Try again."
            }
        }
    }

    func workspaceChanged(in workspace: Workspace) {
        if grantedDirectory != workspace.workingDirectory.map(RunHistoryStore.workspacePath), server != nil {
            setEnabled(false, in: workspace)
            message = "Agent access stopped when the folder changed. Enable it for this folder when ready."
        }
    }

    private func authorizedWorkspace(_ id: UUID) -> Workspace? {
        guard generation == id, let workspace, let grantedDirectory,
              workspace.workingDirectory.map(RunHistoryStore.workspacePath) == grantedDirectory else { return nil }
        return workspace
    }

    private func status(generation: UUID) -> String {
        guard let workspace = authorizedWorkspace(generation) else { return "Agent access disabled." }
        return "Initialized: \(workspace.isInitialized)\nValid: \(workspace.isValid)\nBusy: \(workspace.locked || workspace.historyLoading)\nReading inputs: \(workspace.isInspectingInputs)\nMissing required inputs: \(workspace.terraformVariables.filter(\.isMissingRequiredInput).count)\nTerraform: \(workspace.terraformVersion)\nTerraform workspace: \(workspace.selectedTerraformWorkspace)\nBackend: \(workspace.backendIdentity)"
    }

    private func plan(generation: UUID) -> String {
        guard let workspace = authorizedWorkspace(generation) else { return "Agent access disabled." }
        guard !workspace.locked, !workspace.historyLoading, !workspace.isInspectingInputs,
              workspace.isInitialized, workspace.isValid, workspace.historyError == nil,
              !workspace.hasUnavailableRememberedInputs,
              !workspace.terraformVariables.contains(where: { $0.isMissingRequiredInput || $0.hasUnresolvedDiscoveredValue }) else {
            return "Initialize and validate the configuration, resolve missing inputs, and wait for active commands before planning."
        }
        let job = UUID().uuidString
        if jobs.count >= 500, let oldest = jobs.keys.first { jobs.removeValue(forKey: oldest) }
        pendingJobs.insert(job)
        workspace.queueRun("Agent-requested plan", triggerSource: "mcp", planOnly: true, onCreated: { [weak self] runID in
            guard let self, self.authorizedWorkspace(generation) != nil else { return }
            self.pendingJobs.remove(job); self.jobs[job] = runID
        })
        return "Plan-only job: \(job). Poll run_status with this identifier."
    }

    private func runStatus(_ job: String, generation: UUID) async -> String {
        guard let workspace = authorizedWorkspace(generation) else { return "Agent access disabled." }
        if pendingJobs.contains(job) {
            if workspace.historyError != nil || (!workspace.locked && !workspace.historyLoading) {
                pendingJobs.remove(job)
                return "Plan did not start. Inspect workspace status in Habitable."
            }
            return "Preparing plan."
        }
        guard let runID = jobs[job] ?? UUID(uuidString: job) else { return "Run not found in the selected workspace." }
        if let run = workspace.runs.first(where: { $0.id == runID }) ??
            (workspace.latestOverviewRun?.id == runID ? workspace.latestOverviewRun : nil) {
            return "\(run.id.uuidString) · \(run.status.rawValue) · plan-only=\(run.planOnly)"
        }
        guard let directory = workspace.workingDirectory else { return "Agent access disabled." }
        let store = workspace.historyStore
        let record = await Task.detached(priority: .utility) {
            try? store.readPersistedRecord(id: runID, workspace: directory)
        }.value
        guard authorizedWorkspace(generation) != nil else { return "Agent access disabled." }
        guard let record else { return "Run not found in the selected workspace." }
        return "\(record.id.uuidString) · \(record.status.rawValue) · plan-only=\(record.planOnly ?? false)"
    }
}
