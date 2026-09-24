import Combine
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
    private let planDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Habitable-plans-\(UUID().uuidString)", isDirectory: true)

    init(executableURL: URL? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        executableOverride = executableURL
        self.environment = environment
        self.searchPaths = searchPaths
    }

    deinit { try? FileManager.default.removeItem(at: planDirectory) }

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

    func plan(workingDirectory: URL, runId: String, completion: @escaping Completion) {
        execute(["plan", "-input=false", "-json", "-out=\(planURL(runId: runId).path)"],
                workingDirectory: workingDirectory, completion: completion)
    }

    func apply(workingDirectory: URL, runId: String, completion: @escaping Completion) {
        execute(["apply", "-input=false", "-json", planURL(runId: runId).path],
                workingDirectory: workingDirectory, completion: completion)
    }

    func show(workingDirectory: URL, completion: @escaping Completion) {
        execute(["show", "-json"], workingDirectory: workingDirectory, completion: completion)
    }

    private func execute(_ arguments: [String], workingDirectory: URL, completion: @escaping Completion) {
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
                process.environment = self.environment.merging(["TF_IN_AUTOMATION": "1", "TF_INPUT": "0"]) { _, new in new }
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
