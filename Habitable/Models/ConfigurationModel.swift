import Foundation
import SwiftUI
import AppKit
import Darwin

struct ConfigurationFile: Identifiable, Hashable, Sendable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct ConfigurationDiagnostic: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let file: String?
    let line: Int?
    let severity: Severity

    enum Severity: Hashable { case error, warning }
}

final class TerraformFormatOperation: @unchecked Sendable {
    private let executable: URL
    private let source: String
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval

    init(executable: URL, source: String, timeout: TimeInterval = 15, terminationGrace: TimeInterval = 0.5) {
        self.executable = executable
        self.source = source
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    func run() throws -> (Int32, String, Bool, Bool, Bool, String, Bool) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let input = Pipe()
        let outputCollector = BoundedFormatOutput(limit: 1_048_576)
        let errorCollector = BoundedFormatOutput(limit: 1_048_576)
        process.executableURL = executable
        process.arguments = ["fmt", "-"]
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = input
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outputCollector.finish()
                handle.readabilityHandler = nil
            }
            else { outputCollector.append(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errorCollector.finish()
                handle.readabilityHandler = nil
            }
            else { errorCollector.append(data) }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        // A terminated formatter closes stdin while the background writer may still
        // be writing. Keep EPIPE local to this descriptor instead of terminating the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let writer = TerraformFormatInputWriter(handle: input.fileHandleForWriting, data: Data(source.utf8))
        writer.start()
        var timedOut = false
        while process.isRunning {
            if outputCollector.exceededLimit || errorCollector.exceededLimit || Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if timedOut {
            let terminationDeadline = Date().addingTimeInterval(terminationGrace)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let stdoutClosed = outputCollector.waitForClose(timeout: 0.5)
        let stderrClosed = errorCollector.waitForClose(timeout: 0.5)
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        let exceeded = outputCollector.exceededLimit
        return (process.terminationStatus, outputCollector.string, timedOut && !exceeded && !errorCollector.exceededLimit,
                exceeded, !(stdoutClosed && stderrClosed), errorCollector.string, errorCollector.exceededLimit)
    }
}

private final class TerraformFormatInputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let data: Data
    init(handle: FileHandle, data: Data) { self.handle = handle; self.data = data }
    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

private final class BoundedFormatOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let closeSignal = DispatchSemaphore(value: 0)
    private var storage = Data()
    private var didExceedLimit = false
    private var closed = false

    init(limit: Int) { self.limit = limit }
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return didExceedLimit }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: storage, as: UTF8.self) }

    func finish() {
        lock.lock()
        let shouldSignal = !closed
        closed = true
        lock.unlock()
        if shouldSignal { closeSignal.signal() }
    }

    func waitForClose(timeout: TimeInterval) -> Bool {
        if exceededOrClosed { return true }
        return closeSignal.wait(timeout: .now() + timeout) == .success
    }

    private var exceededOrClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - storage.count)
        storage.append(data.prefix(remaining))
        if data.count > remaining { didExceedLimit = true }
    }
}

enum ConfigurationValidationActivity { case idle, scheduled, running }

@MainActor
final class ConfigurationModel: ObservableObject {
    @Published private(set) var files: [ConfigurationFile] = []
    @Published var selectedFile: ConfigurationFile? {
        didSet {
            if selectedFile != oldValue {
                cancelAutoValidation()
                loadSelectedFile()
            }
        }
    }
    @Published var draft = ""
    @Published var editorSelection = NSRange(location: 0, length: 0)
    @Published private(set) var savedText: String?
    @Published private(set) var diskChanged = false
    @Published private(set) var diagnostics: [ConfigurationDiagnostic] = []
    @Published var message: String?
    @Published private(set) var validationActivity: ConfigurationValidationActivity = .idle
    @Published private(set) var isFormatting = false
    @Published private(set) var isWatching = false
    @Published private(set) var isWorkspaceSwitchPending = false

