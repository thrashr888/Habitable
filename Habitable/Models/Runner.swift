import Combine
import Darwin
import Foundation

struct TerraformCommandError: Error {
    let message: String
    var output = ""
}

/// Runs Terraform directly, without a shell, on a serial background queue.
final class Runner: ObservableObject {
    typealias Completion = (String?, TerraformCommandError?) -> Void
    private let cliQueue = DispatchQueue(label: "Terraform Runner")
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

    func version(completion: @escaping Completion) {
        execute(["version", "-json"], workingDirectory: FileManager.default.temporaryDirectory, completion: completion)
    }

    func initialize(workingDirectory: URL, completion: @escaping Completion) {
        execute(["init", "-input=false", "-no-color"], workingDirectory: workingDirectory, completion: completion)
    }

    func validate(workingDirectory: URL, completion: @escaping Completion) {
        execute(["validate", "-no-color"], workingDirectory: workingDirectory, completion: completion)
    }

    func plan(workingDirectory: URL, runId: String,
              variables: [TerraformVariable] = [],
              environmentVariables: [EnvironmentVariable] = [],
              completion: @escaping Completion) {
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
            execute(arguments, workingDirectory: workingDirectory, environmentOverrides: environmentOverrides) { output, error in
                if let inputFileToRemove { try? FileManager.default.removeItem(at: inputFileToRemove) }
                completion(output, error)
            }
        } catch {
            if let variableFile { try? FileManager.default.removeItem(at: variableFile) }
            DispatchQueue.main.async {
                completion(nil, TerraformCommandError(message: error.localizedDescription))
            }
        }
    }

    func apply(workingDirectory: URL, runId: String, completion: @escaping Completion) {
        execute(["apply", "-input=false", "-json", planURL(runId: runId).path],
                workingDirectory: workingDirectory, completion: completion)
    }

    /// Reads the immutable plan artifact produced for this run. Keep this separate from
    /// `show`, which reads the current workspace state.
    func showPlan(workingDirectory: URL, runId: String, completion: @escaping Completion) {
        execute(["show", "-json", planURL(runId: runId).path],
                workingDirectory: workingDirectory, completion: completion)
    }

    func show(workingDirectory: URL, completion: @escaping Completion) {
        execute(["show", "-json"], workingDirectory: workingDirectory, completion: completion)
    }

    private func execute(_ arguments: [String], workingDirectory: URL,
                         environmentOverrides: [String: String] = [:], completion: @escaping Completion) {
        cliQueue.async {
            guard let executable = self.executableURL else {
                DispatchQueue.main.async {
                    completion(nil, TerraformCommandError(message:
                        "Terraform was not found. Download a release in Settings, use system Terraform, or set HABITABLE_TERRAFORM_PATH in the Xcode scheme."))
                }
                return
            }
            do {
                try FileManager.default.createDirectory(at: self.planDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                // Files keep stdout and stderr separate without blocking on full pipe buffers.
                let outputURL = self.planDirectory.appendingPathComponent(UUID().uuidString)
                let errorURL = self.planDirectory.appendingPathComponent(UUID().uuidString)
                defer {
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: errorURL)
                }
                FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let stdout = try FileHandle(forWritingTo: outputURL)
                let stderr = try FileHandle(forWritingTo: errorURL)
                defer { try? stdout.close(); try? stderr.close() }
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = self.environment
                    .merging(environmentOverrides) { _, new in new }
                    .merging(["TF_IN_AUTOMATION": "1", "TF_INPUT": "0"]) { _, new in new }
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdout
                process.standardError = stderr
                try process.run()
                process.waitUntilExit()
                let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
                let errorOutput = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                let failure: TerraformCommandError? = process.terminationStatus == 0 ? nil : TerraformCommandError(
                    message: errorOutput.isEmpty ? (output.isEmpty ? "Terraform exited with status \(process.terminationStatus)." : output) : errorOutput,
                    output: output)
                DispatchQueue.main.async { completion(failure == nil ? output : nil, failure) }
            } catch {
                let failure = TerraformCommandError(message: error.localizedDescription)
                DispatchQueue.main.async { completion(nil, failure) }
            }
        }
    }
}
