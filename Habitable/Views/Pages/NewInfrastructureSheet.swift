import AppKit
import SwiftUI

/// Exploration F: GarageBand's project chooser, for infrastructure. Start from a
/// folder you already have, an HCP Terraform workspace, or a template that shows
/// the resources it creates and roughly what they cost before anything is written.
struct NewInfrastructureSheet: View {
    enum Choice: Hashable { case folder, cloud, category(InfrastructureTemplate.Category) }

    let onOpenFolder: () -> Void
    let onOpenCloud: () -> Void
    /// Called with the folder the template was written into.
    let onCreated: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var choice: Choice = .category(.websites)
    @State private var template: InfrastructureTemplate?
    @State private var inputs: [String: String] = [:]
    @State private var destination: URL = WorkspaceCheckoutStore.ensureCheckoutFolder()
    @State private var folderName = ""
    @State private var error: String?
    @StateObject private var registry = RegistryModulesModel()
    @State private var registryQuery = ""
    @State private var registryProvider = ""
    @State private var registrySelection: RegistryModuleSummary?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HSplitView {
            sidebar.frame(width: 220)
            content.frame(minWidth: 560, maxWidth: .infinity)
        }
        .frame(width: 860, height: 520)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 14)
            sidebarRow("Folder on this Mac…", symbol: "folder", choice: .folder)
            sidebarRow("HCP Terraform workspace…", symbol: "cloud", choice: .cloud)
            Text("Start from a template").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 14)
            ForEach(InfrastructureTemplate.Category.allCases.filter { $0 != .registry }, id: \.self) { category in
                sidebarRow(category.rawValue, symbol: symbol(for: category), choice: .category(category))
            }
            Text("Modules").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 14)
            sidebarRow(InfrastructureTemplate.Category.registry.rawValue, symbol: symbol(for: .registry), choice: .category(.registry))
            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarRow(_ title: String, symbol: String, choice row: Choice) -> some View {
        Button {
            choice = row
            template = nil
            switch row {
            case .folder: dismiss(); onOpenFolder()
            case .cloud: dismiss(); onOpenCloud()
            case .category: break
            }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(choice == row ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func symbol(for category: InfrastructureTemplate.Category) -> String {
        switch category {
        case .websites: return "globe"
        case .apps: return "shippingbox"
        case .databases: return "cylinder"
        case .networks: return "point.3.connected.trianglepath.dotted"
        case .learn: return "book"
        case .playground: return "sparkles"
        case .registry: return "shippingbox.circle"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let template {
            templateDetail(template)
        } else if case .category(.registry) = choice {
            registryPage
        } else if case .category(let category) = choice {
            templateGrid(category)
        } else {
            Text("Choose a template.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func templateGrid(_ category: InfrastructureTemplate.Category) -> some View {
        let templates = InfrastructureTemplates.templates(in: category)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.rawValue).font(.system(size: 17, weight: .semibold))
                    Text("Each template shows the resources it creates before anything is written.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(templates) { item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.system(size: 15, weight: .semibold))
                                Text(item.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(item.provider) · \(item.resourceCount) \(item.resourceCount == 1 ? "resource" : "resources") · \(item.estimatedMonthlyCost)")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 2)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                if templates.isEmpty {
                    Text("Templates for this category appear here as they are added.").foregroundStyle(.secondary).padding(20)
                }
            }
            Divider()
            HStack {
                Text("Creates a folder in \(abbreviated(destination)) with readable .tf files you own.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Registry

    private var registryPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From the registry").font(.system(size: 17, weight: .semibold))
                    Text("Public modules from registry.terraform.io. The folder calls the module; its code stays at the source.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            HStack(spacing: 10) {
                FilterField(placeholder: "Search modules, like vpc or static site", text: $registryQuery, accessibilityLabel: "Search modules")
                    .frame(maxWidth: 360)
                    .onSubmit { runRegistrySearch() }
                    .task(id: registryQuery) {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        runRegistrySearch()
                    }
                Picker("Provider", selection: $registryProvider) {
                    Text("Any provider").tag("")
                    ForEach(["aws", "google", "azurerm", "cloudflare", "kubernetes", "github"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: registryProvider) { _ in runRegistrySearch() }
                if registry.isSearching { LoadingIndicator(size: 14, label: "Searching…") }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if let message = registry.message, registry.results.isEmpty {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(registry.results) { module in
                    Button { selectRegistryModule(module) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("\(module.namespace)/\(module.name)").font(.system(size: 13, weight: .semibold))
                                if module.verified {
                                    Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("Verified")
                                }
                                if registry.isLoadingDetail, registrySelection?.id == module.id { LoadingIndicator(size: 12, label: "Loading…") }
                            }
                            if !module.description.isEmpty {
                                Text(module.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text("\(module.provider) · v\(module.version) · \(downloadsText(module.downloads)) downloads")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("Creates a folder in \(abbreviated(destination)) with a main.tf that calls the module, pinned to its version.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private func runRegistrySearch() {
        Task { await registry.search(query: registryQuery, provider: registryProvider.isEmpty ? nil : registryProvider) }
    }

    private func selectRegistryModule(_ module: RegistryModuleSummary) {
        registrySelection = module
        Task {
            await registry.load(module)
            guard registrySelection?.id == module.id, let detail = registry.detail else { return }
            select(RegistryModules.template(for: detail))
        }
    }

    private func downloadsText(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return "\(count / 1_000)K"
        default: return "\(count)"
        }
    }

    private func select(_ item: InfrastructureTemplate) {
        template = item
        inputs = Dictionary(uniqueKeysWithValues: item.inputs.map { ($0.name, "") })
        folderName = InfrastructureTemplates.suggestedFolderName(item)
        error = nil
    }

    private func templateDetail(_ item: InfrastructureTemplate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 17, weight: .semibold))
                    Text(item.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("\(item.provider) · \(item.resourceCount) \(item.resourceCount == 1 ? "resource" : "resources") · \(item.estimatedMonthlyCost)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(item.links, id: \.url) { link in
                    ExternalLink(title: link.title, url: link.url)
                }
                Button("Back") { template = nil; registry.clearDetail() }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What it creates").font(.headline)
                        if item.category == .registry {
                            Text(item.resources.isEmpty
                                 ? "The module builds from its own submodules, so the Registry lists no resources at the top level. Preview Changes shows what it would create."
                                 : "The module declares \(item.resourceCount) \(item.resourceCount == 1 ? "resource" : "resources"); which ones Terraform creates depends on the inputs.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(item.resources.prefix(24).enumerated()), id: \.offset) { _, resource in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(resource.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    .frame(width: 220, alignment: .leading)
                                Text(resource.type).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                if let note = resource.note { Text("· \(note)").font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                        }
                        if item.resources.count > 24 {
                            Text("and \(item.resources.count - 24) more; the README and the Map list them all.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if item.category != .playground, item.category != .learn, item.category != .registry {
                            Text("Costs are rough, from the provider's public prices; your account's usage sets the real number.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    if !item.inputs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Needs from you").font(.headline)
                            ForEach(item.inputs, id: \.name) { input in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(input.name).font(.system(size: 13, design: .monospaced))
                                        Text(input.prompt).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 220, alignment: .leading)
                                    TextField(input.example, text: Binding(get: { inputs[input.name] ?? "" }, set: { inputs[input.name] = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                    if input.required { Text("Required").font(.system(size: 11)).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where").font(.headline)
                        HStack(spacing: 8) {
                            Text(abbreviated(destination) + "/").font(.system(size: 13)).foregroundStyle(.secondary)
                            TextField("folder name", text: $folderName).textFieldStyle(.roundedBorder).frame(width: 220)
                            Button("Choose…") { chooseDestination() }
                        }
                        Text("Readable .tf files you own. Nothing is created in any cloud until you preview and apply.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Folder") { create(item) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty || missingRequired(item))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private func missingRequired(_ item: InfrastructureTemplate) -> Bool {
        item.inputs.contains { $0.required && (inputs[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func create(_ item: InfrastructureTemplate) {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        do {
            _ = try InfrastructureTemplates.write(item, to: folder, inputs: inputs)
            dismiss()
            onCreated(folder)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to create the folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            destination = url
        }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
