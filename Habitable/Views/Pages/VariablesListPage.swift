//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct TerraformVariableSummaryView: View {
    @ObservedObject var variable: TerraformVariable

    private var safeValuePreview: String {
        if variable.rememberedSecretUnavailable { return "Remembered value unavailable" }
        if variable.sensitive { return "Sensitive value hidden" }
        if !variable.isUserInput && variable.discoveredSource == nil { return "No value supplied" }
        return variable.value.isEmpty ? "(empty)" : variable.value
    }

    private var status: String {
        if variable.isUserInput {
            if let source = variable.discoveredSource { return "Habitable value · overrides \(source)" }
            return "Habitable value · used for plans"
        }
        if let source = variable.discoveredSource { return "Value from \(source)" }
        if variable.hasUnresolvedDiscoveredValue {
            if let source = variable.unresolvedSource { return "Value from \(source) could not be resolved without Terraform" }
            return "Value could not be resolved without Terraform"
        }
        if variable.declaration?.hasDefault == true { return "Uses Terraform default" }
        return variable.declaration?.required == true ? "Required · unset" : "Optional · unset"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variable.key).font(.body.weight(.medium))
            let details = variable.declaration?.description ?? variable.description
            if !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(details)
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let type = variable.declaration?.type {
                    let compactType = type.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    Text(compactType).lineLimit(1).truncationMode(.middle)
                        .help(type).accessibilityLabel("Type: \(type)")
                }
                if variable.declaration?.required == true { Text("Required") }
                if variable.declaration?.hasDefault == true { Text("Default") }
                if variable.sensitive { Label("Sensitive", systemImage: "eye.slash") }
                if variable.declaration?.ephemeral == true { Text("Ephemeral") }
                if variable.isRemembered { Text("Remembered") }
                else if variable.isUserInput { Text("This session") }
                if variable.rememberedSecretUnavailable { Text("Unavailable") }
            }
            .font(.caption).foregroundColor(.secondary).lineLimit(2)
            Text(status).font(.callout.weight(.medium))
                .foregroundStyle(variable.isUserInput || variable.discoveredSource != nil ? .primary : .secondary)
            if variable.isUserInput || variable.discoveredSource != nil {
                Text(safeValuePreview).font(.callout).foregroundColor(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            if let source = variable.declaration?.sourceLocation {
                Text("Declared in \(source)").font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
private struct TerraformVariableEditorContext: Identifiable {
    let id = UUID()
    let draft: TerraformVariable
    let original: TerraformVariable?
}

struct VariableListPage: View {
    @EnvironmentObject var workspace: Workspace
    
    @State private var terraformEditorContext: TerraformVariableEditorContext?
    @State private var inputError: String?
    @State private var requiredOnly = false

    private var visibleVariables: [TerraformVariable] {
        workspace.terraformVariables.filter { !requiredOnly || $0.declaration?.required == true }
    }

    private var missingRequiredCount: Int {
        workspace.terraformVariables.filter {
            $0.declaration?.required == true && !$0.isUserInput
                && $0.discoveredSource == nil && !$0.hasUnresolvedDiscoveredValue
        }.count
    }

    var body: some View {
        VStack(alignment: .leading) {
            if !workspace.terraformInputDiagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Some Terraform inputs could not be inspected", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                    ForEach(Array(workspace.terraformInputDiagnostics.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if let error = workspace.rememberedInputsError {
                Text(error).foregroundColor(.red).font(.caption).padding(.horizontal)
            }
            HStack(spacing: 10) {
                if workspace.isInspectingInputs {
                    ProgressView().controlSize(.small)
                    Text("Checking Terraform inputs…").foregroundStyle(.secondary)
                } else if missingRequiredCount > 0 {
                    Label("\(missingRequiredCount) required input\(missingRequiredCount == 1 ? "" : "s") need a value",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else if !workspace.declaredTerraformInputs.isEmpty {
                    Label("Required inputs are set", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !workspace.declaredTerraformInputs.isEmpty {
                    Toggle("Required only", isOn: $requiredOnly)
                        .toggleStyle(.button)
                        .help("Show only root inputs without a Terraform default")
                }
            }
            .font(.callout).padding(.horizontal, 16).padding(.vertical, 8)
            List {
                ForEach(visibleVariables, id: \.id) { variable in
                    HStack {
                        TerraformVariableSummaryView(variable: variable)
                        Spacer()
                        if variable.isUserInput {
                            Button("Edit") { openEditor(for: variable) }
                                .buttonStyle(.borderless).disabled(workspace.locked)
                            Button(role: .destructive) { remove(variable) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).disabled(workspace.locked)
                                .accessibilityLabel("Remove app input \(variable.key)")
                                .help("Remove app input")
                        } else if variable.declaration != nil {
                            Button(variable.discoveredSource == nil ? "Set value" : "Override") { openEditor(for: variable) }
                                .buttonStyle(.borderless).disabled(workspace.locked)
                                .accessibilityLabel("Set value for \(variable.key)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .overlay {
                if visibleVariables.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: requiredOnly && !workspace.terraformVariables.isEmpty ? "line.3.horizontal.decrease.circle" : "text.badge.plus")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(requiredOnly && !workspace.terraformVariables.isEmpty ? "No required inputs" : "No Terraform inputs").font(.headline)
                        Text(requiredOnly && !workspace.terraformVariables.isEmpty
                             ? "This root module has no required inputs. Turn off Required only to see optional inputs and values."
                             : "Declared root inputs appear here with their type, default, and source. Add an app value only when you want Habitable to override Terraform’s own inputs.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if !requiredOnly || workspace.terraformVariables.isEmpty {
                            Button("Add Terraform input") { openEditor(for: nil) }
                                .disabled(workspace.locked)
                        }
                    }
                    .frame(maxWidth: 420)
                    .padding(20)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Terraform Variables")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { workspace.checkVariables() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .help("Refresh variables")
                }
                .disabled(workspace.locked || workspace.isInspectingInputs)
            }
            ToolbarItem(placement: .primaryAction) {
                // TODO move to footer
                Button(action: {
                    openEditor(for: nil)
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                        Text("Add")
                    }
                }
                .disabled(workspace.locked)
            }
        }
        .sheet(item: $terraformEditorContext) { context in
            TerraformVariableEditor(
                variable: context.draft,
                existingKeys: Set(workspace.terraformVariables.filter { $0.isUserInput && $0 !== context.original }.map(\.key)),
                errorMessage: inputError,
                onCancel: {
                    terraformEditorContext = nil
                    inputError = nil
                },
                onSave: { draft in
                    let isDuplicate = workspace.terraformVariables.contains { $0 !== context.original && $0.isUserInput && $0.key == draft.key }
                    guard draft.validationError == nil, !isDuplicate else { return }
                    do {
                        if let original = context.original {
                            try workspace.updateTerraformVariable(original, key: draft.key, value: draft.value,
                                                                  description: draft.description, sensitive: draft.sensitive, hcl: draft.hcl, remember: draft.isRemembered)
                        } else {
                            try workspace.addTerraformVariable(draft)
                        }
                    } catch { inputError = error.localizedDescription; return }
                    terraformEditorContext = nil
                    inputError = nil
                }
            )
        }
        .alert("Could not remove variable", isPresented: Binding(
            get: { inputError != nil && terraformEditorContext == nil },
            set: { if !$0 { inputError = nil } }
        )) {
            Button("OK", role: .cancel) { inputError = nil }
        } message: { Text(inputError ?? "") }
    }

    private func copy(_ source: TerraformVariable) -> TerraformVariable {
        let result = TerraformVariable()
        result.key = source.key; result.value = source.value; result.description = source.description
        result.sensitive = source.sensitive; result.hcl = source.hcl
        result.isRemembered = source.isRemembered
        result.rememberedSecretUnavailable = source.rememberedSecretUnavailable
        result.rememberedSecretID = source.rememberedSecretID
        result.declaration = source.declaration
        result.discoveredSource = source.discoveredSource
        result.hasUnresolvedDiscoveredValue = source.hasUnresolvedDiscoveredValue
        return result
    }

    private func openEditor(for original: TerraformVariable?) {
        inputError = nil
        if let original, original.isUserInput {
            terraformEditorContext = TerraformVariableEditorContext(draft: copy(original), original: original)
        } else {
            let draft = TerraformVariable()
            if let original {
                draft.key = original.key
                draft.description = original.declaration?.description ?? ""
                draft.sensitive = original.declaration?.sensitive ?? false
                let type = original.declaration?.type ?? "string"
                draft.hcl = type != "string" && type != "any"
            }
            terraformEditorContext = TerraformVariableEditorContext(draft: draft, original: nil)
        }
    }

    private func remove(_ variable: TerraformVariable) {
        do { try workspace.removeTerraformVariable(variable); inputError = nil }
        catch { inputError = error.localizedDescription }
    }
}

private struct TerraformVariableEditor: View {
    @ObservedObject var variable: TerraformVariable
    let existingKeys: Set<String>
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (TerraformVariable) -> Void
    @State private var didAttemptSave = false
    @State private var didEditKey = false

    private var isDuplicate: Bool { existingKeys.contains(variable.key) }

    var body: some View {
        Form {
            Section(header: Text("Save a Terraform variable").font(.headline)) {
                Text("App inputs override workspace tfvars for plans started in Habitable. Choose Remember to keep this input for this workspace; otherwise it lasts for this app session.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Remember for this workspace", isOn: $variable.isRemembered)
                Text("Non-sensitive values are stored in a private local file. Sensitive values are stored in macOS Keychain.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if variable.rememberedSecretUnavailable {
                    Text("This remembered secret is unavailable. Restore Keychain access or remove this input before running Terraform.")
                        .font(.caption).foregroundColor(.red)
                }
                Text("Key").font(.caption).foregroundColor(.secondary)
                TextField("Variable key", text: $variable.key).labelsHidden().accessibilityLabel("Variable key").multilineTextAlignment(.leading)
                Text("Value").font(.caption).foregroundColor(.secondary)
                if variable.sensitive {
                    SecureField("Value", text: $variable.value)
                } else {
                    TextEditor(text: $variable.value)
                        .frame(minHeight: 72)
                        .multilineTextAlignment(.leading)
                }
                Toggle("Value is JSON (list, map, number, boolean, or null)", isOn: $variable.hcl)
                Toggle("Sensitive", isOn: $variable.sensitive)
                    .disabled(variable.declaration?.sensitive == true)
                    .help(variable.declaration?.sensitive == true ? "Terraform declares this input sensitive." : "")
                Text("Hides this value and redacts matching input values from Habitable run logs and reviews. Also mark it sensitive in your Terraform configuration for Terraform’s own output.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Description").font(.caption).foregroundColor(.secondary)
                TextField("Optional description", text: $variable.description).labelsHidden().accessibilityLabel("Optional description")
                    .multilineTextAlignment(.leading)
                if (didEditKey || didAttemptSave), let validationError = variable.validationError {
                    Text(validationError).foregroundColor(.red)
                } else if (didEditKey || didAttemptSave), isDuplicate {
                    Text("A variable with this key already exists.").foregroundColor(.red)
                }
                if let errorMessage { Text(errorMessage).foregroundColor(.red) }
                HStack {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save variable") {
                        didAttemptSave = true
                        guard variable.validationError == nil, !isDuplicate else { return }
                        onSave(variable)
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.all)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 380, idealHeight: 520)
        .onChange(of: variable.key) { _ in didEditKey = true }
    }
}

struct VariableListPage_Previews: PreviewProvider {
    static var previews: some View {
        VariableListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
