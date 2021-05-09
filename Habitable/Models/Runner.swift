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

    func initialize(workingDirectory: String, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformInit(), at: workingDirectory)
                completion(out, nil)
            } catch {
                let error = error as! ShellOutError
                completion(nil, error)
            }
        }
    }

    func plan(workingDirectory: String, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformPlan(), at: workingDirectory)
                completion(out, nil)
            } catch {
                let error = error as! ShellOutError
                completion(nil, error)
            }
        }
    }

    func apply(workingDirectory: String, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformApply(), at: workingDirectory)
                completion(out, nil)
            } catch {
                let error = error as! ShellOutError
                completion(nil, error)
            }
        }
    }

    func show(workingDirectory: String, completion: @escaping (_ res: String?, _ error: ShellOutError?) -> Void) {
        cliQueue.async {
            do {
                let out = try shellOut(to: .terraformShow(), at: workingDirectory)
                completion(out, nil)
            } catch {
                let error = error as! ShellOutError
                completion(nil, error)
            }
        }
    }
}
