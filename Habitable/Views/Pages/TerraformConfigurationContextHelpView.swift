import SwiftUI

struct TerraformConfigurationContextHelpView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var configuration: ConfigurationModel
    @StateObject private var model = TerraformConfigurationContextHelpModel()
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Provider and module help", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Declaration details from the saved configuration")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Load") { model.load(directory: workspace.workingDirectory) }
                        .buttonStyle(.borderless)
                        .disabled(model.isLoading || workspace.workingDirectory == nil)
                        .accessibilityLabel("Load provider and module help")
                }
                if model.isLoading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading declarations…").foregroundStyle(.secondary) }
                        .font(.callout)
                }
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let context = model.context {
                    ScrollView {
                        TerraformConfigurationContextResults(context: context)
                    }
                    .frame(maxHeight: 240)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
        .onChange(of: workspace.workingDirectory) { _ in model.reset() }
        .onChange(of: configuration.savedText) { _ in model.reset() }
        .onChange(of: configuration.diskChanged) { changed in if changed { model.reset() } }
    }

}

private struct TerraformConfigurationContextResults: View {
    let context: TerraformWorkspaceContextHelp
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if !context.providers.isEmpty { TerraformProviderHelpList(providers: context.providers) }
            if !context.inputs.isEmpty || !context.outputs.isEmpty {
                TerraformDeclarationHelpSection(title: "Root module", inputs: context.inputs, outputs: context.outputs)
            }
            if !context.modules.isEmpty { TerraformModuleHelpList(modules: context.modules) }
            if !context.requiredCore.isEmpty {
                Text("Terraform CLI constraint: \(context.requiredCore.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(context.diagnostics.enumerated()), id: \.offset) { item in
                Text(item.element).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TerraformProviderHelpList: View {
    let providers: [TerraformProviderContextHelp]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Providers · \(providers.count)").font(.subheadline.weight(.semibold))
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    if let url = provider.documentationURL, let version = provider.lockedVersion {
                        Link("\(provider.name) · \(version)", destination: url)
                            .accessibilityLabel("Provider documentation for \(provider.source) version \(version)")
                    } else { Text(provider.name).font(.callout.weight(.medium)) }
                    Text(provider.source).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if provider.lockedVersion == nil { Text("Locked version unavailable; documentation link omitted.").font(.caption).foregroundStyle(.secondary) }
                    if !provider.constraints.isEmpty { Text("Constraint: \(provider.constraints.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                    if !provider.aliases.isEmpty { Text("Aliases: \(provider.aliases.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TerraformModuleHelpList: View {
    let modules: [TerraformModuleContextHelp]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Declared and installed modules · \(modules.count)").font(.subheadline.weight(.semibold))
            ForEach(modules) { module in TerraformModuleHelpRow(module: module) }
        }
    }
}

private struct TerraformModuleHelpRow: View {
    let module: TerraformModuleContextHelp
    var body: some View {
        DisclosureGroup {
            if let url = module.documentationURL, let version = module.installedVersion {
                Link("Documentation · \(version)", destination: url)
                    .accessibilityLabel("Module documentation for \(module.source) version \(version)")
            }
            if let metadata = module.metadata {
                TerraformDeclarationHelpSection(title: module.key, inputs: metadata.inputs, outputs: metadata.outputs)
                if !metadata.providers.isEmpty {
                    Text("Providers: \(metadata.providers.map(\.name).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Declaration details are unavailable for this module folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.key + (module.installedVersion.map { " · \($0)" } ?? ""))
                    .font(.callout.weight(.medium))
                Text(module.source).font(.caption.monospaced()).foregroundStyle(.secondary)
                if module.installedVersion == nil {
                    Text(module.declaredVersion.map { "Declared version: \($0); module is not installed." }
                        ?? "Module is not installed; documentation link omitted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TerraformDeclarationHelpSection: View {
    let title: String
    let inputs: [TerraformDeclaredInput]
    let outputs: [TerraformOutputMetadata]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if !inputs.isEmpty {
                DisclosureGroup("Inputs · \(inputs.count)") {
                    ForEach(inputs) { input in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(input.name)\(input.required ? " · required" : "")\(input.sensitive ? " · sensitive" : "")")
                                .font(.caption.monospaced())
                            if let type = input.type { Text(type).font(.caption2).foregroundStyle(.secondary) }
                            if let description = input.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !outputs.isEmpty {
                DisclosureGroup("Outputs · \(outputs.count)") {
                    ForEach(outputs) { output in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(output.name)\(output.sensitive ? " · sensitive" : "")").font(.caption.monospaced())
                            if let type = output.type { Text(type).font(.caption2).foregroundStyle(.secondary) }
                            if let description = output.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
