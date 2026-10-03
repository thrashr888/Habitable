//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct TerraformVariableSummaryView: View {
    @ObservedObject var variable: TerraformVariable
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("\(variable.key)")
                Spacer()
                if variable.sensitive {
                    Text("(sensitive)")
                        .foregroundColor(.secondary)
                }
                if variable.hcl {
                    Text("(HCL)")
                        .foregroundColor(.secondary)
                }
            }
            Text(variable.rememberedSecretUnavailable ? "(remembered value unavailable)" : variable.sensitive ? "(sensitive value)" : variable.value)
                .foregroundColor(.secondary)
            if !variable.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(variable.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(variable.isUserInput ? "App override · \(variable.isRemembered ? "Remembered for this workspace" : "This session") · Overrides workspace tfvars" : "From workspace tfvars · Read-only")
                .font(.caption).foregroundColor(.secondary)
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

    var body: some View {
        VStack(alignment: .leading) {
            if let error = workspace.rememberedInputsError {
                Text(error).foregroundColor(.red).font(.caption).padding(.horizontal)
            }
            if workspace.terraformVariables.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.plus").font(.largeTitle).foregroundColor(.secondary)
                    Text("No Terraform inputs").font(.headline)
                    Text("Values from workspace tfvars appear here as read-only inputs. Add an app override to supply or replace a value for plans started from Habitable.")
                        .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
                    Button("Add Terraform input") { openEditor(for: nil) }
                        .disabled(workspace.locked)
                        .accessibilityHint("Create an app override for a Terraform variable")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            } else {
                List {
                    ForEach(workspace.terraformVariables, id: \.id) { variable in
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
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
        .navigationTitle("Terraform Variables")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { workspace.checkVariables() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .help("Refresh variables")
                }
                .disabled(workspace.locked)
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
        return result
    }

    private func openEditor(for original: TerraformVariable?) {
        inputError = nil
        terraformEditorContext = TerraformVariableEditorContext(
            draft: original.map(copy) ?? TerraformVariable(), original: original
        )
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
                TextField("Variable key", text: $variable.key).multilineTextAlignment(.leading)
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
                Text("Hides this value and redacts matching input values from Habitable run logs and reviews. Also mark it sensitive in your Terraform configuration for Terraform’s own output.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Description").font(.caption).foregroundColor(.secondary)
                TextField("Optional description", text: $variable.description)
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
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
