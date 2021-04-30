//
//  TerraformRunner.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Foundation
import ShellOut
import SwiftyJSON
import SwiftUI

class StructuredLog: ObservableObject {
    var logs: [LogMessage] = []
    var changeSummaries: [ChangeSummaryMessage] = []
    var versions: [VersionMessage] = []
    var diagnostics: [DiagnosticMessage] = []
    var resources: [ResourceState] = []
    var outputs: [OutputsMessage] = []
}

class TerraformRunner: ObservableObject {
    @Published var workingDirectory: String
    @Published var locked = false
    @Published var textOutput: String?
    @Published var ansiOutput: Text?
    @Published var errorMessage: String?
    @Published var structuredLog: StructuredLog?
    
    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }
    
    private func cleanANSI(_ input: String) -> String {
        return input.replacingOccurrences(of: #"\[(0-9)+m"#, with: "=================", options: .regularExpression, range: nil)
    }
    
    private func before() {
        locked = true
        textOutput = nil
        ansiOutput = nil
        structuredLog = nil
        errorMessage = nil
    }
    private func handleSuccess(_ output: String) {
        locked = false
        textOutput = cleanANSI(output)
//        ansiOutput = Ansi.format(output)
        print(textOutput!)
        objectWillChange.send()
    }
    private func handleError(_ error: ShellOutError) {
        locked = false
//        textOutput = cleanANSI(error.output)
//        ansiOutput = Ansi.format(error.output)
        errorMessage = cleanANSI(error.message)
        print(errorMessage!)
        objectWillChange.send()
    }
    
    
    func isResourceMessage(_ message: JSON) -> Bool {
        if (!message["type"].exists()) { return false }
        return message["type"].string == MessageTypes.PlannedChange.rawValue || isHookMessage(message);
    }

    func isHookMessage(_ message: JSON) -> Bool {
        if (!message["type"].exists()) { return false }
        guard let mType = message["type"].string, let type = MessageTypes.init(rawValue: mType) else { return false }

        return [
            MessageTypes.ApplyStart,
            MessageTypes.ApplyProgress,
            MessageTypes.ApplyComplete,
            MessageTypes.ApplyErrored,
            MessageTypes.ProvisionStart,
            MessageTypes.ProvisionProgress,
            MessageTypes.ProvisionComplete,
            MessageTypes.ProvisionErrored,
            MessageTypes.RefreshStart,
            MessageTypes.RefreshComplete,
        ].contains(type)
    }

    func handleJsonSuccess(_ output: String) {
        print(output)
        locked = false
        
        let newLogs = StructuredLog()
        
        let json = parseJsonOutput(output)
        newLogs.logs.append(transformLog(json))
        
        structuredLog = newLogs
        
        print(newLogs)
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
                    "@message": output.trimmingCharacters(in: .whitespacesAndNewlines)
                  ])
            }
        }
        return JSON([
            "type": "log",
            "@message": output.trimmingCharacters(in: .whitespacesAndNewlines)
          ])
    }
    
    func handleNDJsonSuccess(_ output: String) {
        locked = false
        
        let newLogs = StructuredLog()
        
        let json = parseNDJsonOutput(output)
        for line in json {
            guard let mType = line["type"].string, let type = MessageTypes.init(rawValue: mType) else {
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
                    guard let index = newLogs.resources.firstIndex(where: { (rs) -> Bool in
                        rs.address == hook.address
                    }) else { continue }
                    newLogs.resources[index].update(hook)
                }
                continue
            }
            
            switch(type) {
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
                        "@message": line.trimmingCharacters(in: .whitespacesAndNewlines)
                      ])
                    out.append(json)
                }
                print(line)
            }
        }
        return out
    }
    
    func initialize() {
        before()
        do {
            let out = try shellOut(to: .terraformInit(), at: self.workingDirectory)
            handleSuccess(out)
        } catch {
            let error = error as! ShellOutError
            handleError(error)
        }
    }
    
    func plan() {
        before()
        do {
            let out = try shellOut(to: .terraformPlan(), at: self.workingDirectory)
            handleNDJsonSuccess(out)
        } catch {
            let error = error as! ShellOutError
            handleError(error)
        }
    }
    
    func apply() {
        before()
        do {
            let out = try shellOut(to: .terraformApply(), at: self.workingDirectory)
            handleNDJsonSuccess(out)
        } catch {
            let error = error as! ShellOutError
            handleNDJsonSuccess(error.output)
            handleError(error)
        }
    }
    
    func show() {
        before()
        do {
            let out = try shellOut(to: .terraformShow(), at: self.workingDirectory)
            handleJsonSuccess(out)
        } catch {
            let error = error as! ShellOutError
            handleError(error)
        }
    }
}

public extension ShellOutCommand {
    static func terraformInit() -> ShellOutCommand {
        return ShellOutCommand(string: "/usr/local/bin/terraform init")
    }
    static func terraformPlan() -> ShellOutCommand {
        let command = "~/hashicorp/alisdair-terraform-private/tfa plan".appending(" -json")
        return ShellOutCommand(string: command)
    }
    static func terraformApply() -> ShellOutCommand {
        let command = "~/hashicorp/alisdair-terraform-private/tfa apply".appending(" -json").appending(" -auto-approve")
        return ShellOutCommand(string: command)
    }
    static func terraformShow() -> ShellOutCommand {
        let command = "~/hashicorp/alisdair-terraform-private/tfa show".appending(" -json")
        return ShellOutCommand(string: command)
    }
}
