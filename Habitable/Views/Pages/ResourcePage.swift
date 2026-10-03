//
//  ResourcePage.swift
//  Habitable
//

import SwiftUI

struct ShowResourceView: View {
    var resource: ShowResource
    var workspaceDirectory: URL? = nil
    var terraformExecutableURL: URL? = nil
    var workspaceInitialized = false
    var onOpenDeclaration: ((String, Int) -> Void)? = nil
    @State private var searchText = ""
    @State private var schemaSearchText = ""
    @State private var showSchemaAttributes = false
    @StateObject private var schemaHelp = TerraformProviderSchemaHelpModel()
    @State private var loadedDocumentationID: String?
    @State private var loadedProviderDocumentation: TerraformProviderDocumentation?
    @State private var loadedModuleDocumentation: TerraformModuleDocumentation?
    @State private var loadedDeclaration: TerraformResourceDeclaration?

    private var documentationID: String { "\(resource.id)-\(resource.address ?? "")-\(workspaceDirectory?.path ?? "")" }

    private var attributes: [ResourceAttribute] {
        resource.displayAttributes
    }

    private var filteredAttributes: [ResourceAttribute] {
        guard !searchText.isEmpty else { return attributes }
        return attributes.filter { $0.searchableText.localizedCaseInsensitiveContains(searchText) }
    }

    private var providerDocumentation: TerraformProviderDocumentation? {
        loadedDocumentationID == documentationID ? loadedProviderDocumentation : nil
    }

    private var builtInResourceDocumentation: URL? {
        guard resource.provider_name == "terraform.io/builtin/terraform",
              resource.type == "terraform_data" else { return nil }
        return URL(string: "https://developer.hashicorp.com/terraform/language/resources/terraform-data")
    }

    private var moduleDocumentation: TerraformModuleDocumentation? {
        loadedDocumentationID == documentationID ? loadedModuleDocumentation : nil
    }

    private var schemaAttributes: [TerraformSchemaAttribute]? {
        schemaHelp.attributes(for: resource.provider_name, resourceType: resource.type, mode: resource.mode)
    }

