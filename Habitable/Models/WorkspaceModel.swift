//
//  Workspace.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import Foundation
import SwiftUI
import SwiftyJSON
import CryptoKit
import Darwin

/// Serializes Terraform commands across windows and app processes for one canonical directory.
final class WorkspaceCommandCoordinator {
    final class Lease {
        private let descriptor: Int32
        let metadataURL: URL
        private let failureMarkerURL: URL
        private let failureIdentifier: String
        private var isReleased = false
        private(set) var generation: Int64

        fileprivate init(descriptor: Int32, metadataURL: URL, failureMarkerURL: URL,
                        failureIdentifier: String, generation: Int64) {
            self.descriptor = descriptor
            self.metadataURL = metadataURL
            self.failureMarkerURL = failureMarkerURL
            self.failureIdentifier = failureIdentifier
            self.generation = generation
        }

        func invalidatePlans() throws {
            let nextGeneration = generation + 1
            do {
                try saveGeneration(nextGeneration)
                generation = nextGeneration
            } catch {
                WorkspaceCommandCoordinator.markFailed(identifier: failureIdentifier,
                    marker: failureMarkerURL, reason: error.localizedDescription)
                throw CoordinatorError.unavailable("Could not invalidate saved plans. Workspace commands are blocked until coordination recovers. \(error.localizedDescription)")
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        private func saveGeneration(_ value: Int64) throws {
            try WorkspaceCommandCoordinator.writeDurably(Data(String(value).utf8), to: metadataURL)
        }

        deinit { release() }
    }

    enum CoordinatorError: LocalizedError {
        case busy
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "Another Habitable window or process is using this Terraform workspace. Try again when its command finishes."
            case .unavailable(let message): return "Workspace command coordination failed: \(message)"
            }
        }
    }

    static let shared = WorkspaceCommandCoordinator()
    private static let failureLock = NSLock()
    private static var failedIdentifiers = Set<String>()
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Habitable/CommandCoordination", isDirectory: true)) {
        self.directory = directory
    }

    func acquire(workspace: URL, contextIdentity: String) throws -> Lease {
        let folder = coordinationFolder(for: workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = folder.appendingPathComponent(".lock")
        let failureMarkerURL = folder.appendingPathComponent(".failed")
        let failureIdentifier = folder.standardizedFileURL.path
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CoordinatorError.unavailable(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw CoordinatorError.busy }
            throw CoordinatorError.unavailable(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)
        }

        if Self.isFailed(identifier: failureIdentifier) || FileManager.default.fileExists(atPath: failureMarkerURL.path) {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw CoordinatorError.unavailable("Workspace command coordination previously failed. Saved plans cannot be applied safely.")
        }

        let metadataURL = folder.appendingPathComponent("generation")
        do {
            let savedGeneration: Int64
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                guard let saved = try? String(contentsOf: metadataURL, encoding: .utf8),
                      let parsed = Int64(saved.trimmingCharacters(in: .whitespacesAndNewlines)), parsed >= 0 else {
                    throw CoordinatorError.unavailable("The saved-plan generation could not be read safely.")
                }
                savedGeneration = parsed
            } else {
                savedGeneration = 0
            }
            var generation = savedGeneration
            let contextURL = folder.appendingPathComponent("context")
            let previousContext = try? String(contentsOf: contextURL, encoding: .utf8)
            if previousContext != contextIdentity {
                let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
                guard !overflow else { throw CoordinatorError.unavailable("The saved-plan generation is exhausted.") }
                generation = nextGeneration
                try Self.writeDurably(Data(String(generation).utf8), to: metadataURL)
                try Self.writeDurably(Data(contextIdentity.utf8), to: contextURL)
            }
            return Lease(descriptor: descriptor, metadataURL: metadataURL, failureMarkerURL: failureMarkerURL,
                         failureIdentifier: failureIdentifier, generation: generation)
        } catch {
            Self.markFailed(identifier: failureIdentifier, marker: failureMarkerURL, reason: error.localizedDescription)
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw CoordinatorError.unavailable(error.localizedDescription)
        }
    }

    /// Returns whether this workspace has a persistent or in-process failed marker.
    func recoveryRequired(workspace: URL) -> Bool {
        let folder = coordinationFolder(for: workspace)
        return Self.isFailed(identifier: folder.standardizedFileURL.path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent(".failed").path)
    }

    /// Advances saved-plan generation under the workspace lock, then clears the failure marker.
    /// The new generation and its directory entry are synced before the marker is removed.
    @discardableResult
    func recover(workspace: URL) throws -> Int64 {
        let folder = coordinationFolder(for: workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = folder.appendingPathComponent(".lock")
        let markerURL = folder.appendingPathComponent(".failed")
        let identifier = folder.standardizedFileURL.path
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw CoordinatorError.unavailable(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw CoordinatorError.busy }
            throw CoordinatorError.unavailable(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        guard recoveryRequired(workspace: workspace) else {
            throw CoordinatorError.unavailable("Workspace coordination does not need recovery.")
        }

        let metadataURL = folder.appendingPathComponent("generation")
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let saved = try? String(contentsOf: metadataURL, encoding: .utf8),
              let savedGeneration = Int64(saved.trimmingCharacters(in: .whitespacesAndNewlines)), savedGeneration >= 0 else {
            throw CoordinatorError.unavailable("The saved-plan generation could not be read safely. The failure marker remains in place.")
        }
        let (nextGeneration, overflow) = savedGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw CoordinatorError.unavailable("The saved-plan generation is exhausted. The failure marker remains in place.")
        }

        try Self.writeDurably(Data(String(nextGeneration).utf8), to: metadataURL)
        do {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                try FileManager.default.removeItem(at: markerURL)
            }
            try Self.syncDirectory(folder)
        } catch {
            // Keep this process fail-closed if marker removal could not be made durable.
            Self.markFailed(identifier: identifier, marker: markerURL, reason: error.localizedDescription)
            throw CoordinatorError.unavailable("The new generation was saved, but the failure marker could not be cleared safely. \(error.localizedDescription)")
        }
        Self.failureLock.lock()
        Self.failedIdentifiers.remove(identifier)
        Self.failureLock.unlock()
        return nextGeneration
    }

    private func coordinationFolder(for workspace: URL) -> URL {
        let canonicalPath = RunHistoryStore.workspacePath(workspace)
        let key = SHA256.hash(data: Data(canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key, isDirectory: true)
    }

    fileprivate static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    fileprivate static func markFailed(identifier: String, marker: URL, reason: String) {
        // Keep the failure visible to other app processes when the filesystem still permits writes.
        do {
            try Data(reason.utf8).write(to: marker, options: .atomic)
        } catch {
            failureLock.lock()
            failedIdentifiers.insert(identifier)
            failureLock.unlock()
        }
    }

    private static func isFailed(identifier: String) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failedIdentifiers.contains(identifier)
    }
}

