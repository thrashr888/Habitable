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
final class WorkspaceCommandCoordinator: Sendable {
    /// Mutable lease state is protected by `stateLock`; the descriptor and file URLs
    /// are immutable after initialization, so callers can safely pass a lease to
    /// command completion callbacks without sending unsynchronized state.
    final class Lease: @unchecked Sendable {
        private let stateLock = NSLock()
        private let descriptor: Int32
        let metadataURL: URL
        private let failureMarkerURL: URL
        private let failureIdentifier: String
        private var isReleased = false
        private var currentGeneration: Int64

        var generation: Int64 {
            stateLock.lock(); defer { stateLock.unlock() }
            return currentGeneration
        }

        fileprivate init(descriptor: Int32, metadataURL: URL, failureMarkerURL: URL,
                        failureIdentifier: String, generation: Int64) {
            self.descriptor = descriptor
            self.metadataURL = metadataURL
            self.failureMarkerURL = failureMarkerURL
            self.failureIdentifier = failureIdentifier
            currentGeneration = generation
        }

        func invalidatePlans() throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            let (nextGeneration, overflow) = currentGeneration.addingReportingOverflow(1)
            guard !overflow else {
                throw WorkspaceCommandCoordinator.CoordinatorError.unavailable("The saved-plan generation is exhausted.")
            }
            do {
                try saveGeneration(nextGeneration)
                currentGeneration = nextGeneration
            } catch {
                WorkspaceCommandCoordinator.markFailed(identifier: failureIdentifier,
                    marker: failureMarkerURL, reason: error.localizedDescription)
                throw CoordinatorError.unavailable("Could not invalidate saved plans. Workspace commands are blocked until coordination recovers. \(error.localizedDescription)")
            }
        }

