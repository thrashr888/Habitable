//
//  Variables.swift
//  Habitable
//
//  Created by Paul Thrasher on 5/4/21.
//

import SwiftUI

struct EnvironmentVariableSummaryView: View {
    @ObservedObject var variable: EnvironmentVariable
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(variable.key) = \(variable.sensitive ? "(sensitive value)" : variable.value)")
            if !variable.description.isEmpty { Text(variable.description).font(.caption).foregroundColor(.secondary) }
            Text(variable.isUserInput ? "App override · This session · Overrides process environment" : "From process environment · Read-only")
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
        }
        .navigationTitle("Environment Variables")
        .toolbar {
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
                                                                    description: draft.description, sensitive: draft.sensitive)
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

    private var isDuplicate: Bool { existingKeys.contains(variable.key) }

    var body: some View {
        Form {
            Section(header: Text("Save an environment variable").font(.headline)) {
                Text("App inputs apply to plans started in this session and override process environment values.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("Key", text: $variable.key)
                Toggle("Sensitive", isOn: $variable.sensitive)
                Text("Hides this value in Habitable. Terraform plan output follows the sensitivity declared in your Terraform configuration.")
                    .font(.caption).foregroundColor(.secondary)
                if variable.sensitive {
                    SecureField("Value", text: $variable.value)
                } else {
                    TextField("Value", text: $variable.value)
                        .multilineTextAlignment(.leading)
                }
                TextField("Description", text: $variable.description)
                    .multilineTextAlignment(.leading)
                if let validationError = variable.validationError {
                    Text(validationError).foregroundColor(.red)
                } else if isDuplicate {
                    Text("An environment variable with this key already exists.").foregroundColor(.red)
                }
                if let errorMessage { Text(errorMessage).foregroundColor(.red) }
                HStack {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { onSave(variable) }
                        .disabled(variable.validationError != nil || isDuplicate)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.all)
    }
}

struct EnvVarListPage_Previews: PreviewProvider {
    static var previews: some View {
        EnvVarListPage()
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