// break out plan, apply, show, etc runners
class Workspace: ObservableObject {
    var id = UUID()

    @Published var runner: Runner
    @Published var managedTerraformVersion: String?
    private let preferences: UserDefaults
    private let commandCoordinator: WorkspaceCommandCoordinator
    let historyStore: RunHistoryStore
    @Published var historyError: String?
    @Published private(set) var coordinationRecoveryNotice: String?
    private var unsavedRuns: [UUID: (RunRecord, URL)] = [:]

    // state
    @Published var locked = false
    @Published var lockedBy: TerraformRun?
    @Published private(set) var isCancelingCommand = false
    @Published private var activeCommand: TerraformCommandHandle?

    var canCancelCommand: Bool { activeCommand != nil }

    func cancelCommand() {
        guard let activeCommand, !isCancelingCommand else { return }
        isCancelingCommand = true
        activeCommand.cancel()
    }

    private func appendCommandOutput(_ text: String, redactor: SensitiveInputRedactor) {
        let safe = redactor.redact(text)
        textOutput = String(((textOutput ?? "") + safe).suffix(262_144))
    }

    private func finishCommand() {
        activeCommand = nil
        isCancelingCommand = false
    }

    // config
    @Published var isValid = false
    @Published var isInitialized = false
    @Published var hasState = false
    @Published var hasVariables = false

    // settings
    @Published var workingDirectory: URL?
//    @AppStorage("workingDirectory") var workingDirectory: URL?
    @AppStorage("lastWorkingDirectory") var lastWorkingDirectory: URL?
    @Published var description = ""
    @Published var autoApply = false
    @Published var terraformVersion = "Checking…"
    @Published var selectedTerraformWorkspace = "default"
    @Published var backendIdentity = "unknown backend"
    @Published private(set) var executionContextDisplay = "Workspace: default · Backend: unknown backend"

    // data
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var runs: [TerraformRun] = []
    @Published var state: ShowMessage?
    @Published var terraformVariables: [TerraformVariable] = []
    @Published var environmentVariables: [EnvironmentVariable] = []