        func release() {
            stateLock.lock()
            guard !isReleased else {
                stateLock.unlock()
                return
            }
            isReleased = true
            stateLock.unlock()
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
    // Every access to this fallback set is paired with `failureLock`; the marker file
    // remains the cross-process source of truth when it can be written.
    nonisolated(unsafe) private static var failedIdentifiers = Set<String>()
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
@MainActor
class Workspace: ObservableObject {
    var id = UUID()

    @Published var runner: Runner
    @Published var managedTerraformVersion: String?
    private let preferences: UserDefaults
    private let commandCoordinator: WorkspaceCommandCoordinator
    let historyStore: RunHistoryStore
    @Published var historyError: String?
    @Published private(set) var historyLoading = false
    @Published private(set) var historyPageOffset = 0
    @Published private(set) var historyTotalCount = 0
    let historyPageSize = 50
    @Published private(set) var coordinationRecoveryNotice: String?
    private var unsavedRuns: [UUID: (RunRecord, URL)] = [:]
    private var historyRequestID = UUID()
    private var historyActionRequestID = UUID()

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
        let safe = stripTerraformTerminalEscapes(redactor.redact(text))
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
    @Published var description = "" {
        didSet { persistWorkspaceDescription() }
    }
    @Published private(set) var descriptionPersistenceError: String?
    @Published private(set) var descriptionNeedsSave = false
    private let descriptionStore: WorkspaceDescriptionStore
    private var descriptionWorkspace: URL?
    private var isLoadingWorkspaceDescription = false
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
    @Published private(set) var rememberedInputsError: String?
    @Published private(set) var workspaceOpenError: String?
    private var rememberedInputLoadFailed = false
    private let workspaceInputStore: WorkspaceInputStore

    init(dir: URL? = nil, restoreLastDirectory: Bool = true, defaults: UserDefaults = .standard,
         historyStore: RunHistoryStore = RunHistoryStore(),
         commandCoordinator: WorkspaceCommandCoordinator = .shared,
         descriptionStore: WorkspaceDescriptionStore = WorkspaceDescriptionStore(),
         workspaceInputStore: WorkspaceInputStore = WorkspaceInputStore()) {
        self.historyStore = historyStore
        preferences = defaults
        self.commandCoordinator = commandCoordinator
        self.descriptionStore = descriptionStore
        self.workspaceInputStore = workspaceInputStore
        managedTerraformVersion = defaults.string(forKey: TerraformReleaseService.selectionKey)
        runner = Runner(executableURL: TerraformReleaseService.selectedExecutable(defaults: defaults))
        refreshTerraformVersion()
        if restoreLastDirectory, dir == nil, let lastDir = lastWorkingDirectory {
            updateWorkingDirectory(dir: lastDir)
            return
        }
        if let dir = dir {
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
                _ = self.openWorkspaceDirectory(fileUrl)
            }
        }
    }

    func save() {
        // save settings to user defaults?
        // there's some ModelState thing in swiftui for this
    }

    func updateWorkingDirectory(dir: URL) { _ = openWorkspaceDirectory(dir) }

    @discardableResult
    func openWorkspaceDirectory(_ dir: URL) -> Bool {
        workspaceOpenError = nil
        guard !locked else { workspaceOpenError = "Wait for the current workspace command to finish before opening another folder."; return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            workspaceOpenError = "The selected folder is unavailable. Choose an existing directory."
            return false
        }
        let previousPath = descriptionWorkspace.map(RunHistoryStore.workspacePath)
        let nextPath = RunHistoryStore.workspacePath(dir)
        if previousPath != nextPath, descriptionNeedsSave, !saveWorkspaceDescription() {
            workspaceOpenError = descriptionPersistenceError ?? "The current workspace description could not be saved."
            return false
        }
        let remembered: [(StoredWorkspaceInput, String?)]
        do { remembered = try workspaceInputStore.loadAllowingUnavailableSecrets(workspace: dir) }
        catch { workspaceOpenError = "Remembered workspace inputs could not be loaded. \(error.localizedDescription)"; return false }
        coordinationRecoveryNotice = nil
        guard retryUnsavedRuns() else { workspaceOpenError = historyError ?? "Unsaved run history could not be saved."; return false }
        for run in runs { run.doDiscard() }
        guard retryUnsavedRuns() else { workspaceOpenError = historyError ?? "Unsaved run history could not be saved."; return false }
        runs = []
        if previousPath != nextPath {
            isLoadingWorkspaceDescription = true
            descriptionWorkspace = dir
            descriptionNeedsSave = false
            description = ""
            descriptionPersistenceError = nil
            do {
                description = try descriptionStore.load(workspace: dir)
            } catch {
                descriptionPersistenceError = error.localizedDescription
            }
            isLoadingWorkspaceDescription = false
        }
        historyError = nil
        state = nil
        isInitialized = false
        isValid = false
        hasState = false
        hasVariables = false
        terraformVariables = []
        environmentVariables = []
        applyRememberedInputs(remembered)
        historyActionRequestID = UUID()
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
        return true
    }

    func dismissWorkspaceOpenError() { workspaceOpenError = nil }

    private func applyRememberedInputs(_ loaded: [(StoredWorkspaceInput, String?)]) {
        rememberedInputsError = nil
        rememberedInputLoadFailed = false
        for (record, value) in loaded {
            switch record.kind {
            case .terraform:
                let input = TerraformVariable()
                input.key = record.key; input.value = value ?? ""; input.description = record.description
                input.sensitive = record.sensitive; input.hcl = record.hcl; input.isUserInput = true
                input.isRemembered = true; input.rememberedSecretUnavailable = value == nil
                input.rememberedSecretID = record.secretID
                terraformVariables.append(input)
            case .environment:
                let input = EnvironmentVariable()
                input.key = record.key; input.value = value ?? ""; input.description = record.description
                input.sensitive = record.sensitive; input.isUserInput = true
                input.isRemembered = true; input.rememberedSecretUnavailable = value == nil
                input.rememberedSecretID = record.secretID
                environmentVariables.append(input)
            }
            if value == nil {
                rememberedInputLoadFailed = true
                rememberedInputsError = "A remembered sensitive input is unavailable in Keychain. Remove it or restore Keychain access before starting a run."
            }
        }
    }

    private func persistRememberedInputs() throws {
        guard let workspace = workingDirectory else { return }
        let records = terraformVariables.filter { $0.isUserInput && $0.isRemembered }.map {
            StoredWorkspaceInput(kind: .terraform, key: $0.key, value: $0.rememberedSecretUnavailable && $0.value.isEmpty ? nil : $0.value,
                                 secretID: $0.rememberedSecretUnavailable && $0.value.isEmpty ? $0.rememberedSecretID : nil,
                                 description: $0.description, sensitive: $0.sensitive, hcl: $0.hcl)
        } + environmentVariables.filter { $0.isUserInput && $0.isRemembered }.map {
            StoredWorkspaceInput(kind: .environment, key: $0.key, value: $0.rememberedSecretUnavailable && $0.value.isEmpty ? nil : $0.value,
                                 secretID: $0.rememberedSecretUnavailable && $0.value.isEmpty ? $0.rememberedSecretID : nil,
                                 description: $0.description, sensitive: $0.sensitive, hcl: false)
        }
        let cleanupNotice = try workspaceInputStore.save(records, workspace: workspace)
        rememberedInputLoadFailed = terraformVariables.contains(where: { $0.rememberedSecretUnavailable })
            || environmentVariables.contains(where: { $0.rememberedSecretUnavailable })
        let missingSecretNotice = rememberedInputLoadFailed
            ? "A remembered sensitive input is unavailable in Keychain. Replace it with a new value or remove it before running Terraform."
            : nil
        rememberedInputsError = [missingSecretNotice, cleanupNotice].compactMap { $0 }.joined(separator: " ")
        if rememberedInputsError?.isEmpty == true { rememberedInputsError = nil }
    }

    var hasUnavailableRememberedInputs: Bool { rememberedInputLoadFailed }

    private func persistWorkspaceDescription() {
        guard !isLoadingWorkspaceDescription, descriptionWorkspace != nil else { return }
        descriptionNeedsSave = true
        _ = saveWorkspaceDescription()
    }

    func retrySavingWorkspaceDescription() {
        guard descriptionNeedsSave else { return }
        _ = saveWorkspaceDescription()
    }

    @discardableResult
    private func saveWorkspaceDescription() -> Bool {
        guard let directory = descriptionWorkspace else { return false }
        do {
            try descriptionStore.save(description, workspace: directory)
            descriptionPersistenceError = nil
            descriptionNeedsSave = false
            return true
        } catch {
            descriptionPersistenceError = error.localizedDescription
            descriptionNeedsSave = true
            return false
        }
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
        // The implicit local backend does not write a backend metadata file.
        // Keep malformed or unreadable metadata unknown instead of calling it local.
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            let fileError = error as NSError
            let isMissing = fileError.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(fileError.code)
            backendIdentity = isMissing ? "local" : "unknown backend"
            executionContextDisplay = "Workspace: \(selectedTerraformWorkspace) · Backend: \(backendIdentity)"
            return
        }
        guard let json = try? JSON(data: data),
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
        guard let dir = workingDirectory else {
            hasVariables = false
            return
        }

        // Keep editor-created inputs stable while replacing all file/environment
        // discoveries. This also removes values whose source file was deleted.
        let userVariables = terraformVariables.filter(\.isUserInput)
        let userEnvironmentVariables = environmentVariables.filter(\.isUserInput)
        var discoveredVariables: [TerraformVariable] = []
        let fileManager = FileManager.default
        let textFile = dir.appendingPathComponent("terraform.tfvars")
        if fileManager.fileExists(atPath: textFile.path) {
            discoveredVariables += parseTextVariables(file: textFile)
        }
        let jsonFile = dir.appendingPathComponent("terraform.tfvars.json")
        if fileManager.fileExists(atPath: jsonFile.path) {
            discoveredVariables += parseJSONVariables(file: jsonFile)
        }

        // Keep one display entry per key, with the later-discovered JSON file
        // taking precedence when both conventional tfvars files define it.
        var discoveredByKey: [String: TerraformVariable] = [:]
        for variable in discoveredVariables { discoveredByKey[variable.key] = variable }

        terraformVariables = userVariables + discoveredByKey.values.sorted { $0.key < $1.key }
        environmentVariables = userEnvironmentVariables + parseEnvironmentVariables()
        hasVariables = fileManager.fileExists(atPath: textFile.path)
            || fileManager.fileExists(atPath: jsonFile.path)
    }

