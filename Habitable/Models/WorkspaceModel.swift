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

// break out plan, apply, show, etc runners
class Workspace: ObservableObject {
    var id = UUID()

    @Published var runner = Runner()

    // state
    @Published var locked = false
    @Published var lockedBy: TerraformRun?

    // config
    @Published var isValid = false
    @Published var isInitialized = false
    @Published var hasState = false
    @Published var hasVariables = false

    // settings
    @Published var workingDirectory: URL?
//    @AppStorage("workingDirectory") var workingDirectory: URL?
    @AppStorage("lastWorkingDirectory") var lastWorkingDirectory: URL?
    @Published var description = ""
    @Published var autoApply = false
    @Published var terraformVersion = "0.15.3"

    // data
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var runs: [TerraformRun] = []
    @Published var state: ShowMessage?
    @Published var terraformVariables: [TerraformVariable] = []
    @Published var environmentVariables: [EnvironmentVariable] = []

    init(dir: URL? = nil) {
        if dir == nil, let lastDir = lastWorkingDirectory {
            workingDirectory = lastDir
            updateWorkingDirectory(dir: lastDir)
            return
        }
        if let dir = dir {
            workingDirectory = dir
            updateWorkingDirectory(dir: dir)
        }
    }
    
//    init(path: String? = nil) {
//        if let path = path {
//            let dir = URL(fileURLWithPath: path)
//            workingDirectory = dir
//            updateWorkingDirectory(dir: dir)
//        }
//    }
    
    func reset() {
        textOutput = nil
        errorMessage = nil
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
        workingDirectory = dir
        lastWorkingDirectory = dir

        var isDir: ObjCBool = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dir.appendingPathComponent(".terraform").path, isDirectory: &isDir) {
            isInitialized = true
        }
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfstate").path, isDirectory: &isDir) {
            hasState = true
            refreshResources()
        }
        
        checkVariables()
        validate()
    }
    
    func checkVariables() {
        guard let dir = workingDirectory else { return }
        
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfvars").path, isDirectory: &isDir) {
            hasVariables = true
            parseTextVariables(file: dir.appendingPathComponent("terraform.tfvars"))
        }
        isDir = false
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfvars.json").path, isDirectory: &isDir) {
            hasVariables = true
            parseJSONVariables(file: dir.appendingPathComponent("terraform.tfvars.json"))
        }
        
        parseEnvironmentVariables()
    }
    
    private func parseEnvironmentVariables() {
        environmentVariables = []
        for (key, value) in ProcessInfo.processInfo.environment {
            if !key.hasPrefix("TF_VAR_") { continue }
            let variable = EnvironmentVariable()
            variable.key = key
            variable.value = value
            environmentVariables.append(variable)
        }
    }
    
    private func parseTextVariables(file: URL) {
        do {
            terraformVariables = []
            let vars = try String(contentsOf: file)
            for v in vars.split(separator: "\n") {
                let parts = v.split(separator: "=")
                                
                let variable = TerraformVariable()
                variable.key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                if parts.count > 1 {
                    // TODO parse json value
                    variable.value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                terraformVariables.append(variable)
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    private func parseJSONVariables(file: URL) {
        let json = JSON.init(file)
        for (key, value):(String, JSON) in json {
            let variable = TerraformVariable()
            variable.key = key
            variable.value = value.string ?? ""
            terraformVariables.append(variable)
        }
    }

    private func cleanANSI(_ input: String) -> String {
        return input.replacingOccurrences(of: #"\[([0-9])+m"#, with: "", options: .regularExpression, range: nil)
    }

    func initialize() {
        guard let workingDirectory = self.workingDirectory else { return }
        reset()
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
            self.objectWillChange.send()
        })
    }
    
    func validate() {
        guard let workingDirectory = self.workingDirectory else { return }
        reset()
        locked = true
        runner.validate(workingDirectory: workingDirectory, completion: { res, error in
            self.locked = false
            if let error = error {
                self.errorMessage = error.message
                self.isValid = false
            }
            if let _ = res {
                self.isValid = true
            }
            self.objectWillChange.send()
        })
    }
    
    func refreshResources() {
        guard let workingDirectory = workingDirectory else { return }
        lock()
        
        runner.show(workingDirectory: workingDirectory, completion: { res, error in
            self.unlock()
            
            if let res = res {
                let json = parseJsonOutput(res)
                self.state = transformShow(json)
                self.isValid = true
            }
            
            if let error = error {
                self.errorMessage = error.message
                self.isValid = false
            }
        })
    }
    
//    func show() {
//        guard let workingDirectory = self.workingDirectory else { return }
//        locked = true
//        runner.validate(workingDirectory: workingDirectory, completion: { res, error in
//            self.locked = false
//            if let error = error {
//                self.errorMessage = error.message
//                self.isValid = false
//            }
//            if let res = res {
//                self.textOutput = self.cleanANSI(res)
//                self.isValid = true
//            }
//        })
//    }
    
    func didPlan(run: TerraformRun, plan: StructuredLog) {
        if self.autoApply {
            run.doApply({ apply, error in
                
            })
        }
    }
    
    func didApply(run: TerraformRun, apply: StructuredLog) {
        for run in runs {
            run.doDiscard()
        }
        refreshResources()
    }
    
    func lock(_ by: TerraformRun? = nil) {
        lockedBy = by
        locked = true
    }
    func unlock() {
        lockedBy = nil
        locked = false
    }

    func queueRun(_: String? = nil) {
        if locked {
            return
        }
        let run = TerraformRun(workspace: self)
        run.number = runs.count + 1
        runs.append(run)
    }
    
    func addTerraformVariable(_ variable: TerraformVariable) {
        terraformVariables.append(variable)
    }
    
    func addEnvironmentVariable(_ variable: EnvironmentVariable) {
        environmentVariables.append(variable)
    }
}