    init(dir: URL? = nil, restoreLastDirectory: Bool = true, defaults: UserDefaults = .standard,
         historyStore: RunHistoryStore = RunHistoryStore(),
         commandCoordinator: WorkspaceCommandCoordinator = .shared) {
        self.historyStore = historyStore
        preferences = defaults
        self.commandCoordinator = commandCoordinator
        managedTerraformVersion = defaults.string(forKey: TerraformReleaseService.selectionKey)
        runner = Runner(executableURL: TerraformReleaseService.selectedExecutable(defaults: defaults))
        refreshTerraformVersion()
        if restoreLastDirectory, dir == nil, let lastDir = lastWorkingDirectory {
            workingDirectory = lastDir
            updateWorkingDirectory(dir: lastDir)
            return
        }
        if let dir = dir {
            workingDirectory = dir
            updateWorkingDirectory(dir: dir)
        }
    }
    
//    init(path: String? = nil) {
//        if let path = path {
//            let dir = URL(fileURLWithPath: path)
//            workingDirectory = dir
//            updateWorkingDirectory(dir: dir)
//        }
//    }
    
    func useTerraform(version: String?, executableURL: URL?) {
        guard !locked else { return }
        // Saved plans belong to the CLI that created them. Require a fresh plan after switching.
        for run in runs { run.doDiscard() }
        managedTerraformVersion = version
        preferences.set(version, forKey: TerraformReleaseService.selectionKey)
        runner = Runner(executableURL: executableURL)
        terraformVersion = "Checking…"
        state = nil
        isValid = false
        refreshTerraformVersion()
        if workingDirectory != nil { validate() }
    }

    func refreshTerraformVersion() {
        let currentRunner = runner
        runner.version { output, error in
            guard self.runner === currentRunner else { return }
            if let output = output, let data = output.data(using: .utf8),
               let json = try? JSON(data: data), let version = json["terraform_version"].string {
                self.terraformVersion = version
            } else {
                self.terraformVersion = "Unavailable"
                self.errorMessage = error?.message
            }
        }
    }

    func reset() {
        textOutput = nil
        errorMessage = nil
    }

