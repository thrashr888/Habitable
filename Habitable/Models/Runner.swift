import Darwin
import Foundation

enum TerraformOutputStream: Equatable, Sendable {
    case stdout
    case stderr
}

func stripTerraformTerminalEscapes(_ text: String) -> String {
    let patterns = [
        #"\x1B\][\s\S]*?(?:\x07|\x1B\\|\x9C)"#, // OSC
        #"\x1B[P^_][\s\S]*?(?:\x1B\\|\x9C)"#, // DCS, PM, APC
        #"(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]"#, // CSI
        #"\x1B[@-_]"# // two-byte escape
    ]
    return patterns.reduce(text) { value, pattern in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}

struct TerraformCommandError: Error, Sendable {
    let message: String
    var output: String
    var cancelled: Bool
    var outputTruncated: Bool

    init(message: String, output: String = "", cancelled: Bool = false, outputTruncated: Bool = false) {
        self.message = stripTerraformTerminalEscapes(message)
        self.output = stripTerraformTerminalEscapes(output)
        self.cancelled = cancelled
        self.outputTruncated = outputTruncated
    }
}

/// A cancellable reference to one Terraform command. Cancellation is cooperative:
/// Terraform receives SIGINT and the command completes only after it exits and its
/// output streams have been drained.
/// Cancellation state is protected by `lock`; Process is attached/read while holding
/// that lock and is only controlled through Process' thread-safe lifecycle methods.
final class TerraformCommandHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var finished = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationRequested
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func cancel() {
        let activeProcess: Process?
        lock.lock()
        cancellationRequested = true
        activeProcess = process
        lock.unlock()
        guard let activeProcess, activeProcess.isRunning else { return }
        // Terraform treats SIGINT as a graceful cancellation and can perform
        // provider cleanup before exiting. Never escalate apply to SIGKILL.
        activeProcess.interrupt()
    }

    fileprivate func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel, process.isRunning {
            process.interrupt()
        }
    }

    fileprivate func finish() {
        lock.lock()
        finished = true
        process = nil
        lock.unlock()
    }
}

/// Runs Terraform directly, without a shell, on a serial command queue.
final class Runner: Sendable {
    typealias Completion = @MainActor @Sendable (String?, TerraformCommandError?) -> Void
    typealias OutputHandler = @MainActor @Sendable (TerraformOutputStream, String) -> Void

    private static let captureLimit = 1024 * 1024
    private static let lineLimit = 64 * 1024
    private static let omittedLine = "[Terraform output line omitted: line exceeded 64 KiB]\n"

    private let cliQueue = DispatchQueue(label: "Terraform Runner")
    private let lifecycleQueue = DispatchQueue(label: "Terraform Runner lifecycle")
    private let executableOverride: URL?
    private let environment: [String: String]
    private let searchPaths: [String]
    private let planDirectory: URL

