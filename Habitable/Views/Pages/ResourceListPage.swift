//
//  ResourceListPage.swift
//  Habitable
//

import SwiftUI

private struct ResourceBrowserRow: Identifiable {
    let resource: ShowResource
    let address: String
    let provider: String
    let type: String
    let module: String
    let mode: String

    var id: String { address }

    @MainActor
    init(_ resource: ShowResource) {
        self.resource = resource
        address = resource.address ?? resource.id.uuidString
        provider = resource.provider_name ?? "—"
        type = resource.type ?? "—"
        mode = resource.mode ?? "managed"
        module = Self.modulePath(in: address)
    }

    private static func modulePath(in address: String) -> String {
        // Consume only repeated Terraform module prefixes. Resource addresses may
        // contain dots inside quoted keys, so splitting the full address is unsafe.
        var cursor = address.startIndex
        var moduleEnd: String.Index?
        while address[cursor...].hasPrefix("module.") {
            cursor = address.index(cursor, offsetBy: "module.".count)
            guard cursor < address.endIndex else { break }

            while cursor < address.endIndex, address[cursor] != ".", address[cursor] != "[" {
                cursor = address.index(after: cursor)
            }
            guard cursor > address.startIndex else { break }

            if cursor < address.endIndex, address[cursor] == "[" {
                var depth = 0
                var inString = false
                var escaped = false
                repeat {
                    let character = address[cursor]
                    if inString {
                        if escaped { escaped = false }
                        else if character == "\\" { escaped = true }
                        else if character == "\"" { inString = false }
                    } else if character == "\"" {
                        inString = true
                    } else if character == "[" {
                        depth += 1
                    } else if character == "]" {
                        depth -= 1
                    }
                    cursor = address.index(after: cursor)
                } while cursor < address.endIndex && depth > 0
                guard depth == 0 else { break }
            }

            guard cursor < address.endIndex, address[cursor] == "." else { break }
            moduleEnd = cursor
            cursor = address.index(after: cursor)
        }
        guard let moduleEnd else { return "root" }
        return String(address[..<moduleEnd])
    }
}

struct ResourceListPage: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var selection: String?
    @State private var searchText = ""
    @State private var modeFilter = "All types"
    @State private var providerFilter = "All providers"
    @State private var moduleFilter = "All modules"
    @State private var sortOrder: [KeyPathComparator<ResourceBrowserRow>] = [
        KeyPathComparator(\.address, order: .forward)
    ]

    private var resources: [ResourceBrowserRow] {
        (workspace.state?.root_module.resources ?? []).map(ResourceBrowserRow.init)
    }

    private var providers: [String] { Array(Set(resources.map(\.provider))).filter { $0 != "—" }.sorted() }
    private var modules: [String] { Array(Set(resources.map(\.module))).sorted() }

    private var filteredResources: [ResourceBrowserRow] {
        resources.filter { row in
            (searchText.isEmpty || row.address.localizedCaseInsensitiveContains(searchText)) &&
            (modeFilter == "All types" || row.mode == modeFilter) &&
            (providerFilter == "All providers" || row.provider == providerFilter) &&
            (moduleFilter == "All modules" || row.module == moduleFilter)
        }.sorted(using: sortOrder)
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || modeFilter != "All types" || providerFilter != "All providers" || moduleFilter != "All modules"
    }

    func refresh() {
        workspace.refreshResources()
        if selection == nil { selection = filteredResources.first?.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            GeometryReader { geometry in
                if workspace.state == nil {
                    statusView.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredResources.isEmpty {
                    emptyMessage(hasActiveFilters ? "No matching resources" : "No resources",
                                 detail: hasActiveFilters ? "Adjust the filters or search text." : "This state has no resources.",
                                 symbol: hasActiveFilters ? "magnifyingglass" : "globe")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if geometry.size.width < 560 {
                    compactList
                } else {
                    resourceTable
                }
            }
        }

        .toolbar {
            QuietToolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .help("Refresh state")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workspace.locked)
                }
            }
        }
        .onChange(of: filteredResources.map(\.id)) { addresses in
            if let selection, !addresses.contains(selection) { self.selection = nil }
        }
        .onChange(of: workspace.state?.id) { _ in
            if let selection, !resources.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            SearchField(search: $searchText, accessibilityLabel: "Search resource addresses")
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                filterPicker("All types", selection: $modeFilter, options: ["managed", "data"])
                filterPicker("All providers", selection: $providerFilter, options: providers)
                filterPicker("All modules", selection: $moduleFilter, options: modules)
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private func filterPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            Text(title).tag(title)
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .help(title == "All types" ? "Filter managed resources and data sources" : title.replacingOccurrences(of: "All ", with: "Filter by "))
    }

    private var resourceTable: some View {
        Table(filteredResources, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Address", value: \.address) { row in
                Text(row.address).font(.system(.callout, design: .monospaced)).lineLimit(1).help(row.address)
            }
            TableColumn("Provider", value: \.provider) { row in
                Text(row.provider).lineLimit(1).help(row.provider)
            }
            TableColumn("Type", value: \.type) { row in
                Text(row.type).lineLimit(1).help(row.type)
            }
            TableColumn("Module", value: \.module) { row in
                Text(row.module).lineLimit(1).help(row.module)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var compactList: some View {
        List(selection: $selection) {
            ForEach(filteredResources) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.address).font(.system(.callout, design: .monospaced)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(row.mode == "data" ? "Data source" : "Managed")
                        Text("·")
                        Text(row.type)
                        if row.provider != "—" { Text("·"); Text(row.provider).lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(row.id)
            }
        }
        .listStyle(.plain)
    }

    private var statusView: some View {
        VStack(spacing: 10) {
            Label(statusTitle, systemImage: statusSymbol).font(.headline)
            Text(statusMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(workspace.locked)
        }
        .padding()
    }

    private var statusTitle: String {
        if workspace.locked && workspace.canCancelCommand { return "Loading resources" }
        if workspace.errorMessage != nil { return "Could not load resources" }
        return "No state available"
    }

    private var statusMessage: String {
        if workspace.locked && workspace.canCancelCommand { return "Terraform is refreshing this workspace." }
        if let error = workspace.errorMessage { return error }
        return workspace.hasState ? "Refresh to check this workspace for resources." : "No state is available for this workspace yet. Refresh to check again."
    }

    private var statusSymbol: String {
        if workspace.locked && workspace.canCancelCommand { return "arrow.clockwise" }
        return workspace.errorMessage == nil ? "tray" : "exclamationmark.triangle"
    }

    private func emptyMessage(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct ResourceListPage_Previews: PreviewProvider {
    static var previews: some View {
        ResourceListPage(selection: .constant(nil))
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "~/workspace/Habitable")))
    }
}
