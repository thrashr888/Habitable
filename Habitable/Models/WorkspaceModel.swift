//
//  Workspace.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import Foundation
import SwiftUI
import SwiftyJSON

// break out plan, apply, show, etc runners
class Workspace: ObservableObject {
    var id = UUID()

    @Published var runner: Runner
    @Published var managedTerraformVersion: String?
    private let preferences: UserDefaults

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
    @Published var terraformVersion = "Checking…"

    // data
    @Published var textOutput: String?
    @Published var errorMessage: String?
    @Published var runs: [TerraformRun] = []
    @Published var state: ShowMessage?
    @Published var terraformVariables: [TerraformVariable] = []
    @Published var environmentVariables: [EnvironmentVariable] = []

    init(dir: URL? = nil, restoreLastDirectory: Bool = true, defaults: UserDefaults = .standard) {
        preferences = defaults
        managedTerraformVersion = defaults.string(forKey: TerraformReleaseService.selectionKey)
        runner = Runner(executableURL: TerraformReleaseService.selectedExecutable(defaults: defaults))
        refreshTerraformVersion()
        if restoreLastDirectory, dir == nil, let lastDir = lastWorkingDirectory {
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
    
    func useTerraform(version: String?, executableURL: URL?) {
        guard !locked else { return }
        // Saved plans belong to the CLI that created them. Require a fresh plan after switching.
        for run in runs { run.doDiscard() }
        managedTerraformVersion = version
        preferences.set(version, forKey: TerraformReleaseService.selectionKey)
        runner = Runner(executableURL: executableURL)
        terraformVersion = "Checking…"
        state = nil
        isValid = false
        refreshTerraformVersion()
        if workingDirectory != nil { validate() }
    }

    func refreshTerraformVersion() {
        let currentRunner = runner
        runner.version { output, error in
            guard self.runner === currentRunner else { return }
            if let output = output, let data = output.data(using: .utf8),
               let json = try? JSON(data: data), let version = json["terraform_version"].string {
                self.terraformVersion = version
            } else {
                self.terraformVersion = "Unavailable"
                self.errorMessage = error?.message
            }
        }
    }

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
        guard !locked else { return }
        for run in runs { run.doDiscard() }
        runs = []
        state = nil
        isInitialized = false
        isValid = false
        hasState = false
        hasVariables = false
        terraformVariables = []
        workingDirectory = dir
        lastWorkingDirectory = dir

        var isDir: ObjCBool = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dir.appendingPathComponent(".terraform").path, isDirectory: &isDir) {
            isInitialized = true
        }
        if fileManager.fileExists(atPath: dir.appendingPathComponent("terraform.tfstate").path, isDirectory: &isDir) {
            hasState = true
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
                guard parts.count > 1 else { continue }
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
        guard !locked, let workingDirectory = self.workingDirectory else { return }
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
                self.isInitialized = true
                self.validate()
            }
            self.objectWillChange.send()
        })
    }
    
    func validate() {
        guard !locked, let workingDirectory = self.workingDirectory else { return }
        reset()
        locked = true
        runner.validate(workingDirectory: workingDirectory, completion: { res, error in
            self.locked = false
            if let error = error {
                self.errorMessage = error.message
                self.isValid = false
            }
            if res != nil {
                self.isValid = true
                if self.hasState { self.refreshResources() }
            }
            self.objectWillChange.send()
        })
    }
    
    func refreshResources() {
        guard let workingDirectory = workingDirectory else { return }
        guard !locked else { return }
        lock()
        
        runner.show(workingDirectory: workingDirectory, completion: { res, error in
            self.unlock()
            
            if let res = res {
                let json = parseJsonOutput(res)
                self.state = transformShow(json)
                self.hasState = self.state != nil
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
        if locked || !isValid {
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