    init(executableURL: URL? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        executableOverride = executableURL
        self.environment = environment
        self.searchPaths = searchPaths
        planDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Habitable-plans-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                    isDirectory: true)
        Self.removeAbandonedPlanDirectories()
    }

    deinit { try? FileManager.default.removeItem(at: planDirectory) }

    private static func removeAbandonedPlanDirectories() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("Habitable-plans-") {
            let components = entry.lastPathComponent.split(separator: "-", maxSplits: 3)
            guard components.count == 4, components[0] == "Habitable", components[1] == "plans",
                  let processID = Int32(components[2]) else { continue }
            // Never remove another live Runner's input files. PID-scoped names
            // let a later app launch clean directories left by crashed sessions.
            if kill(pid_t(processID), 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    var executableURL: URL? {
        if let override = executableOverride {
            return FileManager.default.isExecutableFile(atPath: override.path) ? override : nil
        }
        if let path = environment["HABITABLE_TERRAFORM_PATH"], !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + searchPaths
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("terraform") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func planURL(runId: String) -> URL {
        planDirectory.appendingPathComponent(runId).appendingPathExtension("tfplan")
    }

    func discardPlan(runId: String) {
        try? FileManager.default.removeItem(at: planURL(runId: runId))
    }

    @discardableResult
    func version(onOutput: OutputHandler? = nil, completion: @escaping Completion) -> TerraformCommandHandle {
        execute(["version", "-json"], workingDirectory: FileManager.default.temporaryDirectory,
                onOutput: onOutput, completion: completion)
    }

    @discardableResult
    func initialize(workingDirectory: URL, onOutput: OutputHandler? = nil,
                    completion: @escaping Completion) -> TerraformCommandHandle {
        execute(["init", "-input=false", "-no-color"], workingDirectory: workingDirectory,
                onOutput: onOutput, completion: completion)
    }

    @discardableResult
    func validate(workingDirectory: URL, onOutput: OutputHandler? = nil,
                  completion: @escaping Completion) -> TerraformCommandHandle {
        execute(["validate", "-no-color"], workingDirectory: workingDirectory,
                onOutput: onOutput, completion: completion)
    }

    @discardableResult
    @MainActor
    func plan(workingDirectory: URL, runId: String,
              variables: [TerraformVariable] = [],
              environmentVariables: [EnvironmentVariable] = [],
              onOutput: OutputHandler? = nil,
              completion: @escaping Completion) -> TerraformCommandHandle {
        let handle = TerraformCommandHandle()
        var variableFile: URL?
        do {
            var values: [String: Any] = [:]
            for variable in variables {
                guard values[variable.key] == nil else {
                    throw VariableInputError.duplicateKey(variable.key)
                }
                values[variable.key] = try variable.terraformJSONValue()
            }

            var environmentOverrides: [String: String] = [:]
            for variable in environmentVariables {
                try variable.validate()
                environmentOverrides[variable.key] = variable.value
            }

            var arguments = ["plan", "-input=false", "-json"]
            if !values.isEmpty {
                try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = planDirectory.appendingPathComponent("\(UUID().uuidString).tfvars.json")
                let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .fragmentsAllowed])
                variableFile = file
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                arguments.append("-var-file=\(file.path)")
            }
            arguments.append("-out=\(planURL(runId: runId).path)")
            let inputFileToRemove = variableFile
            execute(arguments, workingDirectory: workingDirectory, environmentOverrides: environmentOverrides,
                    onOutput: onOutput, handle: handle) { output, error in
                if let inputFileToRemove { try? FileManager.default.removeItem(at: inputFileToRemove) }
                completion(output, error)
            }
        } catch {
            if let variableFile { try? FileManager.default.removeItem(at: variableFile) }
            handle.finish()
            DispatchQueue.main.async {
                completion(nil, TerraformCommandError(message: error.localizedDescription))
            }
        }
        return handle
    }

    @discardableResult
    func apply(workingDirectory: URL, runId: String, onOutput: OutputHandler? = nil,
               completion: @escaping Completion) -> TerraformCommandHandle {
        execute(["apply", "-input=false", "-json", planURL(runId: runId).path],
                workingDirectory: workingDirectory, onOutput: onOutput, completion: completion)
    }

    /// Reads the immutable plan artifact produced for this run. Keep this separate from
    /// `show`, which reads the current workspace state.
    @discardableResult
    func showPlan(workingDirectory: URL, runId: String, onOutput: OutputHandler? = nil,
                  completion: @escaping Completion) -> TerraformCommandHandle {
        execute(["show", "-json", planURL(runId: runId).path],
                workingDirectory: workingDirectory, onOutput: onOutput, completion: completion)
    }

    @discardableResult
    func show(workingDirectory: URL, onOutput: OutputHandler? = nil,
              completion: @escaping Completion) -> TerraformCommandHandle {
        execute(["show", "-json"], workingDirectory: workingDirectory,
                onOutput: onOutput, completion: completion)
    }

    @discardableResult
    private func execute(_ arguments: [String], workingDirectory: URL,
                         environmentOverrides: [String: String] = [:],
                         onOutput: OutputHandler? = nil,
                         handle: TerraformCommandHandle = TerraformCommandHandle(),
                         completion: @escaping Completion) -> TerraformCommandHandle {
        let delivery = onOutput.map(OutputDelivery.init)
        cliQueue.async {
            let commandFinished = DispatchSemaphore(value: 0)
            guard !handle.isCancelled else {
                handle.finish()
                DispatchQueue.main.async {
                    completion(nil, TerraformCommandError(message: "Terraform command was canceled before it started.", cancelled: true))
                }
                return
            }
            guard let executable = self.executableURL else {
                handle.finish()
                DispatchQueue.main.async {
                    completion(nil, TerraformCommandError(message:
                        "Terraform was not found. Download a release in Settings, use system Terraform, or set HABITABLE_TERRAFORM_PATH in the Xcode scheme."))
                }
                return
            }

            let retainsFullOutput = arguments.first == "show"
            let process = Process()
            do {
                try FileManager.default.createDirectory(at: self.planDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = self.environment
                    .merging(environmentOverrides) { _, new in new }
                    .merging(["TF_IN_AUTOMATION": "1", "TF_INPUT": "0"]) { _, new in new }
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let state = CommandState(
                    runner: self, process: process, handle: handle,
                    stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading,
                    retainsFullOutput: retainsFullOutput,
                    streamsOutput: onOutput != nil && ["init", "validate", "plan", "apply"].contains(arguments.first ?? ""),
                    onOutput: delivery,
                    completion: completion, finished: { commandFinished.signal() })

                process.terminationHandler = { process in
                    self.lifecycleQueue.async { state.processExited(status: process.terminationStatus) }
                }
                try process.run()
                handle.attach(process)
                // Close the parent's write descriptors so EOF arrives once the
                // child and its inherited writers exit.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                // Both descriptors are drained concurrently before completion. This
                // avoids deadlock even when Terraform fills both pipe buffers.
                stdoutPipe.fileHandleForReading.readabilityHandler = { file in
                    let data = file.availableData
                    self.lifecycleQueue.async { state.consume(data, stream: .stdout) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { file in
                    let data = file.availableData
                    self.lifecycleQueue.async { state.consume(data, stream: .stderr) }
                }
                commandFinished.wait()
            } catch {
                // A failed launch never calls terminationHandler, so release its
                // captured command state explicitly.
                process.terminationHandler = nil
                handle.finish()
                let failure = TerraformCommandError(message: error.localizedDescription, cancelled: handle.isCancelled)
                DispatchQueue.main.async { completion(nil, failure) }
                commandFinished.signal()
            }
        }
        return handle
    }

    /// Coalesces bursts into one pending main-thread delivery, bounding queued UI
    /// updates as well as retained logs. Only complete lines enter this buffer.
    /// Mutable batching state is protected by `lock`; delivery always hops to MainActor.
    private final class OutputDelivery: @unchecked Sendable {
        private let lock = NSLock()
        private let callback: OutputHandler
        private var pending: [(TerraformOutputStream, String)] = []
        private var bytes = 0
        private var scheduled = false
        private var omitted = false

        init(_ callback: @escaping OutputHandler) { self.callback = callback }

        func receive(_ stream: TerraformOutputStream, _ text: String) {
            lock.lock()
            if bytes + text.utf8.count > 262_144 {
                pending.removeAll(keepingCapacity: true)
                bytes = 0
                omitted = true
            }
            pending.append((stream, text))
            bytes += text.utf8.count
            let shouldSchedule = !scheduled
            scheduled = true
            lock.unlock()
            if shouldSchedule { DispatchQueue.main.async { self.deliver() } }
        }

        @MainActor
        private func deliver() {
            lock.lock()
            let events = pending
            let didOmit = omitted
            pending.removeAll(keepingCapacity: true)
            bytes = 0
            omitted = false
            scheduled = false
            lock.unlock()
            if didOmit { callback(.stdout, "[Earlier live output omitted; consult the completed run events]\n") }
            var batch: (TerraformOutputStream, String)?
            for (stream, text) in events {
                if batch?.0 == stream {
                    batch?.1 += text
                } else {
                    if let batch { callback(batch.0, batch.1) }
                    batch = (stream, text)
                }
            }
            if let batch { callback(batch.0, batch.1) }
        }
    }

    /// Mutable command state is confined to `lifecycleQueue` after launch.
    /// Constructed before launch, then all mutable state is accessed only on
    /// `Runner.lifecycleQueue`. Dispatch callbacks enqueue there before touching it.
    private final class CommandState: @unchecked Sendable {
        private let runner: Runner
        private let process: Process
        private let handle: TerraformCommandHandle
        private let stdout: FileHandle
        private let stderr: FileHandle
        private let retainsFullOutput: Bool
        private let streamsOutput: Bool
        private let onOutput: OutputDelivery?
        private let completion: Completion
        private let finished: () -> Void
        private var stdoutState = StreamState()
        private var stderrState = StreamState()
        private var exitStatus: Int32?
        private var completionDelivered = false

        init(runner: Runner, process: Process, handle: TerraformCommandHandle,
             stdout: FileHandle, stderr: FileHandle, retainsFullOutput: Bool,
             streamsOutput: Bool, onOutput: OutputDelivery?, completion: @escaping Completion,
             finished: @escaping () -> Void) {
            self.runner = runner
            self.process = process
            self.handle = handle
            self.stdout = stdout
            self.stderr = stderr
            self.retainsFullOutput = retainsFullOutput
            self.streamsOutput = streamsOutput
            self.onOutput = onOutput
            self.completion = completion
            self.finished = finished
        }

        func consume(_ data: Data, stream: TerraformOutputStream) {
            var state = stream == .stdout ? stdoutState : stderrState
            guard !state.eof else { return }
            if data.isEmpty {
                if !state.pending.isEmpty {
                    state.finishPartialLine(stream: stream,
                                            retainsFullOutput: retainsFullOutput && stream == .stdout,
                                            streamsOutput: streamsOutput, onOutput: onOutput)
                }
                state.eof = true
                if stream == .stdout { stdoutState = state } else { stderrState = state }
                if stream == .stdout { stdout.readabilityHandler = nil; try? stdout.close() }
                else { stderr.readabilityHandler = nil; try? stderr.close() }
                completeIfDrained()
                return
            }

            state.pending.append(data)
            state.processCompleteLines(stream: stream,
                                       retainsFullOutput: retainsFullOutput && stream == .stdout,
                                       streamsOutput: streamsOutput, onOutput: onOutput)
            if stream == .stdout { stdoutState = state } else { stderrState = state }
        }

        func processExited(status: Int32) {
            exitStatus = status
            process.terminationHandler = nil
            completeIfDrained()
        }

        private func completeIfDrained() {
            guard !completionDelivered, exitStatus != nil, stdoutState.eof, stderrState.eof else { return }
            completionDelivered = true
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            let stdoutText = String(decoding: stdoutState.capture, as: UTF8.self)
            let stderrText = String(decoding: stderrState.capture, as: UTF8.self)
            let wasCancelled = handle.isCancelled
            let outputOverflow = stdoutState.truncated
            let captureTruncated = stdoutState.truncated || stderrState.truncated
            let status = exitStatus ?? -1
            let failure: TerraformCommandError?
            if wasCancelled {
                let message = stderrText.isEmpty ? "Terraform command was canceled."
                    : "Terraform command was canceled. \(stderrText)"
                failure = TerraformCommandError(message: message, output: stdoutText, cancelled: true,
                                                outputTruncated: captureTruncated)
            } else if outputOverflow {
                failure = TerraformCommandError(message: "Terraform output exceeded the bounded capture; the command result was not accepted.",
                                                output: stdoutText, outputTruncated: true)
            } else if status != 0 {
                failure = TerraformCommandError(
                    message: stderrText.isEmpty ? (stdoutText.isEmpty ? "Terraform exited with status \(status)." : stdoutText) : stderrText,
                    output: stdoutText, outputTruncated: captureTruncated)
            } else {
                failure = nil
            }
            handle.finish()
            finished()
            DispatchQueue.main.async { [completion] in completion(failure == nil ? stdoutText : nil, failure) }
        }
    }

    /// One stream's bounded capture and line decoder, copied back into CommandState
    /// after every read so all mutations remain serialized.
    private struct StreamState {
        var pending = Data()
        var capture = Data()
        var truncated = false
        var captureLimitReached = false
        var droppingLine = false
        var eof = false

        mutating func processCompleteLines(stream: TerraformOutputStream, retainsFullOutput: Bool,
                                           streamsOutput: Bool, onOutput: OutputDelivery?) {
            while let newline = pending.firstIndex(of: 0x0A) {
                let end = pending.index(after: newline)
                let line = Data(pending[..<end])
                pending.removeSubrange(..<end)
                if droppingLine {
                    emit(Data(Runner.omittedLine.utf8), stream: stream, retainsFullOutput: retainsFullOutput,
                         streamsOutput: streamsOutput, onOutput: onOutput)
                    droppingLine = false
                } else {
                    emit(line, stream: stream, retainsFullOutput: retainsFullOutput,
                         streamsOutput: streamsOutput, onOutput: onOutput)
                }
            }
            if !retainsFullOutput && pending.count > Runner.lineLimit {
                // Keep scanning for the next newline without retaining an unbounded
                // line. The marker is emitted only once that line is complete.
                pending.removeAll(keepingCapacity: true)
                droppingLine = true
                truncated = true
            }
        }

        mutating func finishPartialLine(stream: TerraformOutputStream, retainsFullOutput: Bool,
                                        streamsOutput: Bool,
                                        onOutput: OutputDelivery?) {
            if droppingLine {
                emit(Data(Runner.omittedLine.utf8), stream: stream, retainsFullOutput: false,
                     streamsOutput: streamsOutput, onOutput: onOutput)
            } else {
                emit(pending, stream: stream, retainsFullOutput: retainsFullOutput,
                     streamsOutput: streamsOutput, onOutput: onOutput)
            }
            pending.removeAll()
            droppingLine = false
        }

        private mutating func emit(_ line: Data, stream: TerraformOutputStream, retainsFullOutput: Bool,
                                   streamsOutput: Bool, onOutput: OutputDelivery?) {
            let completeLine: Data
            if !retainsFullOutput && line.count > Runner.lineLimit {
                completeLine = Data(Runner.omittedLine.utf8)
                truncated = true
            } else {
                completeLine = line
            }
            if retainsFullOutput {
                if stream == .stdout { capture.append(completeLine) }
            } else if !captureLimitReached {
                if capture.count + completeLine.count <= Runner.captureLimit {
                    capture.append(completeLine)
                } else {
                    truncated = true
                    captureLimitReached = true
                    let marker = Data("[Terraform output truncated at 1 MiB]\n".utf8)
                    if capture.count + marker.count <= Runner.captureLimit { capture.append(marker) }
                }
            }
            if streamsOutput, let onOutput {
                let text = String(decoding: completeLine, as: UTF8.self)
                onOutput.receive(stream, text)
            }
        }
    }
}
