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
            ForEach(InfrastructureTemplate.Category.allCases, id: \.self) { category in
                sidebarRow(category.rawValue, symbol: symbol(for: category), choice: .category(category))
            }
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
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let template {
            templateDetail(template)
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
                Button("Back") { template = nil }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What it creates").font(.headline)
                        ForEach(Array(item.resources.enumerated()), id: \.offset) { _, resource in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(resource.name).font(.system(size: 13, weight: .medium)).frame(width: 180, alignment: .leading)
                                Text(resource.type).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                if let note = resource.note { Text("· \(note)").font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                        }
                        if item.category != .playground, item.category != .learn {
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
