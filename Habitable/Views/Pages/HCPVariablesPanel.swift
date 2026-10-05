import SwiftUI

/// Width of the variables table, used to switch between wide and compact rows.
struct VariablesTableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Small capsule used for provenance and attribute badges in variable tables.
struct VariableChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .lineLimit(1).truncationMode(.middle)
    }
}

struct HCPMapVariablesPanel: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @State private var editing: HCPWorkspaceVariable?
    @State private var query = ""
    @State private var tableWidth: CGFloat = 1000

    private var compact: Bool { tableWidth < 760 }
    private var keyWidth: CGFloat { min(320, max(180, tableWidth * 0.28)) }

    private var rows: [HCPWorkspaceVariable] {
        ["terraform", "env"].flatMap { category in
            model.workspaceVariables.filter {
                $0.category == category && (query.isEmpty || $0.key.localizedCaseInsensitiveContains(query))
            }
        }
    }

    private var columnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Key").frame(width: compact ? nil : keyWidth, alignment: .leading)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            if !compact {
                Text("Value").frame(maxWidth: .infinity, alignment: .leading)
                Text("Category").frame(width: 190, alignment: .leading)
            }
            Text("Actions").frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold)).textCase(.uppercase)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.selectedWorkspace?.name ?? "Workspace").font(.headline)
                Text("Changes affect future runs").font(.callout).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter variables", text: $query).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260).accessibilityLabel("Filter workspace variables")
                Button { Task { await model.refreshVariables() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh workspace variables")
                    .disabled(model.isLoadingVariables || model.savingVariableID != nil)
            }
            if model.isLoadingVariables { ProgressView("Loading variables…") }
            if let error = model.variablesError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !rows.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, variable in
                                    HCPVariableRow(
                                        variable: variable, index: index, compact: compact, keyWidth: keyWidth,
                                        editDisabled: model.savingVariableID != nil,
                                        onEdit: { editing = variable })
                                    Divider()
                                }
                            } header: {
                                columnHeader
                            }
                        }
                    }
                    if !query.isEmpty && !model.workspaceVariables.contains(where: { $0.key.localizedCaseInsensitiveContains(query) }) {
                        Text("No matching variables").font(.headline)
                        Button("Clear filter") { query = "" }.buttonStyle(.borderless)
                    }
                    if !model.isLoadingVariables && model.workspaceVariables.isEmpty && model.variablesError == nil {
                        Text("No workspace-specific variables").font(.headline)
                    }
                    Text("Inherited variable sets and values from configuration files are not included here.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let url = model.selectedWorkspace?.htmlURL {
                        Link("Open workspace in HCP Terraform", destination: url)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: VariablesTableWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(VariablesTableWidthKey.self) { tableWidth = $0 }
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .task { await model.refreshVariables() }
        .sheet(item: $editing) { variable in
            HCPMapVariableEditor(model: model, variable: variable, sourceKey: model.mapRequestKey)
        }
    }
}

private struct HCPVariableRow: View {
    let variable: HCPWorkspaceVariable
    let index: Int
    let compact: Bool
    let keyWidth: CGFloat
    let editDisabled: Bool
    let onEdit: () -> Void

    private var mono: Font { .system(size: 13, design: .monospaced) }

    private var keyCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(variable.key).font(mono.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                MapCopyButton(value: variable.key, label: "variable name")
            }
            if !variable.description.isEmpty {
                Text(variable.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder private var valueCell: some View {
        if variable.isMaskedForDisplay {
            Label("Private value · hidden", systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        } else if let value = variable.value, !value.isEmpty {
            Text(value).font(mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        } else {
            Text("Empty value").font(.system(size: 13)).italic().foregroundStyle(.secondary)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            VariableChip(text: variable.category == "env" ? "Environment" : "Terraform")
            if variable.isHCL { VariableChip(text: "HCL").accessibilityLabel("HCL expression") }
            if variable.isSensitive { VariableChip(text: "Sensitive", systemImage: "lock.fill") }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let value = variable.value, !variable.isMaskedForDisplay { MapCopyButton(value: value, label: "variable value") }
            Button("Edit") { onEdit() }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit variable \(variable.key)")
                .disabled(editDisabled)
        }
        .frame(width: 100, alignment: .trailing)
    }

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        keyCell
                        valueCell
                        chips
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    keyCell.frame(width: keyWidth, alignment: .leading)
                    valueCell.frame(maxWidth: .infinity, alignment: .leading)
                    chips.frame(width: 190, alignment: .leading)
                    actions
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(index % 2 == 1 ? Color.primary.opacity(0.025) : Color.clear)
        .accessibilityElement(children: .contain)
    }
}


struct HCPMapVariableEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: HCPWorkspaceViewerModel
    let variable: HCPWorkspaceVariable
    let sourceKey: String
    @State private var value: String
    @State private var didEdit = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(model: HCPWorkspaceViewerModel, variable: HCPWorkspaceVariable, sourceKey: String) {
        self.model = model; self.variable = variable; self.sourceKey = sourceKey
        _value = State(initialValue: variable.isMaskedForDisplay ? "" : (variable.value ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(variable.key)").font(.title2.weight(.semibold))
            Text(model.selectedWorkspace?.name ?? "Workspace").foregroundStyle(.secondary)
            Text("Saving updates this workspace variable in HCP Terraform. It does not start a run or change the current state.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            if variable.isMaskedForDisplay {
                Text("The current value is hidden. Enter a replacement only if you intend to change it.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("Replacement value", text: $value).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Replacement sensitive variable value")
            } else {
                Text(variable.isHCL ? "HCL value" : "Value").font(.headline)
                TextEditor(text: $value).font(.system(.body, design: .monospaced))
                    .frame(height: 140).border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("Variable value")
            }
            if let saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save to HCP Terraform") {
                    guard sourceKey == model.mapRequestKey else { return }
                    isSaving = true; saveError = nil
                    Task {
                        let saved = await model.updateVariable(variableID: variable.id, value: value)
                        isSaving = false
                        if saved { dismiss() } else { saveError = model.variablesError ?? "The variable could not be saved." }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !didEdit || sourceKey != model.mapRequestKey || (!variable.isMaskedForDisplay && value == (variable.value ?? "")))
            }
        }
        .padding(24).frame(width: 510)
        .onChange(of: value) { _ in didEdit = true }
        .onChange(of: model.mapRequestKey) { _ in dismiss() }
        .interactiveDismissDisabled(isSaving)
    }
}
