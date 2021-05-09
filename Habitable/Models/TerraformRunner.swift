//
//  TerraformRunner.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Foundation
import ShellOut
import SwiftTerm
import SwiftUI
import SwiftyJSON

// TODO: rename to Workspace
// move all these variables to workspace
// keep shell stuff in a runner
// break out plan, apply, show, etc runners
class TerraformRunner: ObservableObject {
    // state
    @Published var locked = false
    @Published var lockedBy: TerraformRun?
    @Published var isInitialized = false
    @Published var hasState = false
    @Published var hasVariables = false

    // settings
    @Published var workingDirectory: String
    @Published var description = ""
    @Published var autoApply = false
    @Published var terraformVersion = "0.15.2"

    // data
    @Published var runs: [TerraformRun] = []
    @Published var state: ShowMessage?
    @Published var variables = Variables()

    // views (TODO: move to runs)
    @Published var textOutput: String?
    @Published var ansiOutput: Text?
    @Published var showOutput: ShowMessage?
    @Published var errorMessage: String?
    @Published var structuredLog: StructuredLog?

    let cliQueue = DispatchQueue(label: "Terraform Runner")

    init(dir: URL) {
        workingDirectory = dir.path
        updateWorkingDirectory(dir: dir)
    }

    func updateWorkingDirectory(dir: URL) {
        workingDirectory = dir.path

        var isDir: ObjCBool = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dir.appendingPathComponent(".terraform").path, isDirectory: &isDir) {
            isInitialized = true
        }
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfstate").path, isDirectory: &isDir) {
            hasState = true
        }
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfvars").path, isDirectory: &isDir) {
            hasVariables = true
        }
    }

    private func cleanANSI(_ input: String) -> String {
        return input.replacingOccurrences(of: #"\[([0-9])+m"#, with: "", options: .regularExpression, range: nil)
    }

    private func before() {
        locked = true
        textOutput = nil
        ansiOutput = nil
        showOutput = nil
        structuredLog = nil
        errorMessage = nil
    }

    private func handleSuccess(_ output: String) {
        locked = false
        textOutput = cleanANSI(output)
        print(textOutput!)
        objectWillChange.send()
    }

    private func handleError(_ error: ShellOutError) {
        locked = false
        textOutput = cleanANSI(error.output)
        errorMessage = cleanANSI(error.message)
        print(errorMessage!)
        objectWillChange.send()
    }

    func handleShowSuccess(_ output: String) {
        print(output)
        locked = false

        let json = parseJsonOutput(output)
        showOutput = transformShow(json)

        objectWillChange.send()
    }

    private func parseJsonOutput(_ output: String) -> JSON {
        if let dataFromString = output.data(using: .utf8, allowLossyConversion: false) {
            do {
                return try JSON(data: dataFromString)
            } catch {
                print("JSON parse error:", error)
                return JSON([
                    "type": "log",
                    "@message": output.trimmingCharacters(in: .whitespacesAndNewlines),
                ])
            }
        }
        return JSON([
            "type": "log",
            "@message": output.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    func handleNDJsonSuccess(_ output: String) {
        locked = false

        let newLogs = StructuredLog()

        let json = parseNDJsonOutput(output)
        for line in json {
            guard let mType = line["type"].string, let type = MessageTypes(rawValue: mType) else {
                // no type, just log it
                newLogs.logs.append(transformLog(line))
                continue
            }

            if isResourceMessage(line) {
                if type == .PlannedChange {
                    // doesn't exist yet
                    let change = transformPlannedChange(line)
                    newLogs.resources.append(ResourceState(change.change))
                } else {
                    // already exists
                    guard let hook = transformHook(line) else { continue }
                    guard let index = newLogs.resources.firstIndex(where: { rs -> Bool in
                        rs.address == hook.address
                    }) else { continue }
                    newLogs.resources[index].update(hook)
                }
                continue
            }

            switch type {
            case MessageTypes.Version:
                newLogs.versions.append(transformVersion(line))
            case MessageTypes.Log:
                newLogs.logs.append(transformLog(line))
            case MessageTypes.ChangeSummary:
                newLogs.changeSummaries.append(transformChangeSummary(line))
            case MessageTypes.Diagnostic:
                newLogs.diagnostics.append(transformDiagnostic(line))
            case MessageTypes.Outputs:
                newLogs.outputs.append(transformOutputs(line))
            default:
                newLogs.logs.append(transformLog(line))
            }
        }

        structuredLog = newLogs

        print(newLogs)
        objectWillChange.send()
    }

    private func parseNDJsonOutput(_ output: String) -> [JSON] {
        var out: [JSON] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if let dataFromString = line.data(using: .utf8, allowLossyConversion: false) {
                do {
                    let json = try JSON(data: dataFromString)
                    out.append(json)
                } catch {
                    print("JSON parse error:", error)
                    let json = JSON([
                        "type": "log",
                        "@message": line.trimmingCharacters(in: .whitespacesAndNewlines),
                    ])
                    out.append(json)
                }
                print(line)
            }
        }
        return out
    }

    func initialize(workingDirectory _: String) {
        before()
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformInit(), at: self.workingDirectory)
                self.handleSuccess(out)
            } catch {
                let error = error as! ShellOutError
                self.handleError(error)
            }
        }
    }

    func plan(workingDirectory _: String) {
        before()
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformPlan(), at: self.workingDirectory)
                self.handleNDJsonSuccess(out)
            } catch {
                let error = error as! ShellOutError
                self.handleError(error)
            }
        }
    }

    func apply(workingDirectory _: String) {
        before()
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformApply(), at: self.workingDirectory)
                self.handleNDJsonSuccess(out)
            } catch {
                let error = error as! ShellOutError
                self.handleNDJsonSuccess(error.output)
                self.handleError(error)
            }
        }
    }

    func show(workingDirectory _: String) {
        before()
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformShow(), at: self.workingDirectory)
                self.handleShowSuccess(out)
            } catch {
                let error = error as! ShellOutError
                self.handleError(error)
            }
        }
    }
}

public extension ShellOutCommand {
    static func terraformInit() -> ShellOutCommand {
        return ShellOutCommand(string: "/usr/local/bin/terraform init")
    }

    static func terraformPlan() -> ShellOutCommand {
        let command = "/Users/thrashr888/hashicorp/alisdair-terraform-private/tfa plan"
            .appending(" -json")
        return ShellOutCommand(string: command)
    }

    static func terraformApply() -> ShellOutCommand {
        let command = "/Users/thrashr888/hashicorp/alisdair-terraform-private/tfa apply"
            .appending(" -json")
            .appending(" -auto-approve")
        return ShellOutCommand(string: command)
    }

    static func terraformShow() -> ShellOutCommand {
        let command = "/Users/thrashr888/hashicorp/alisdair-terraform-private/tfa show"
            .appending(" -json")
        return ShellOutCommand(string: command)
    }

    static func terraformDestroy() -> ShellOutCommand {
        let command = "/Users/thrashr888/hashicorp/alisdair-terraform-private/tfa destroy"
        return ShellOutCommand(string: command)
    }
}
