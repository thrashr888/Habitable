//
//  RunModel.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/9/21.
//

import Foundation
import ShellOut

enum RunStatus: String {
    case pending = "PENDING"
    case planning = "PLANNING"
    case planned = "PLANNED"
    case confirmed = "CONFIRMED"
    case applying = "APPLYING"
    case applied = "APPLIED"
    case discarded = "DISCARDED"
    case errored = "ERRORED"
    case canceled = "CANCELED"
}

class TerraformRun: ObservableObject, Identifiable {
    var id = UUID()
    var number = 0
    var workspace: Workspace
    var createdAt = Date()
    var autoApply = false
    var message: String?
    
    @Published var status: RunStatus = .pending
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var plan: StructuredLog?
    @Published var apply: StructuredLog?
    
    @Published var added: Int?
    @Published var changed: Int?
    @Published var destroyed: Int?
    
    var isFinished: Bool {
        switch status {
        case .applied, .errored, .discarded, .canceled:
            return true
        default:
            return false
        }
    }
    var canConfirm: Bool {
        status == .planned && apply == nil
    }
    var canDiscard: Bool {
        !isFinished && apply == nil
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        doPlan({ plan, error in
            
        })
    }
    
    func doDiscard() {
        guard canDiscard else { return }
        status = .discarded
    }
    
    func doPlan(_ completion: @escaping (_ plan: StructuredLog?, _ error: String?) -> Void) {
        guard let workingDirectory = workspace.workingDirectory else { return }
        workspace.lock(self)
        status = .planning
        
        self.workspace.runner.plan(workingDirectory: workingDirectory, runId: self.id.uuidString, completion: { res, error in
            self.workspace.unlock()
            self.status = .planned
            
            if let res = res {
                self.plan = handleNDJsonSuccess(res)
                self.workspace.isValid = true
            }
            
            if let error = error {
                self.errorMessage = error.message
                self.plan = handleNDJsonSuccess(error.output)
                print(error)
                self.workspace.isValid = false
                self.status = .errored
            }
            
            self.workspace.didPlan(run: self, plan: self.plan)
            
            completion(self.plan, self.errorMessage)
            self.objectWillChange.send()
        })
    }
    
    func doApply(_ completion: @escaping (_ apply: StructuredLog?, _ error: String?) -> Void) {
        if status == .discarded { return }
        
        status = .confirmed
        
        guard let workingDirectory = workspace.workingDirectory else { return }
        workspace.lock(self)
        status = .applying
        
        workspace.runner.apply(workingDirectory: workingDirectory, completion: { res, error in
            self.workspace.unlock()
            self.status = .applied
            
            if let res = res {
                self.apply = handleNDJsonSuccess(res)
                self.workspace.isValid = true
                
                if let changes = self.apply?.changeSummaries.last {
                    self.added = changes.changes.add
                    self.changed = changes.changes.change
                    self.destroyed = changes.changes.remove
                }
            }
            
            if let error = error {
                self.errorMessage = error.message
                self.apply = handleNDJsonSuccess(error.output)
                self.workspace.isValid = false
                self.status = .errored
            }
            
            self.workspace.didApply(run: self, apply: self.apply)
            
            completion(self.apply, self.errorMessage)
            self.objectWillChange.send()
        })
    }
}

extension TerraformRun: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    static func ==(lhs: TerraformRun, rhs: TerraformRun) -> Bool {
        return lhs === rhs
    }
}