    private func parseEnvironmentVariables() -> [EnvironmentVariable] {
        var discovered: [EnvironmentVariable] = []
        for (key, value) in ProcessInfo.processInfo.environment {
            guard key.hasPrefix("TF_VAR_") else { continue }
            let variable = EnvironmentVariable()
            variable.key = key
            variable.value = value
            discovered.append(variable)
        }
        return discovered
    }

    /// Discovers only simple, single-line assignments. This intentionally does
    /// not claim to parse HCL expressions or multiline collections; Terraform
    /// remains the authority for interpreting the original file.
    private func parseTextVariables(file: URL) -> [TerraformVariable] {
        do {
            let vars = try String(contentsOf: file, encoding: .utf8)
            var discovered: [TerraformVariable] = []
            var nestedExpressionDepth = 0
            var blockComment = false
            var heredocTerminator: String?
            for line in vars.split(whereSeparator: \.isNewline) {
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let terminator = heredocTerminator {
                    if trimmed == terminator { heredocTerminator = nil }
                    continue
                }
                if blockComment {
                    guard let end = trimmed.range(of: "*/") else { continue }
                    trimmed = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    blockComment = false
                }
                if trimmed.hasPrefix("/*") {
                    guard let end = trimmed.range(of: "*/", range: trimmed.index(trimmed.startIndex, offsetBy: 2)..<trimmed.endIndex) else {
                        blockComment = true
                        continue
                    }
                    trimmed = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
                if nestedExpressionDepth > 0 {
                    nestedExpressionDepth += expressionDepthDelta(in: trimmed)
                    nestedExpressionDepth = max(0, nestedExpressionDepth)
                    continue
                }
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty else { continue }
                if let markerRange = value.range(of: #"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) {
                    let marker = value[markerRange].replacingOccurrences(of: #"^<<-?\s*"#, with: "", options: .regularExpression)
                    heredocTerminator = marker
                    continue
                }
                let depth = expressionDepthDelta(in: value)
                guard depth == 0 else {
                    nestedExpressionDepth = max(0, depth)
                    continue
                }
                let variable = TerraformVariable()
                variable.key = key
                variable.value = value
                discovered.append(variable)
            }
            return discovered
        } catch {
            print(error.localizedDescription)
            return []
        }
    }

    private func expressionDepthDelta(in text: String) -> Int {
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if "[{(".contains(character) { depth += 1 }
            else if "]})".contains(character) { depth -= 1 }
        }
        return depth
    }

    private func parseJSONVariables(file: URL) -> [TerraformVariable] {
        do {
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return object.keys.sorted().compactMap { key in
                guard let value = object[key] else { return nil }
                let variable = TerraformVariable()
                variable.key = key
                if let string = value as? String, !(value is NSNumber) {
                    variable.value = string
                } else if let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                          let rendered = String(data: encoded, encoding: .utf8) {
                    variable.value = rendered
                    variable.hcl = true
                }
                return variable
            }
        } catch {
            print(error.localizedDescription)
            return []
        }
    }

    private func cleanANSI(_ input: String) -> String {
        stripTerraformTerminalEscapes(input)
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
        validateConfiguration { valid in
            if valid { self.refreshResources() }
        }
    }

    /// Recovery always validates again; it cannot bypass configuration readiness
    /// or reuse the failed run's artifact.
    func validateAndQueueRun(onCreated: (@MainActor @Sendable (UUID) -> Void)? = nil) {
        validateConfiguration { valid in
            if valid { self.queueRun(onCreated: onCreated) }
        }
    }

    private func validateConfiguration(completion: @escaping (Bool) -> Void) {
        guard !rememberedInputLoadFailed else {
            errorMessage = rememberedInputsError ?? "A remembered sensitive input is unavailable."
            completion(false)
            return
        }
        guard !locked, let workingDirectory = self.workingDirectory else { completion(false); return }
        let lease: WorkspaceCommandCoordinator.Lease
        do { lease = try acquireCommandLease() }
        catch { errorMessage = error.localizedDescription; completion(false); return }
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
            }
            self.objectWillChange.send()
            completion(error == nil && res != nil)
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
        errorMessage = nil
        lock()
        
        let redactor = SensitiveInputRedactor(variables: terraformVariables, environmentVariables: environmentVariables)
        activeCommand = runner.show(workingDirectory: workingDirectory, completion: { res, error in
            self.finishCommand()
            self.unlock()
            lease.release()
            
            if let res = res {
                guard let data = res.data(using: .utf8), let json = try? JSON(data: data),
                      let object = json.dictionary else {
                    self.errorMessage = "Terraform returned malformed state data."
                    return
                }
                if json["values"].dictionary != nil, json["values"]["root_module"].dictionary != nil {
                    self.state = transformShow(json)
                    self.hasState = true
                    self.isValid = true
                } else if json["values"].exists() == false,
                          json["format_version"].string != nil,
                          object.keys.allSatisfy({ ["format_version", "terraform_version"].contains($0) }) {
                    // `terraform show -json` succeeds in a fresh local workspace and
                    // returns only format_version (and optionally terraform_version).
                    // That is a valid empty state, not an error.
                    self.state = nil
                    self.hasState = false
                } else {
                    self.state = nil
                    self.hasState = false
                    self.errorMessage = "Terraform returned malformed state data."
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
        if self.autoApply && !rememberedInputLoadFailed {
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
        guard !locked, workingDirectory != nil else { return }
        guard retryUnsavedRuns() else { return }
        loadRunHistoryPage(offset: 0)
    }

    func loadNextRunHistoryPage() {
        guard !locked, !historyLoading, historyError == nil,
              historyPageOffset + historyPageSize < historyTotalCount else { return }
        loadRunHistoryPage(offset: historyPageOffset + historyPageSize)
    }

    func loadPreviousRunHistoryPage() {
        guard !locked, !historyLoading, historyError == nil, historyPageOffset > 0 else { return }
        loadRunHistoryPage(offset: max(0, historyPageOffset - historyPageSize))
    }

    private func loadRunHistoryPage(offset: Int) {
        guard let directory = workingDirectory else { return }
        let requestID = UUID()
        historyRequestID = requestID
        historyLoading = true
        historyError = nil
        let store = historyStore
        let limit = historyPageSize
        let unsavedIDs = Set(unsavedRuns.keys)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.loadPage(workspace: directory, offset: offset, limit: limit) }
            DispatchQueue.main.async {
                guard self.historyRequestID == requestID,
                      self.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
                self.historyLoading = false
                switch result {
                case .success(let page):
                    // Keep this session's active runs visible; finished records follow the selected page.
                    let live = self.runs.filter { !$0.isPersisted || !$0.isFinished || $0.status == .interrupted || unsavedIDs.contains($0.id) }
                    let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
                    let restored = page.records.map { liveByID[$0.id] ?? TerraformRun(workspace: self, record: $0, restored: true) }
                    let pageIDs = Set(page.records.map(\.id))
                    self.runs = restored + live.filter { !pageIDs.contains($0.id) }
                    self.historyPageOffset = page.offset
                    self.historyTotalCount = page.totalCount
                    self.historyError = nil
                case .failure(let error):
                    self.historyError = error.localizedDescription
                }
            }
        }
    }

    func deleteSavedRun(_ id: UUID) {
        guard !locked, let directory = workingDirectory,
              historyError == nil, unsavedRuns[id] == nil,
              let selectedRun = runs.first(where: { $0.id == id }),
              selectedRun.isPersisted, Self.isCompletedDeletableRun(selectedRun.status) else { return }
        let protectedIDs = Set(runs.filter { !$0.isPersisted || !$0.isFinished || $0.status == .interrupted }.map(\.id)).union(unsavedRuns.keys)
        let store = historyStore
        let requestID = UUID()
        historyRequestID = requestID
        historyLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.delete(workspace: directory, id: id, protecting: protectedIDs) }
            DispatchQueue.main.async {
                guard self.historyRequestID == requestID,
                      self.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
                self.historyLoading = false
                switch result {
                case .success:
                    self.runs.removeAll { $0.id == id }
                    self.historyError = nil
                    self.reloadRunHistory()
                case .failure(let error): self.historyError = error.localizedDescription
                }
            }
        }
    }

    func applyRunHistoryRetention(days: Int) {
        guard !locked, historyError == nil, unsavedRuns.isEmpty, let directory = workingDirectory else { return }
        let protectedIDs = Set(runs.filter { !$0.isPersisted || !$0.isFinished || $0.status == .interrupted }.map(\.id)).union(unsavedRuns.keys)
        let store = historyStore
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: Date()) ?? Date()
        let requestID = UUID()
        historyRequestID = requestID
        historyLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let ids = try store.retentionCandidates(workspace: directory, before: cutoff, protecting: protectedIDs)
                try store.delete(workspace: directory, ids: ids, protecting: protectedIDs)
                return ids
            }
            DispatchQueue.main.async {
                guard self.historyRequestID == requestID,
                      self.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
                self.historyLoading = false
                switch result {
                case .success(let ids):
                    self.runs.removeAll { ids.contains($0.id) }
                    self.reloadRunHistory()
                case .failure(let error): self.historyError = error.localizedDescription
                }
            }
        }
    }

    func exportSavedRun(_ id: UUID, to destination: URL) {
        guard historyError == nil, unsavedRuns[id] == nil, let directory = workingDirectory,
              runs.first(where: { $0.id == id })?.isPersisted == true else { return }
        let store = historyStore
        let requestID = UUID()
        historyActionRequestID = requestID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.export(id: id, workspace: directory, to: destination) }
            DispatchQueue.main.async {
                guard self.historyActionRequestID == requestID,
                      self.workingDirectory.map(RunHistoryStore.workspacePath) == RunHistoryStore.workspacePath(directory) else { return }
                if case .failure(let error) = result { self.historyError = "Run export failed. \(error.localizedDescription)" }
            }
        }
    }

    private static func isCompletedDeletableRun(_ status: RunStatus) -> Bool {
        [.applied, .discarded, .errored, .canceled, .expired].contains(status)
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

    func queueRun(_ message: String? = nil, onCreated: (@MainActor @Sendable (UUID) -> Void)? = nil) {
        guard !locked, !historyLoading, isValid, historyError == nil,
              !rememberedInputLoadFailed, let directory = workingDirectory else { return }
        refreshExecutionContext()
        let canonicalDirectory = RunHistoryStore.workspacePath(directory)
        let terraformVersion = self.terraformVersion
        let selectedTerraformWorkspace = self.selectedTerraformWorkspace
        let backendIdentity = self.backendIdentity
        let executionContext = executionContextIdentifier
        let store = historyStore
        let pageLimit = historyPageSize
        let requestID = UUID()
        historyRequestID = requestID
        historyLoading = true
        lock()

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(RunRecord, RunHistoryStore.Page), Error> = Result {
                let record = try store.create(workspace: directory, terraformVersion: terraformVersion, message: message,
                                              selectedTerraformWorkspace: selectedTerraformWorkspace, backendIdentity: backendIdentity)
                do {
                    let page = try store.loadPage(workspace: directory, offset: 0, limit: pageLimit)
                    return (record, page)
                } catch {
                    var retiredRecord = record
                    retiredRecord.status = .canceled
                    retiredRecord.updatedAt = max(Date(), record.createdAt.addingTimeInterval(0.001))
                    try? store.save(retiredRecord, workspace: directory)
                    throw error
                }
            }
            DispatchQueue.main.async {
                guard self.historyRequestID == requestID else {
                    if case .success(let (record, _)) = result {
                        DispatchQueue.global(qos: .utility).async {
                            var retiredRecord = record
                            retiredRecord.status = .canceled
                            retiredRecord.updatedAt = max(Date(), record.createdAt.addingTimeInterval(0.001))
                            try? store.save(retiredRecord, workspace: directory)
                        }
                    }
                    return
                }
                let contextIsCurrent = self.workingDirectory.map(RunHistoryStore.workspacePath) == canonicalDirectory
                    && self.terraformVersion == terraformVersion
                    && self.executionContextIdentifier == executionContext
                    && self.isValid
                guard contextIsCurrent else {
                    self.historyLoading = false
                    self.unlock()
                    if case .success(let (record, _)) = result {
                        DispatchQueue.global(qos: .utility).async {
                            var retiredRecord = record
                            retiredRecord.status = .canceled
                            retiredRecord.updatedAt = max(Date(), record.createdAt.addingTimeInterval(0.001))
                            try? store.save(retiredRecord, workspace: directory)
                        }
                    }
                    return
                }
                self.historyLoading = false
                self.unlock()
                switch result {
                case .success(let (record, page)):
                    self.historyError = nil
                    let run = TerraformRun(workspace: self, record: record, restored: false)
                    let retained = self.runs.filter {
                        !$0.isRestored && (!$0.isPersisted || !$0.isFinished || $0.status == .interrupted || self.unsavedRuns[$0.id] != nil)
                    }
                    let retainedByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
                    let pageRuns = page.records.map { pageRecord in
                        pageRecord.id == record.id ? run : (retainedByID[pageRecord.id] ?? TerraformRun(workspace: self, record: pageRecord, restored: true))
                    }
                    let pageIDs = Set(page.records.map(\.id))
                    self.runs = pageRuns + retained.filter { !pageIDs.contains($0.id) }
                    self.historyPageOffset = page.offset
                    self.historyTotalCount = page.totalCount
                    onCreated?(run.id)
                    run.doPlan { _, _ in }
                case .failure(let error):
                    self.historyError = "Cannot start a run until its history can be saved. \(error.localizedDescription)"
                }
            }
        }
    }

    func addTerraformVariable(_ variable: TerraformVariable) throws {
        guard !terraformVariables.contains(where: { $0 === variable }) else { return }
        try variable.validate()
        guard !terraformVariables.contains(where: { $0.isUserInput && $0.key == variable.key }) else {
            throw VariableInputError.duplicateKey(variable.key)
        }
        try retirePlansForInputChange()
        variable.isUserInput = true
        terraformVariables.append(variable)
        if variable.isRemembered {
            do { try persistRememberedInputs() }
            catch { terraformVariables.removeAll { $0 === variable }; throw error }
        }
    }

    func updateTerraformVariable(_ existing: TerraformVariable, key: String, value: String,
                                 description: String, sensitive: Bool, hcl: Bool, remember: Bool? = nil) throws {
        guard existing.isUserInput, terraformVariables.contains(where: { $0 === existing }) else { return }
        let draft = TerraformVariable()
        draft.key = key; draft.value = value; draft.description = description
        draft.sensitive = sensitive; draft.hcl = hcl
        try draft.validate()
        guard !terraformVariables.contains(where: { $0 !== existing && $0.isUserInput && $0.key == key }) else {
            throw VariableInputError.duplicateKey(key)
        }
        if existing.rememberedSecretUnavailable && value.isEmpty { throw WorkspaceInputStoreError.missingSecret(key) }
        let changesEffectiveInput = existing.key != key || existing.value != value
            || existing.sensitive != sensitive || existing.hcl != hcl
        if changesEffectiveInput { try retirePlansForInputChange() }
        let old = (existing.key, existing.value, existing.description, existing.sensitive, existing.hcl, existing.isRemembered, existing.rememberedSecretUnavailable, existing.rememberedSecretID)
        existing.key = key; existing.value = value; existing.description = description
        let shouldRemember = remember ?? old.5
        existing.sensitive = sensitive; existing.hcl = hcl; existing.isRemembered = shouldRemember
        existing.rememberedSecretUnavailable = false; existing.rememberedSecretID = nil
        if old.5 || shouldRemember {
            do { try persistRememberedInputs() }
            catch { existing.key = old.0; existing.value = old.1; existing.description = old.2; existing.sensitive = old.3; existing.hcl = old.4; existing.isRemembered = old.5; existing.rememberedSecretUnavailable = old.6; existing.rememberedSecretID = old.7; throw error }
        }
    }

    func removeTerraformVariable(_ variable: TerraformVariable) throws {
        guard variable.isUserInput, terraformVariables.contains(where: { $0 === variable }) else { return }
        try retirePlansForInputChange()
        terraformVariables.removeAll { $0 === variable }
        if variable.isRemembered {
            do { try persistRememberedInputs() }
            catch { terraformVariables.append(variable); throw error }
        }
    }

    func addEnvironmentVariable(_ variable: EnvironmentVariable) throws {
        guard !environmentVariables.contains(where: { $0 === variable }) else { return }
        try variable.validate()
        guard !environmentVariables.contains(where: { $0.isUserInput && $0.key == variable.key }) else {
            throw VariableInputError.duplicateKey(variable.key)
        }
        try retirePlansForInputChange()
        variable.isUserInput = true
        environmentVariables.append(variable)
        if variable.isRemembered {
            do { try persistRememberedInputs() }
            catch { environmentVariables.removeAll { $0 === variable }; throw error }
        }
    }

    func updateEnvironmentVariable(_ existing: EnvironmentVariable, key: String, value: String,
                                   description: String, sensitive: Bool, remember: Bool? = nil) throws {
        guard existing.isUserInput, environmentVariables.contains(where: { $0 === existing }) else { return }
        let draft = EnvironmentVariable()
        draft.key = key; draft.value = value; draft.description = description
        try draft.validate()
        guard !environmentVariables.contains(where: { $0 !== existing && $0.isUserInput && $0.key == key }) else {
            throw VariableInputError.duplicateKey(key)
        }
        if existing.rememberedSecretUnavailable && value.isEmpty { throw WorkspaceInputStoreError.missingSecret(key) }
        if existing.key != key || existing.value != value || existing.sensitive != sensitive {
            try retirePlansForInputChange()
        }
        let old = (existing.key, existing.value, existing.description, existing.sensitive, existing.isRemembered, existing.rememberedSecretUnavailable, existing.rememberedSecretID)
        existing.key = key; existing.value = value; existing.description = description
        let shouldRemember = remember ?? old.4
        existing.sensitive = sensitive; existing.isRemembered = shouldRemember
        existing.rememberedSecretUnavailable = false; existing.rememberedSecretID = nil
        if old.4 || shouldRemember {
            do { try persistRememberedInputs() }
            catch { existing.key = old.0; existing.value = old.1; existing.description = old.2; existing.sensitive = old.3; existing.isRemembered = old.4; existing.rememberedSecretUnavailable = old.5; existing.rememberedSecretID = old.6; throw error }
        }
    }

    func removeEnvironmentVariable(_ variable: EnvironmentVariable) throws {
        guard variable.isUserInput, environmentVariables.contains(where: { $0 === variable }) else { return }
        try retirePlansForInputChange()
        environmentVariables.removeAll { $0 === variable }
        if variable.isRemembered {
            do { try persistRememberedInputs() }
            catch { environmentVariables.append(variable); throw error }
        }
    }

    private func retirePlansForInputChange() throws {
        guard !locked else { throw WorkspaceCommandCoordinator.CoordinatorError.busy }
        let lease = try acquireCommandLease()
        defer { lease.release() }
        try lease.invalidatePlans()
        for run in runs { run.doDiscard() }
    }
}