    func addUrl() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            if response == NSApplication.ModalResponse.OK, let fileUrl = panel.url {
                self.updateWorkingDirectory(dir: fileUrl)
            }
        }
    }

    func save() {
        // save settings to user defaults?
        // there's some ModelState thing in swiftui for this
    }

    func updateWorkingDirectory(dir: URL) {
        guard !locked else { return }
        coordinationRecoveryNotice = nil
        guard retryUnsavedRuns() else { return }
        for run in runs { run.doDiscard() }
        guard retryUnsavedRuns() else { return }
        runs = []
        historyError = nil
        state = nil
        isInitialized = false
        isValid = false
        hasState = false
        hasVariables = false
        terraformVariables = []
        workingDirectory = dir
        refreshExecutionContext()
        lastWorkingDirectory = dir
        reloadRunHistory()

        var isDir: ObjCBool = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dir.appendingPathComponent(".terraform").path, isDirectory: &isDir) {
            isInitialized = true
        }
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfstate").path, isDirectory: &isDir) {
            hasState = true
        }
        
        checkVariables()
        validate()
    }

    var executionContextIdentifier: String {
        let terraform = runner.executableURL?.standardizedFileURL.path ?? "unavailable"
        return "workspace=\(selectedTerraformWorkspace);backend=\(backendIdentity);terraform=\(terraform)"
    }

    func acquireCommandLease() throws -> WorkspaceCommandCoordinator.Lease {
        guard let directory = workingDirectory else {
            throw WorkspaceCommandCoordinator.CoordinatorError.unavailable("No working directory is selected.")
        }
        refreshExecutionContext()
        return try commandCoordinator.acquire(workspace: directory, contextIdentity: executionContextIdentifier)
    }

    var coordinationRecoveryRequired: Bool {
        guard let directory = workingDirectory else { return false }
        return commandCoordinator.recoveryRequired(workspace: directory)
    }

    func recoverCoordination() {
        guard !locked, let directory = workingDirectory else { return }
        do {
            _ = try commandCoordinator.recover(workspace: directory)
            for run in runs { run.doDiscard() }
            coordinationRecoveryNotice = "Coordination recovered. Create a new plan before applying."
            errorMessage = nil
            validate()
        } catch {
            coordinationRecoveryNotice = nil
            errorMessage = error.localizedDescription
        }
    }

    private func refreshExecutionContext() {
        guard let directory = workingDirectory else { return }
        let environmentWorkspace = ProcessInfo.processInfo.environment["TF_WORKSPACE"]
        let selectionFile = directory.appendingPathComponent(".terraform/environment")
        let fileWorkspace = try? String(contentsOf: selectionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        selectedTerraformWorkspace = environmentWorkspace?.isEmpty == false ? environmentWorkspace! : (fileWorkspace?.isEmpty == false ? fileWorkspace! : "default")

        let metadataURL = directory.appendingPathComponent(".terraform/terraform.tfstate")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSON(data: data),
              let backend = json["backend"]["type"].string else {
            backendIdentity = "unknown backend"
            executionContextDisplay = "Workspace: \(selectedTerraformWorkspace) · Backend: \(backendIdentity)"
            return
        }
        let backendHash = json["backend"]["hash"].string ?? json["backend"]["hash"].int.map(String.init)
        backendIdentity = backendHash.map { "\(backend) #\($0)" } ?? backend
        executionContextDisplay = "Workspace: \(selectedTerraformWorkspace) · Backend: \(backendIdentity)"
    }
    
    func checkVariables() {
        guard let dir = workingDirectory else { return }
        
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfvars").path, isDirectory: &isDir) {
            hasVariables = true
            parseTextVariables(file: dir.appendingPathComponent("terraform.tfvars"))
        }
        isDir = false
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfvars.json").path, isDirectory: &isDir) {
            hasVariables = true
            parseJSONVariables(file: dir.appendingPathComponent("terraform.tfvars.json"))
        }
        
        parseEnvironmentVariables()
    }
    
    private func parseEnvironmentVariables() {
        environmentVariables = []
        for (key, value) in ProcessInfo.processInfo.environment {
            if !key.hasPrefix("TF_VAR_") { continue }
            let variable = EnvironmentVariable()
            variable.key = key
            variable.value = value
            environmentVariables.append(variable)
        }
    }
    
    private func parseTextVariables(file: URL) {
        do {
            terraformVariables = []
            let vars = try String(contentsOf: file)
            for v in vars.split(separator: "\n") {
                let parts = v.split(separator: "=")
                                
                let variable = TerraformVariable()
                guard parts.count > 1 else { continue }
                variable.key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                if parts.count > 1 {
                    // TODO parse json value
                    variable.value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                terraformVariables.append(variable)
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    private func parseJSONVariables(file: URL) {
        let json = JSON.init(file)
        for (key, value):(String, JSON) in json {
            let variable = TerraformVariable()
            variable.key = key
            variable.value = value.string ?? ""
            terraformVariables.append(variable)
        }
    }

    private func cleanANSI(_ input: String) -> String {
        return input.replacingOccurrences(of: #"\[([0-9])+m"#, with: "", options: .regularExpression, range: nil)
    }

    func initialize() {
        guard !locked, let workingDirectory = self.workingDirectory else { return }
        let lease: WorkspaceCommandCoordinator.Lease
        do { lease = try acquireCommandLease() }
        catch { errorMessage = error.localizedDescription; return }
        reset()
        locked = true
        let redactor = SensitiveInputRedactor(variables: terraformVariables, environmentVariables: environmentVariables)
        textOutput = ""
        activeCommand = runner.initialize(workingDirectory: workingDirectory, onOutput: { _, text in
            self.appendCommandOutput(text, redactor: redactor)
        }, completion: { res, error in
            self.finishCommand()
            self.locked = false
            lease.release()
            if let error = error {
                self.errorMessage = redactor.redact(error.message)
                self.isValid = false
            }
            if let res = res {
                self.textOutput = redactor.redact(self.cleanANSI(res))
                self.isInitialized = true
                self.validate()
            }
            self.objectWillChange.send()
        })
    }
    
    func validate() {
        guard !locked, let workingDirectory = self.workingDirectory else { return }
        let lease: WorkspaceCommandCoordinator.Lease
        do { lease = try acquireCommandLease() }
        catch { errorMessage = error.localizedDescription; return }
        reset()
        locked = true
        let redactor = SensitiveInputRedactor(variables: terraformVariables, environmentVariables: environmentVariables)
        activeCommand = runner.validate(workingDirectory: workingDirectory, onOutput: { _, text in
            self.appendCommandOutput(text, redactor: redactor)
        }, completion: { res, error in
            self.finishCommand()
            self.locked = false
            lease.release()
            if let error = error {
                self.errorMessage = redactor.redact(error.message)
                self.isValid = false
            }
            if res != nil {
                // A successful validate proves the directory has completed init, even
                // when Terraform has no downloaded providers and creates no .terraform folder.
                self.isInitialized = true
                self.isValid = true
                self.refreshResources()
            }
            self.objectWillChange.send()
        })
    }
    
    func refreshResources() {
        guard let workingDirectory = workingDirectory else { return }
        guard !locked else { return }
        let lease: WorkspaceCommandCoordinator.Lease
        do { lease = try acquireCommandLease() }
        catch { errorMessage = error.localizedDescription; return }
        // Clear stale inventory while querying the selected local or remote backend.
        state = nil
        hasState = false
        lock()
        
        let redactor = SensitiveInputRedactor(variables: terraformVariables, environmentVariables: environmentVariables)
        activeCommand = runner.show(workingDirectory: workingDirectory, completion: { res, error in
            self.finishCommand()
            self.unlock()
            lease.release()
            
            if let res = res {
                let json = parseJsonOutput(res)
                if json["values"].dictionary != nil, json["values"]["root_module"].dictionary != nil {
                    self.state = transformShow(json)
                    self.errorMessage = nil
                    self.hasState = true
                    self.isValid = true
                } else {
                    self.state = nil
                    self.hasState = false
                    self.errorMessage = "Terraform returned no state data for the selected backend and workspace."
                }
            }
            
            if let error = error {
                // Validation succeeded; a missing state or inaccessible backend should
                // not make the Terraform configuration itself appear invalid.
                self.errorMessage = redactor.redact(error.message)
            }
        })
    }
    
//    func show() {
//        guard let workingDirectory = self.workingDirectory else { return }
//        locked = true
//        runner.validate(workingDirectory: workingDirectory, completion: { res, error in
//            self.locked = false
//            if let error = error {
//                self.errorMessage = error.message
//                self.isValid = false
//            }
//            if let res = res {
//                self.textOutput = redactor.redact(self.cleanANSI(res))
//                self.isValid = true
//            }
//        })
//    }
    
    func didPlan(run: TerraformRun, plan: StructuredLog) {
        if self.autoApply {
            run.doApply({ apply, error in
                
            })
        }
    }
    
    func didApply(run: TerraformRun, apply: StructuredLog) {
        for run in runs {
            run.doDiscard()
        }
        refreshResources()
    }
    
    func lock(_ by: TerraformRun? = nil) {
        lockedBy = by
        locked = true
    }
    func unlock() {
        lockedBy = nil
        locked = false
    }

    func reloadRunHistory() {
        guard !locked, let directory = workingDirectory else { return }
        guard retryUnsavedRuns() else { return }
        do {
            let records = try historyStore.load(workspace: directory)
            // Preserve live runs and their saved-plan capabilities when refreshing the list.
            let live = Dictionary(uniqueKeysWithValues: runs.filter { !$0.isRestored }.map { ($0.id, $0) })
            runs = records.map { live[$0.id] ?? TerraformRun(workspace: self, record: $0, restored: true) }
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    @discardableResult
    func persistRun(_ record: RunRecord, directory: URL) -> Bool {
        do {
            try historyStore.save(record, workspace: directory)
            unsavedRuns.removeValue(forKey: record.id)
            if unsavedRuns.isEmpty { historyError = nil }
            return true
        } catch {
            unsavedRuns[record.id] = (record, directory)
            historyError = "Run history could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    private func retryUnsavedRuns() -> Bool {
        for (record, directory) in Array(unsavedRuns.values) {
            if !persistRun(record, directory: directory) { return false }
        }
        return true
    }

    func queueRun(_ message: String? = nil) {
        guard !locked, isValid, historyError == nil, let directory = workingDirectory else { return }
        refreshExecutionContext()
        do {
            let record = try historyStore.create(workspace: directory, terraformVersion: terraformVersion, message: message,
                                                 selectedTerraformWorkspace: selectedTerraformWorkspace,
                                                 backendIdentity: backendIdentity)
            historyError = nil
            let run = TerraformRun(workspace: self, record: record, restored: false)
            runs.append(run)
            run.doPlan { _, _ in }
        } catch {
            historyError = "Cannot start a run until its history can be saved. \(error.localizedDescription)"
        }
    }

    func addTerraformVariable(_ variable: TerraformVariable) {
        terraformVariables.append(variable)
    }
    
    func addEnvironmentVariable(_ variable: EnvironmentVariable) {
        environmentVariables.append(variable)
    }
}
