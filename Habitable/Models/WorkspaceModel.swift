//
//  Workspace.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import Collections
import Foundation
import ShellOut
import SwiftTerm
import SwiftUI
import SwiftyJSON

enum RunStatus: String {
    case pending = "PENDING"
    case planning = "PLANNING"
    case planned = "PLANNED"
    case planQueued = "PLAN_QUEUED"
    case plannedAndFinished = "PLANNED_AND_FINISHED"
    case confirmed = "CONFIRMED"
    case applying = "APPLYING"
    case applied = "APPLIED"
    case applyQueued = "APPLY_QUEUED"
    case discarded = "DISCARDED"
    case errored = "ERRORED"
    case canceled = "CANCELED"
}

class TerraformRun: ObservableObject {
    var id = UUID()
    var workspace: Workspace
    var createdAt = Date()
    var autoApply = false
    var message = ""
    @Published var status: RunStatus = .pending
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var plan: StructuredLog?
    @Published var apply: StructuredLog?
    @Published var startState: ShowMessage?
    @Published var endState: ShowMessage?
    @Published var variables: Variables?

    init(workspace: Workspace) {
        self.workspace = workspace
    }
}

class TerraformVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
    @Published var hcl = false
}

class EnvironmentVariable: ObservableObject {
    var id = UUID()
    @Published var key: String = ""
    @Published var value: String = ""
    @Published var description: String = ""
    @Published var sensitive = false
}

class Variables: ObservableObject {
    @Published var terraformVariables: [TerraformVariable] = []
    @Published var environmentVariables: [EnvironmentVariable] = []
}

// TODO: rename to Workspace
// move all these variables to workspace
// keep shell stuff in a runner
// break out plan, apply, show, etc runners
class Workspace: ObservableObject {
    var id = UUID()

    @Published var runner = Runner()

    // state
    @Published var locked = false
    @Published var lockedBy: TerraformRun?

    // config
    @Published var isValid = true // run `terraform validate`
    @Published var isInitialized = false
    @Published var hasState = false
    @Published var hasVariables = false

    // settings
    @Published var workingDirectory: String?
    @Published var description = ""
    @Published var autoApply = false
    @Published var terraformVersion = "0.15.2"

    // data
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var runs: [TerraformRun] = []
    @Published var state: ShowMessage?
    @Published var variables = Variables()

    init(dir: URL? = nil) {
        if let dir = dir {
            workingDirectory = dir.path
            updateWorkingDirectory(dir: dir)
        }
    }

    func addUrl() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            if response == NSApplication.ModalResponse.OK, let fileUrl = panel.url {
                self.updateWorkingDirectory(dir: fileUrl)
            }
        }
    }

    func save() {
        // save settings to user defaults?
        // there's some ModelState thing in swiftui for this
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

    func initialize() {
        guard let workingDirectory = self.workingDirectory else { return }
        locked = true
        runner.initialize(workingDirectory: workingDirectory, completion: { res, error in
            self.locked = false
            if let error = error {
                self.errorMessage = error.message
                self.isValid = false
            }
            if let res = res {
                self.textOutput = self.cleanANSI(res)
                self.isValid = true
            }
        })
    }

    func validate() {
        // TODO:
        // does initialize do this?
        isValid = true
    }

    func refreshResources() {
//        runner.show(workingDirectory: workingDirectory)
    }

    func queueRun(_: String? = nil) {
        // TODO: we don't actually copy the config over, so queuing doesn't make sense
        // just run a Plan or Apply immediately and lock the workspace
        runs.append(TerraformRun(workspace: self))
    }
}
