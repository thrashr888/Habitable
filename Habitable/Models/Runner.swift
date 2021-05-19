//
//  Runner.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/5/21.
//

import Collections
import Foundation
import ShellOut
import SwiftTerm
import SwiftUI
import SwiftyJSON

class Runner: ObservableObject {
    var runnerQueue: Deque<TerraformRun> = []
    let cliQueue = DispatchQueue(label: "Terraform Runner")
    let cliDir = Bundle.main.url(forResource: "terraform", withExtension: nil)!

    func initialize(workingDirectory: URL, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                print(self.cliDir)
                let out = try shellOut(to: .terraformInit(self.cliDir.path), at: workingDirectory.path)
                DispatchQueue.main.async {
                    completion(out, nil)
                }
            } catch {
                let error = error as! ShellOutError
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
    
    func validate(workingDirectory: URL, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformValidate(self.cliDir.path), at: workingDirectory.path)
                DispatchQueue.main.async {
                    completion(out, nil)
                }
            } catch {
                let error = error as! ShellOutError
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    func plan(workingDirectory: URL, runId: String? = nil, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                var tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                if let runId = runId {
                    tmp = tmp.appendingPathComponent("\(runId).plan")
                } else {
                    tmp = tmp.appendingPathComponent("tf.plan")
                }
                
                let out = try shellOut(to: .terraformPlan(self.cliDir.path, tmp.relativePath), at: workingDirectory.path)
                DispatchQueue.main.async {
                    completion(out, nil)
                }
            } catch {
                let error = error as! ShellOutError
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    func apply(workingDirectory: URL, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformApply(self.cliDir.path), at: workingDirectory.path)
                DispatchQueue.main.async {
                    completion(out, nil)
                }
            } catch {
                let error = error as! ShellOutError
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    func show(workingDirectory: URL, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformShow(self.cliDir.path), at: workingDirectory.path)
                DispatchQueue.main.async {
                    completion(out, nil)
                }
            } catch {
                let error = error as! ShellOutError
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
}

public extension ShellOutCommand {
    static func terraformInit(_ cliDir: String) -> ShellOutCommand {
        let command = cliDir + " init"
        print(command)
        return ShellOutCommand(string: command)
    }

    static func terraformPlan(_ cliDir: String, _ planFile: String? = nil) -> ShellOutCommand {
        var command = cliDir + " plan"
            .appending(" -json")
        if let planFile = planFile {
            command = command.appending(" -out=\(planFile)")
        }
        print(command)
        return ShellOutCommand(string: command)
    }

    // TODO write JSON and stdout to files
    // keep a folder per-run so we can reload them later
    // essentially persist the run list w/ plans and applies
    static func terraformApply(_ cliDir: String, _ planFile: String? = nil) -> ShellOutCommand {
        var command = cliDir + " apply"
            .appending(" -json")
            .appending(" -auto-approve")
        if let planFile = planFile {
            command = command.appending(" \(planFile)")
        }
        print(command)
        return ShellOutCommand(string: command)
    }

    static func terraformShow(_ cliDir: String) -> ShellOutCommand {
        let command = cliDir + " show"
            .appending(" -json")
        print(command)
        return ShellOutCommand(string: command)
    }
    
    static func terraformValidate(_ cliDir: String) -> ShellOutCommand {
        let command = cliDir + " validate"
        print(command)
        return ShellOutCommand(string: command)
    }

    static func terraformDestroy(_ cliDir: String) -> ShellOutCommand {
        let command = cliDir + " destroy"
        print(command)
        return ShellOutCommand(string: command)
    }
}
