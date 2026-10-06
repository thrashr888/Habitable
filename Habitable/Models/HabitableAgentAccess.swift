import Foundation
import Combine

/// One app-wide local agent server. It exposes the active local workspace: the
/// window most recently focused. With no workspace open the server keeps running
/// and answers that no workspace is open. Turning it off, or restarting it,
/// invalidates every callback of the previous server.
@MainActor
final class HabitableAgentAccess: ObservableObject {
    static let noWorkspaceMessage = "No workspace is open in Habitable."
    static let disabledMessage = "Agent access disabled."

    @Published private(set) var server: HabitableMCPServer?
    @Published private(set) var isEnabled = false
    @Published private(set) var isStarting = false
    @Published private(set) var message: String?
    /// Folder name of the workspace agents can currently reach, if any.
    @Published private(set) var activeWorkspaceName: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var jobs: [String: UUID] = [:]
    private var pendingJobs = Set<String>()
    private weak var workspace: Workspace?

    /// Makes `workspace` the one agents can reach. Safe to call repeatedly.
    func activate(_ workspace: Workspace) {
        if self.workspace !== workspace { jobs = [:]; pendingJobs = [] }
        self.workspace = workspace
        refreshActiveName()
    }

    /// Clears the active workspace only when it is `workspace`.
    func deactivate(_ workspace: Workspace) {
        guard self.workspace === workspace else { return }
        self.workspace = nil
        jobs = [:]; pendingJobs = []
        refreshActiveName()
    }

    /// The active workspace's folder changed; follow it without stopping the server.
    func workspaceChanged(in workspace: Workspace) {
        guard self.workspace === workspace else { return }
        jobs = [:]; pendingJobs = []
        refreshActiveName()
    }

    private func refreshActiveName() {
        let name = workspace?.workingDirectory?.lastPathComponent
        if activeWorkspaceName != name { activeWorkspaceName = name }
    }

    /// Starts or stops the server. Passing a workspace also makes it the active one.
    func setEnabled(_ enabled: Bool, in workspace: Workspace? = nil) {
        if let workspace { activate(workspace) }
        generation = UUID(); task?.cancel(); task = nil
        let oldServer = server
        server = nil; isEnabled = false; isStarting = false
        jobs = [:]; pendingJobs = []
        if let oldServer { Task { await oldServer.stop() } }
        guard enabled else { message = nil; return }
        let id = generation
        let actions = HabitableMCPActions(
            workspaceStatus: { [weak self] in self?.status(generation: id) ?? Self.disabledMessage },
            declarations: { [weak self] in
                guard let self, let workspace = self.authorizedWorkspace(id), let directory = workspace.workingDirectory else { return self?.unavailable(id) ?? Self.disabledMessage }
                let inspection = Task.detached(priority: .utility) { TerraformConfigurationInspector.inspectMetadata(directory: directory) }
                let metadata = await withTaskCancellationHandler(operation: { await inspection.value }, onCancel: { inspection.cancel() })
                guard self.authorizedWorkspace(id) === workspace else { return Self.disabledMessage }
                return metadata.inputs.prefix(100).map { "\($0.name): \($0.type ?? "unknown type") · \($0.required ? "required" : "optional") · sensitive=\($0.sensitive) · \($0.sourceLocation)" }.joined(separator: "\n")
            },
            resourceMetadata: { [weak self] in
                guard let self, let workspace = self.authorizedWorkspace(id) else { return self?.unavailable(id) ?? Self.disabledMessage }
                return (workspace.state?.resources ?? []).prefix(100).map { "\($0.address ?? "Unknown address") · type=\($0.type ?? "unknown") · provider=\($0.provider_name ?? "unknown")" }.joined(separator: "\n")
            },
            outputMetadata: { [weak self] in
                guard let self, let workspace = self.authorizedWorkspace(id) else { return self?.unavailable(id) ?? Self.disabledMessage }
                return (workspace.state?.outputs ?? []).prefix(100).map { "\($0.key) · type=\($0.type ?? "unknown") · sensitive=\($0.sensitive)" }.joined(separator: "\n")
            },
            runSummaries: { [weak self] in
                guard let self, let workspace = self.authorizedWorkspace(id) else { return self?.unavailable(id) ?? Self.disabledMessage }
                return workspace.runs.prefix(50).map { "\($0.id.uuidString) · run #\($0.number) · \($0.status.rawValue) · plan-only=\($0.planOnly)" }.joined(separator: "\n")
            },
            diagnostics: { [weak self] in
                guard let self, let workspace = self.authorizedWorkspace(id) else { return self?.unavailable(id) ?? Self.disabledMessage }
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
                guard let self, let workspace = self.authorizedWorkspace(id) else { return self?.unavailable(id) ?? Self.disabledMessage }
                guard !workspace.locked, !workspace.historyLoading, !workspace.hasUnavailableRememberedInputs else { return "Workspace is busy or has unavailable inputs." }
                workspace.validate()
                return "Validation started. Poll workspace_status, then diagnostics."
            },
            requestPlan: { [weak self] in self?.plan(generation: id) ?? Self.disabledMessage },
            runStatus: { [weak self] job in await self?.runStatus(job, generation: id) ?? Self.disabledMessage })
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

    /// The active workspace when this callback's server is still current and a
    /// folder is open; nil otherwise.
    private func authorizedWorkspace(_ id: UUID) -> Workspace? {
        guard generation == id, let workspace, workspace.workingDirectory != nil else { return nil }
        return workspace
    }

    /// Why `authorizedWorkspace` is nil for this callback.
    private func unavailable(_ id: UUID) -> String {
        generation == id ? Self.noWorkspaceMessage : Self.disabledMessage
    }

    private func status(generation: UUID) -> String {
        guard let workspace = authorizedWorkspace(generation) else { return unavailable(generation) }
        return "Initialized: \(workspace.isInitialized)\nValid: \(workspace.isValid)\nBusy: \(workspace.locked || workspace.historyLoading)\nReading inputs: \(workspace.isInspectingInputs)\nMissing required inputs: \(workspace.terraformVariables.filter(\.isMissingRequiredInput).count)\nTerraform: \(workspace.terraformVersion)\nTerraform workspace: \(workspace.selectedTerraformWorkspace)\nBackend: \(workspace.backendIdentity)"
    }

    private func plan(generation: UUID) -> String {
        guard let workspace = authorizedWorkspace(generation) else { return unavailable(generation) }
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
            guard let self, self.authorizedWorkspace(generation) === workspace else { return }
            self.pendingJobs.remove(job); self.jobs[job] = runID
        })
        return "Plan-only job: \(job). Poll run_status with this identifier."
    }

    private func runStatus(_ job: String, generation: UUID) async -> String {
        guard let workspace = authorizedWorkspace(generation) else { return unavailable(generation) }
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
        guard let directory = workspace.workingDirectory else { return Self.noWorkspaceMessage }
        let store = workspace.historyStore
        let record = await Task.detached(priority: .utility) {
            try? store.readPersistedRecord(id: runID, workspace: directory)
        }.value
        guard authorizedWorkspace(generation) === workspace else { return Self.disabledMessage }
        guard let record else { return "Run not found in the selected workspace." }
        return "\(record.id.uuidString) · \(record.status.rawValue) · plan-only=\(record.planOnly ?? false)"
    }
}