    private var filteredSchemaAttributes: [TerraformSchemaAttribute] {
        guard let schemaAttributes, !schemaSearchText.isEmpty else { return schemaAttributes ?? [] }
        return schemaAttributes.filter {
            $0.path.localizedCaseInsensitiveContains(schemaSearchText) ||
            ($0.description?.localizedCaseInsensitiveContains(schemaSearchText) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                if let address = resource.address {
                    GridRow(alignment: .top) {
                        Text("Address").foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            SafeCopyButton(value: address, label: "Copy resource address \(address)")
                        }
                    }
                }
                if let provider = resource.provider_name {
                    GridRow(alignment: .top) {
                        Text("Provider").foregroundStyle(.secondary)
                        if let url = providerDocumentation?.providerURL {
                            HStack {
                                Link(provider, destination: url)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help("Open provider documentation for version \(providerDocumentation?.lockedVersion ?? "")")
                                    .accessibilityLabel("Provider documentation for \(provider) version \(providerDocumentation?.lockedVersion ?? "unknown")")
                                SafeCopyButton(value: url.absoluteString, label: "Copy provider documentation URL")
                            }
                        } else {
                            Text(provider).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let mode = resource.mode { metadataRow("Mode", value: mode) }
                if let type = resource.type {
                    GridRow(alignment: .top) {
                        Text("Type").foregroundStyle(.secondary)
                        if let url = providerDocumentation?.resourceURL ?? builtInResourceDocumentation {
                            Link(type, destination: url).fixedSize(horizontal: false, vertical: true)
                                .help("Open documentation for resource type \(type)")
                                .accessibilityLabel("Documentation for resource type \(type)")
                        } else {
                            Text(type).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if resource.provider_name?.hasPrefix("registry.terraform.io/") == true,
                   loadedDocumentationID == documentationID,
                   providerDocumentation?.lockedVersion == nil {
                    GridRow(alignment: .top) {
                        Text("Documentation").foregroundStyle(.secondary)
                        Text("Version unavailable — check .terraform.lock.hcl")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let version = providerDocumentation?.lockedVersion {
                    metadataRow("Provider version", value: version)
                }
                if let module = moduleDocumentation {
                    GridRow(alignment: .top) {
                        Text("Module").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            if let url = module.registryURL {
                                HStack {
                                    Link(module.source, destination: url)
                                        .help("Open module documentation for version \(module.version ?? "")")
                                        .accessibilityLabel("Module documentation for \(module.source) version \(module.version ?? "unknown")")
                                    SafeCopyButton(value: url.absoluteString, label: "Copy module documentation URL")
                                }
                            } else {
                                Text(module.source).textSelection(.enabled)
                            }
                            if let version = module.version {
                                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let name = resource.name { metadataRow("Name", value: name) }
                if let version = resource.schema_version { metadataRow("Schema version", value: String(version)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if loadedDocumentationID == documentationID,
               let address = resource.address,
               let declaration = loadedDeclaration,
               let line = declaration.sourceLine {
                HStack {
                    Text("Declared in \(declaration.sourceFile):\(line)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let onOpenDeclaration {
                        Button("Open declaration") {
                            guard let filename = TerraformDiagnosticSource.currentWorkspaceFile(
                                filename: declaration.sourceFile, workspaceDirectory: workspaceDirectory),
                                  let boundedLine = TerraformDiagnosticSource.boundedLine(
                                    line, in: filename, workspaceDirectory: workspaceDirectory) else { return }
                            onOpenDeclaration(filename, boundedLine)
                        }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            HStack {
                Text("Attributes").font(.headline)
                Spacer()
                Text("\(filteredAttributes.count)").foregroundStyle(.secondary)
                if resource.provider_name != nil {
                    Button {
                        schemaHelp.load(directory: workspaceDirectory, executable: terraformExecutableURL,
                                       workspaceInitialized: workspaceInitialized,
                                       providerIdentity: resource.provider_name,
                                       resourceType: resource.type, mode: resource.mode)
                    } label: {
                        Label("Load attribute help", systemImage: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(schemaHelp.isLoading || !workspaceInitialized || terraformExecutableURL == nil)
                    .help("Read schemas from providers already installed for this workspace. No provider installation runs.")
                }
            }
            if schemaHelp.isLoading(for: resource.provider_name, resourceType: resource.type, mode: resource.mode) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading installed provider schemas…").foregroundStyle(.secondary) }
            } else if let message = schemaHelp.message(for: resource.provider_name, resourceType: resource.type, mode: resource.mode) {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let schemaAttributes, !schemaAttributes.isEmpty {
                DisclosureGroup("Attribute help · \(schemaAttributes.count)", isExpanded: $showSchemaAttributes) {
                    TextField("Search attribute help", text: $schemaSearchText)
                        .textFieldStyle(.roundedBorder)
                    Text("\(filteredSchemaAttributes.count) of \(schemaAttributes.count) attributes")
                        .font(.caption).foregroundStyle(.secondary)
                    if filteredSchemaAttributes.isEmpty {
                        Text("No matching attributes").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredSchemaAttributes) { attribute in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(attribute.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 8) {
                                            if attribute.required { schemaBadge("Required") }
                                            if attribute.optional { schemaBadge("Optional") }
                                            if attribute.computed { schemaBadge("Computed") }
                                            if attribute.sensitive { schemaBadge("Sensitive") }
                                        }
                                        .fixedSize(horizontal: false, vertical: true)
                                            if let type = attribute.type { Text(type).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                            if let description = attribute.description, !description.isEmpty {
                                                Text(description).font(.callout).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                    }
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityElement(children: .combine)
                                    Divider()
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                    }
                }
                .font(.callout)
            }
            if !attributes.isEmpty {
                TextField("Search attributes", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            if filteredAttributes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: searchText.isEmpty ? "list.bullet.rectangle" : "magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No attributes" : "No matches").font(.headline)
                    Text(searchText.isEmpty ? "This resource has no recorded values." : "Try another search.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredAttributes) { attribute in
                    HStack(alignment: .top, spacing: 12) {
                        Text(attribute.path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(minWidth: 150, alignment: .leading)
                        Text(attribute.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SafeCopyButton(value: attribute.value, label: "Copy value for \(attribute.path)")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
        .task(id: documentationID) {
            loadedDeclaration = nil
            let id = documentationID
            let identity = resource.provider_name
            let type = resource.type
            let mode = resource.mode
            let address = resource.address
            let directory = workspaceDirectory
            let inspectionTask = Task.detached(priority: .utility) {
                (TerraformProviderDocumentation.resolve(providerIdentity: identity, resourceType: type,
                    resourceMode: mode, lockFile: directory?.appendingPathComponent(".terraform.lock.hcl")),
                 TerraformModuleDocumentation.resolve(resourceAddress: address, workspaceDirectory: directory),
                 directory.flatMap { root in
                     address.flatMap { TerraformConfigurationInspector.declarations(for: [$0], directory: root)[$0] }
                 })
            }
            let result = await withTaskCancellationHandler(
                operation: { await inspectionTask.value },
                onCancel: { inspectionTask.cancel() })
            guard !Task.isCancelled else { return }
            loadedProviderDocumentation = result.0
            loadedModuleDocumentation = result.1
            loadedDeclaration = result.2
            loadedDocumentationID = id
        }
        .onChange(of: resource.address) { _ in schemaHelp.reset() }
        .onChange(of: workspaceDirectory?.path) { _ in schemaHelp.reset() }
        .onChange(of: terraformExecutableURL?.path) { _ in schemaHelp.reset() }
    }
    private func metadataRow(_ label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func schemaBadge(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
    }
}

struct ShowView: View {
    @State var show: ShowMessage

    var body: some View {
        VStack(alignment: .leading) {
            if !show.root_module.resources.isEmpty {
                Text("Resources").fontWeight(.bold)
                List(show.root_module.resources, id: \.id) { resource in
                    ShowResourceView(resource: resource)
                }
            }
            if !show.values.outputs.isEmpty {
                Text("Outputs").fontWeight(.bold)
                OutputView(outputs: show.values.outputs)
            }
        }
    }
}

struct ShowModuleView: View {
    @State var run: TerraformRun
    var body: some View { Text("id: \(run.id)") }
}