    private weak var workspace: Workspace?
    private var attachedDirectory: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var isVisible = false
    private var autoValidationTask: Task<Void, Never>?
    private var autoValidationCommandRunning = false
    private var externalInvalidationTask: Task<Void, Never>?
    private var externalInvalidationPending = false
    private var autoValidationID = UUID()
    private var fileRefreshID = UUID()

    var hasUnsavedChanges: Bool { savedText.map { $0 != draft } ?? false }
    var hasConflict: Bool { diskChanged && hasUnsavedChanges }
    var canSaveInCurrentWorkspace: Bool {
        guard let current = workspace?.workingDirectory, let attachedDirectory else { return false }
        return canonicalPath(current) == canonicalPath(attachedDirectory)
    }
    var canFormatCurrentFile: Bool { selectedFile.map { $0.name.hasSuffix(".tf") && !$0.name.hasSuffix(".tf.json") } ?? false }

    func attach(to workspace: Workspace) {
        let newDirectory = workspace.workingDirectory
        if self.workspace === workspace, attachedDirectory == newDirectory, !isWorkspaceSwitchPending {
            refreshFilesInBackground()
            return
        }
        if let attachedDirectory, canonicalPath(attachedDirectory) != newDirectory.map(canonicalPath),
           hasUnsavedChanges {
            cancelValidationWork(clearExternalInvalidation: true)
            self.workspace = workspace
            isWorkspaceSwitchPending = true
            message = "The workspace changed while this file had unsaved edits. Return to the original folder to save them, or discard them to continue here."
            return
        }
        if self.workspace !== workspace || attachedDirectory.map(canonicalPath) != newDirectory.map(canonicalPath) {
            cancelValidationWork(clearExternalInvalidation: true)
            stopWatching()
            selectedFile = nil
        }
        self.workspace = workspace
        attachedDirectory = newDirectory
        isWorkspaceSwitchPending = false
        refreshFiles()
        if selectedFile == nil || !files.contains(selectedFile!) { selectedFile = files.first }
        startWatching()
    }

    func discardAndSwitchWorkspace() {
        guard let workspace else { return }
        cancelValidationWork(clearExternalInvalidation: true)
        draft = ""
        savedText = nil
        diskChanged = false
        selectedFile = nil
        attachedDirectory = workspace.workingDirectory
        isWorkspaceSwitchPending = false
        refreshFiles()
        selectedFile = files.first
        message = nil
        startWatching()
    }

    func keepEditingPreviousWorkspace() {
        isWorkspaceSwitchPending = false
        message = "Edits remain open from the previous folder. Return to that folder to save them."
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if !visible {
            cancelAutoValidation()
        }
    }

    func refreshFiles() {
        guard let directory = workspace?.workingDirectory else { files = []; selectedFile = nil; return }
        fileRefreshID = UUID()
        applyFiles(Self.scanFiles(in: directory))
    }

