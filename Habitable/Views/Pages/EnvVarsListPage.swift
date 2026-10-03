//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct EnvironmentVariableSummaryView: View {
    @ObservedObject var variable: EnvironmentVariable

    private var safeValuePreview: String {
        if variable.rememberedSecretUnavailable { return "Remembered value unavailable" }
        if variable.sensitive { return "Sensitive value hidden" }
        return variable.value.isEmpty ? "(empty)" : variable.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variable.key).font(.body.weight(.medium))
            if !variable.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(variable.description).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if variable.sensitive { Text("Sensitive") }
                if variable.isRemembered { Text("Remembered") }
                else if variable.isUserInput { Text("This session") }
                if variable.rememberedSecretUnavailable { Text("Unavailable") }
            }
            .font(.caption).foregroundColor(.secondary)
            Text(safeValuePreview).font(.callout).foregroundColor(.secondary)
                .lineLimit(2).truncationMode(.middle)
            Text(variable.isUserInput
                 ? "Source: Habitable app override · takes precedence over process environment · editable"
                 : "Source: process environment · read-only")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

@MainActor
private struct EnvironmentVariableEditorContext: Identifiable {
    let id = UUID()
    let draft: EnvironmentVariable
    let original: EnvironmentVariable?
}

struct EnvVarListPage: View {
    @EnvironmentObject var workspace: Workspace
    
    @State private var editorContext: EnvironmentVariableEditorContext?
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading) {
            if let error = workspace.rememberedInputsError {
                Text(error).foregroundColor(.red).font(.caption).padding(.horizontal)
            }
            List {
                ForEach(workspace.environmentVariables, id: \.id) { variable in
                    HStack {
                        EnvironmentVariableSummaryView(variable: variable)
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
            .overlay {
                if workspace.environmentVariables.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("No environment variable inputs").font(.headline)
                        Text("Add an environment variable override for Terraform commands started from Habitable.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add environment variable") { openEditor(for: nil) }
                            .disabled(workspace.locked)
                    }
                    .frame(maxWidth: 420)
                    .padding(20)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .toolbar {
            QuietToolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { workspace.checkVariables() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .help("Refresh variables")
                    }
                    .disabled(workspace.locked)
                }
                ToolbarItem(placement: .primaryAction) {
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
        }
        .sheet(item: $editorContext) { context in
            EnvironmentVariableEditor(
                variable: context.draft,
                existingKeys: Set(workspace.environmentVariables.filter { $0.isUserInput && $0 !== context.original }.map(\.key)),
                errorMessage: inputError,
                onCancel: {
                    editorContext = nil
                    inputError = nil
                },
                onSave: { draft in
                    let isDuplicate = workspace.environmentVariables.contains { $0 !== context.original && $0.isUserInput && $0.key == draft.key }
                    guard draft.validationError == nil, !isDuplicate else { return }
                    do {
                        if let original = context.original {
                            try workspace.updateEnvironmentVariable(original, key: draft.key, value: draft.value,
                                                                    description: draft.description, sensitive: draft.sensitive, remember: draft.isRemembered)
                        } else {
                            try workspace.addEnvironmentVariable(draft)
                        }
                    } catch { inputError = error.localizedDescription; return }
                    editorContext = nil
                    inputError = nil
                }
            )
        }
        .alert("Could not remove environment variable", isPresented: Binding(
            get: { inputError != nil && editorContext == nil },
            set: { if !$0 { inputError = nil } }
        )) {
            Button("OK", role: .cancel) { inputError = nil }
        } message: { Text(inputError ?? "") }
    }

    private func copy(_ source: EnvironmentVariable) -> EnvironmentVariable {
        let result = EnvironmentVariable()
        result.key = source.key; result.value = source.value; result.description = source.description
        result.sensitive = source.sensitive
        result.isRemembered = source.isRemembered
        result.rememberedSecretUnavailable = source.rememberedSecretUnavailable
        result.rememberedSecretID = source.rememberedSecretID
        return result
    }

    private func openEditor(for original: EnvironmentVariable?) {
        inputError = nil
        editorContext = EnvironmentVariableEditorContext(
            draft: original.map(copy) ?? EnvironmentVariable(), original: original
        )
    }

    private func remove(_ variable: EnvironmentVariable) {
        do { try workspace.removeEnvironmentVariable(variable); inputError = nil }
        catch { inputError = error.localizedDescription }
    }
}

private struct EnvironmentVariableEditor: View {
    @ObservedObject var variable: EnvironmentVariable
    let existingKeys: Set<String>
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (EnvironmentVariable) -> Void
    @State private var didAttemptSave = false
    @State private var didEditKey = false

    private var isDuplicate: Bool { existingKeys.contains(variable.key) }

    var body: some View {
        Form {
            Section(header: Text("Save an environment variable").font(.headline)) {
                Text("App inputs override process environment values for plans started in Habitable. Choose Remember to keep this input for this workspace; otherwise it lasts for this app session.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Remember for this workspace", isOn: $variable.isRemembered)
                Text("Non-sensitive values are stored in a private local file. Sensitive values are stored in macOS Keychain.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if variable.rememberedSecretUnavailable {
                    Text("This remembered secret is unavailable. Restore Keychain access or remove this input before running Terraform.")
                        .font(.caption).foregroundColor(.red)
                }
                Text("Key").font(.caption).foregroundColor(.secondary)
                TextField("Environment variable key", text: $variable.key)
                    .labelsHidden().accessibilityLabel("Environment variable key")
                    .multilineTextAlignment(.leading)
                Toggle("Sensitive", isOn: $variable.sensitive)
                Text("Hides this value in Habitable. Terraform plan output follows the sensitivity declared in your Terraform configuration.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Value").font(.caption).foregroundColor(.secondary)
                if variable.sensitive {
                    SecureField("Value", text: $variable.value)
                        .labelsHidden().accessibilityLabel("Sensitive value")
                } else {
                    TextField("Value", text: $variable.value)
                        .labelsHidden().accessibilityLabel("Value")
                        .multilineTextAlignment(.leading)
                }
                Text("Description").font(.caption).foregroundColor(.secondary)
                TextField("Optional description", text: $variable.description)
                    .labelsHidden().accessibilityLabel("Description")
                    .multilineTextAlignment(.leading)
                if (didEditKey || didAttemptSave), let validationError = variable.validationError {
                    Text(validationError).foregroundColor(.red)
                } else if (didEditKey || didAttemptSave), isDuplicate {
                    Text("An environment variable with this key already exists.").foregroundColor(.red)
                }
                if let errorMessage { Text(errorMessage).foregroundColor(.red) }
                HStack {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        didAttemptSave = true
                        guard variable.validationError == nil, !isDuplicate else { return }
                        onSave(variable)
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.all)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 500)
        .onChange(of: variable.key) { _ in didEditKey = true }
    }
}

struct EnvVarListPage_Previews: PreviewProvider {
    static var previews: some View {
        EnvVarListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