    private func refreshFilesInBackground() {
        guard let directory = workspace?.workingDirectory else { return }
        let id = UUID()
        fileRefreshID = id
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Self.scanFiles(in: directory) }.value
            guard let self, self.fileRefreshID == id, self.attachedDirectory == directory,
                  self.workspace?.workingDirectory == directory else { return }
            self.applyFiles(found)
        }
    }

    nonisolated private static func scanFiles(in directory: URL) -> [ConfigurationFile] {
        let found = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory != true, values.isSymbolicLink != true else { return false }
                return url.lastPathComponent.hasSuffix(".tf") || url.lastPathComponent.hasSuffix(".tf.json")
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return found.map(ConfigurationFile.init(url:))
    }

    private func applyFiles(_ found: [ConfigurationFile]) {
        if files != found { files = found }
        if let selectedFile, !found.contains(selectedFile) {
            if hasUnsavedChanges {
                diskChanged = true
                message = "The open file was removed or renamed outside Habitable. Copy your edits before closing this file."
            } else {
                self.selectedFile = files.first
            }
        }
    }

    func file(matching sourcePath: String) -> ConfigurationFile? {
        let cleaned = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.contains("/") {
            if let directory = attachedDirectory {
                let relative = URL(fileURLWithPath: cleaned, relativeTo: directory).standardizedFileURL.path
                return files.first { $0.url.standardizedFileURL.path == relative || $0.url.path.hasSuffix("/" + cleaned) }
            }
        }
        return files.first { $0.name == cleaned }
    }

    func insertVariableReference(_ name: String) {
        let source = draft as NSString
        let cursor = min(max(0, editorSelection.location), source.length)
        let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
        let prefix = source.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
        let expression = try? NSRegularExpression(pattern: #"\bvar\.[A-Za-z0-9_-]*$"#)
        let match = expression?.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length))
        let replacementRange = match.map { NSRange(location: lineRange.location + $0.range.location, length: $0.range.length) }
            ?? NSRange(location: cursor, length: min(editorSelection.length, source.length - cursor))
        let reference = "var.\(name)"
        let updated = source.replacingCharacters(in: replacementRange, with: reference)
        editorSelection = NSRange(location: replacementRange.location + (reference as NSString).length, length: 0)
        draft = updated
    }

    func save() {
        guard let workspace, let selectedFile, hasUnsavedChanges else { return }
        _ = saveSource(draft, to: selectedFile, expectedText: savedText, workspace: workspace,
                       status: "Saved.")
    }

    func formatAndSave() {
        guard let workspace, let selectedFile, let baseline = savedText else {
            message = "Open a readable Terraform file before formatting it."; return
        }
        guard canSaveInCurrentWorkspace else { message = "Return to the folder containing this file before formatting and saving."; return }
        guard !workspace.locked else { message = "Wait for the current Terraform command to finish before formatting."; return }
        guard canFormatCurrentFile else { message = "Terraform's formatter handles HCL .tf files. JSON configuration files are not changed."; return }
        guard !hasConflict else { message = "This file changed outside Habitable. Reload it before formatting to avoid replacing that change."; return }
        guard !isFormatting else { return }
        guard draft.utf8.count <= 1_048_576 else { message = "Formatting is limited to files under 1 MB."; return }
        guard isSafeWorkspaceFile(selectedFile.url, in: workspace.workingDirectory) else {
            message = "This file is no longer a regular configuration file inside the selected workspace."; return
        }
        isFormatting = true
        message = "Formatting the current editor text…"
        let source = draft
        let file = selectedFile
        let directory = attachedDirectory
        guard let executable = workspace.runner.executableURL else {
            isFormatting = false
            message = "Terraform CLI is unavailable. Select an installed Terraform version first."
            return
        }
        let operation = TerraformFormatOperation(executable: executable, source: source)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak workspace] in
            do {
                let result = try operation.run()
                Task { @MainActor in
                    guard let self, let workspace else { return }
                    self.isFormatting = false
                    guard self.selectedFile == file, self.draft == source, self.savedText == baseline,
                          self.attachedDirectory.map(self.canonicalPath) == directory.map(self.canonicalPath),
                          workspace.workingDirectory.map(self.canonicalPath) == directory.map(self.canonicalPath) else {
                        self.message = "Formatting finished after the file or workspace changed. No formatted text was saved."
                        return
                    }
                    let (status, formatted, timedOut, stdoutTooLarge, outputDidNotClose, warnings, stderrTooLarge) = result
                    guard !timedOut, !stdoutTooLarge, !stderrTooLarge, !outputDidNotClose, status == 0 else {
                        self.message = timedOut ? "Formatting stopped after 15 seconds. No file was changed." :
                            stdoutTooLarge || stderrTooLarge ? "Terraform output exceeded 1 MB. No file was changed." :
                            outputDidNotClose ? "Formatting output did not close after Terraform exited. No file was changed." :
                            "Terraform could not format this file. No file was changed. \(warnings)"
                        return
                    }
                    guard formatted.utf8.count <= 1_048_576 else {
                        self.message = "Formatted output exceeded 1 MB. No file was changed."; return
                    }
                    if self.saveSource(formatted, to: file, expectedText: baseline, workspace: workspace,
                                       status: warnings.isEmpty
                                        ? "Formatted and saved."
                                        : "Formatted and saved. Terraform reported: \(warnings)") {
                        self.editorSelection = NSRange(location: (formatted as NSString).length, length: 0)
                    }
                }
            } catch {
                Task { @MainActor in
                    self?.isFormatting = false
                    self?.message = "Could not run terraform fmt: \(error.localizedDescription). No file was changed."
                }
            }
        }
    }

    private func saveSource(_ source: String, to file: ConfigurationFile, expectedText: String?,
                            workspace: Workspace, status: String) -> Bool {
        guard canSaveInCurrentWorkspace else { message = "Return to the folder containing this file before saving."; return false }
        guard !workspace.locked else { message = "Wait for the current Terraform command to finish before saving."; return false }
        guard let expectedText else { message = "The original file contents are unavailable. Reload the file before saving."; return false }
        do {
            guard isSafeWorkspaceFile(file.url, in: workspace.workingDirectory) else {
                message = "This file is no longer a regular configuration file inside the selected workspace."; return false
            }
            let data = Data(source.utf8)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var saveError: Error?
            coordinator.coordinate(writingItemAt: file.url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    guard isSafeWorkspaceFile(coordinatedURL, in: workspace.workingDirectory) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    let current = try readEditableFile(coordinatedURL)
                    guard current == expectedText else { throw ConfigurationSaveError.externalChange }
                    try data.write(to: coordinatedURL, options: .atomic)
                } catch { saveError = error }
            }
            if let coordinationError { throw coordinationError }
            if let saveError { throw saveError }
            workspace.isValid = false
            do { try workspace.configurationDidSave() }
            catch {
                savedText = source
                draft = source
                diskChanged = false
                workspace.isValid = false
                message = "The file was saved, but Habitable could not safely invalidate existing plans: \(error.localizedDescription)"
                return false
            }
            savedText = source
            draft = source
            diskChanged = false
            message = status
            if isVisible {
                scheduleAutoValidation(for: file, workspace: workspace)
            } else {
                message = "\(status) Run Validate when ready."
            }
            return true
        } catch {
            if error as? ConfigurationSaveError == .externalChange {
                diskChanged = true
                message = "This file changed outside Habitable. Reload it before saving to avoid overwriting that change."
                return false
            }
            message = "Could not save this file: \(error.localizedDescription)"
            return false
        }
    }

    func reloadFromDisk() {
        guard let file = selectedFile, let workspace, let baseline = savedText else { return }
        do {
            let diskText = try readEditableFile(file.url)
            draft = diskText
            savedText = diskText
            diskChanged = false
            if diskText != baseline { handleExternalSavedChange(file: file, workspace: workspace) }
            else { message = "Reloaded the saved configuration from disk." }
        } catch { message = "Could not reload this file: \(error.localizedDescription)" }
    }

    private func scheduleAutoValidation(for file: ConfigurationFile, workspace: Workspace) {
        cancelAutoValidation()
        guard isVisible, !externalInvalidationPending,
              let directory = attachedDirectory,
              canonicalPath(workspace.workingDirectory ?? URL(fileURLWithPath: "/")) == canonicalPath(directory) else { return }
        validationActivity = .scheduled
        let requestID = autoValidationID
        let savedSource = savedText
        autoValidationTask = Task { [weak self, weak workspace] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, let workspace, self.isCurrentValidation(requestID, file: file, workspace: workspace,
                directory: directory, savedSource: savedSource) else { return }
            while workspace.locked {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard self.isCurrentValidation(requestID, file: file, workspace: workspace,
                    directory: directory, savedSource: savedSource) else { return }
            }
            guard self.isCurrentValidation(requestID, file: file, workspace: workspace,
                directory: directory, savedSource: savedSource) else { return }
            self.validationActivity = .running
            self.message = nil
            self.autoValidationCommandRunning = true
            workspace.validate()
            while workspace.locked {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard self.isCurrentValidation(requestID, file: file, workspace: workspace,
                    directory: directory, savedSource: savedSource) else { return }
            }
            self.autoValidationCommandRunning = false
            guard self.isCurrentValidation(requestID, file: file, workspace: workspace,
                directory: directory, savedSource: savedSource) else { return }
            self.validationActivity = .idle
            self.autoValidationTask = nil
        }
    }

    private func isCurrentValidation(_ id: UUID, file: ConfigurationFile, workspace: Workspace,
                                     directory: URL, savedSource: String?) -> Bool {
        !Task.isCancelled && autoValidationID == id && isVisible && !externalInvalidationPending &&
            selectedFile == file && savedText == savedSource &&
            canonicalPath(attachedDirectory ?? URL(fileURLWithPath: "/")) == canonicalPath(directory) &&
            canonicalPath(workspace.workingDirectory ?? URL(fileURLWithPath: "/")) == canonicalPath(directory)
    }

    private func cancelAutoValidation() {
        autoValidationID = UUID()
        autoValidationTask?.cancel()
        autoValidationTask = nil
        if autoValidationCommandRunning, let workspace, workspace.locked { workspace.cancelCommand() }
        autoValidationCommandRunning = false
        validationActivity = .idle
    }

    private func cancelValidationWork(clearExternalInvalidation: Bool) {
        cancelAutoValidation()
        if clearExternalInvalidation {
            externalInvalidationTask?.cancel()
            externalInvalidationTask = nil
            externalInvalidationPending = false
        }
    }

    private func handleExternalSavedChange(file: ConfigurationFile, workspace: Workspace, shouldValidate: Bool = true) {
        workspace.isValid = false
        externalInvalidationPending = true
        externalInvalidationTask?.cancel()
        let directory = attachedDirectory
        externalInvalidationTask = Task { [weak self, weak workspace] in
            guard let self, let workspace, let directory else { return }
            while workspace.locked {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled,
                      self.canonicalPath(self.attachedDirectory ?? URL(fileURLWithPath: "/")) == self.canonicalPath(directory),
                      self.canonicalPath(workspace.workingDirectory ?? URL(fileURLWithPath: "/")) == self.canonicalPath(directory) else { return }
            }
            guard !Task.isCancelled,
                  self.canonicalPath(self.attachedDirectory ?? URL(fileURLWithPath: "/")) == self.canonicalPath(directory),
                  self.canonicalPath(workspace.workingDirectory ?? URL(fileURLWithPath: "/")) == self.canonicalPath(directory) else { return }
            do {
                // A validation already in flight may have completed while this
                // external edit was waiting for the workspace command lock.
                // Clear that result again before invalidating plans for the new
                // saved configuration.
                workspace.isValid = false
                try workspace.configurationDidSave()
                self.externalInvalidationPending = false
                self.externalInvalidationTask = nil
                guard shouldValidate, self.isVisible, self.selectedFile == file else {
                    self.message = "A saved configuration file changed outside Habitable. Existing plans were invalidated."
                    return
                }
                self.scheduleAutoValidation(for: file, workspace: workspace)
            } catch {
                self.externalInvalidationPending = false
                self.externalInvalidationTask = nil
                self.message = "A saved configuration file changed outside Habitable, but existing plans could not be invalidated safely: \(error.localizedDescription)"
            }
        }
    }

    func readDiagnostics(from output: String?) {
        guard let output, !output.isEmpty else { diagnostics = []; return }
        let pattern = #"(?m)^\s*(?:╷\s*\n\s*│\s*)?(?:Error|Warning):\s*(.*?)(?:\n|$)"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let ns = output as NSString
        let matches = expression?.matches(in: output, range: NSRange(location: 0, length: ns.length)) ?? []
        diagnostics = matches.map { match in
            let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippetStart = match.range.location + match.range.length
            let remaining = ns.substring(from: snippetStart)
            let nextHeading = (try? NSRegularExpression(pattern: #"(?m)^\s*(?:Error|Warning):"#))?
                .firstMatch(in: remaining, range: NSRange(location: 0, length: (remaining as NSString).length))
            let snippetLength = min(1400, nextHeading?.range.location ?? ns.length - snippetStart)
            let snippet = ns.substring(with: NSRange(location: snippetStart, length: max(0, snippetLength)))
            let sourcePattern = #"(?m) on ([^\n:]+\.tf(?:\.json)? line (\d+))"#
            let source = (try? NSRegularExpression(pattern: sourcePattern))?.firstMatch(in: snippet, range: NSRange(location: 0, length: (snippet as NSString).length))
            let sourceNS = snippet as NSString
            var file: String?
            var line: Int?
            if let source {
                let value = sourceNS.substring(with: source.range(at: 1))
                let parts = value.components(separatedBy: " line ")
                file = parts.first
                line = Int(sourceNS.substring(with: source.range(at: 2)))
            }
            return ConfigurationDiagnostic(message: title, file: file, line: line,
                severity: ns.substring(with: match.range).contains("Warning:") ? .warning : .error)
        }
    }

    private func readEditableFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximumBytes = 1_048_576
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationEditorReadError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    private func loadSelectedFile() {
        guard let selectedFile else { draft = ""; savedText = nil; stopWatching(); return }
        do {
            let text = try readEditableFile(selectedFile.url)
            draft = text
            savedText = text
            diskChanged = false
            message = nil
            startWatching()
        } catch {
            draft = ""
            savedText = nil
            message = "Could not read this file: \(error.localizedDescription)"
        }
    }

    private func startWatching() {
        stopWatching()
        guard let url = selectedFile?.url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let url = self.selectedFile?.url else { return }
            guard let file = self.selectedFile, let workspace = self.workspace else { self.startWatching(); return }
            if let text = try? self.readEditableFile(url) {
                if text == self.savedText {
                    self.diskChanged = false
                } else if !self.hasUnsavedChanges || text == self.draft {
                    self.draft = text
                    self.savedText = text
                    self.diskChanged = false
                    self.message = "A saved file changed outside Habitable. Checking the saved on-disk configuration."
                    self.handleExternalSavedChange(file: file, workspace: workspace)
                } else {
                    self.diskChanged = true
                    workspace.isValid = false
                    self.message = "This file changed outside Habitable. Your editor draft is preserved; reload or resolve the conflict before saving."
                    self.handleExternalSavedChange(file: file, workspace: workspace)
                }
            } else {
                self.diskChanged = true
                workspace.isValid = false
                self.message = "The saved configuration changed outside Habitable but cannot be read in the editor. Existing plans will be invalidated."
                self.handleExternalSavedChange(file: file, workspace: workspace, shouldValidate: false)
            }
            self.startWatching()
        }
        source.setCancelHandler { close(fd) }
        watcher = source
        isWatching = true
        source.resume()
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedDescriptor = -1
        isWatching = false
    }

    deinit { watcher?.cancel() }

    private func isSafeWorkspaceFile(_ file: URL, in directory: URL?) -> Bool {
        guard let directory else { return false }
        let folder = canonicalPath(directory)
        let candidate = file.standardizedFileURL
        guard canonicalPath(candidate.deletingLastPathComponent()) == folder,
              candidate.path.hasSuffix(".tf") || candidate.path.hasSuffix(".tf.json"),
              let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory != true, values.isSymbolicLink != true else { return false }
        return true
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private enum ConfigurationSaveError: Error, Equatable { case externalChange }

struct StarterConfiguration {
    let title: String
    let files: [(String, String)]

    static let local = StarterConfiguration(title: "Local learning example", files: [
        ("main.tf", """
terraform {
  required_version = ">= 1.5.0"
}

variable "message" {
  description = "A message to store in this local example."
  type        = string
  default     = "Hello, Terraform"
}

resource "terraform_data" "example" {
  input = var.message
}

output "message" {
  value = terraform_data.example.output
}
""")
    ])
}

private enum ConfigurationEditorReadError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "The in-app editor supports files up to 1 MB. Open this file in your external editor." }
}
