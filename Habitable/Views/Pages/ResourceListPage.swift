//
//  ResourceListPage.swift
//  Habitable
//

import SwiftUI

private struct ResourceBrowserRow: Identifiable {
    let resource: ShowResource
    let record: ResourceBrowserRecord
    var id: String { record.id }
    var address: String { record.address }
    var provider: String { record.provider }
    var type: String { record.type }
    var module: String { record.module }

    @MainActor
    init(_ resource: ShowResource) {
        self.resource = resource
        let address = resource.address ?? resource.id.uuidString
        record = ResourceBrowserRecord(id: address, address: address, type: resource.type,
                                       provider: resource.provider_name, mode: resource.mode)
    }
}

struct ResourceListPage: View {
    @EnvironmentObject var workspace: Workspace
    @Binding var selection: String?
    @State private var query = ResourceBrowserQuery()
    @State private var index = ResourceBrowserIndex(records: [])
    @State private var resourceRows: [ResourceBrowserRow] = []
    @State private var visibleRows: [ResourceBrowserRow] = []
    @State private var sortOrder: [KeyPathComparator<ResourceBrowserRow>] = [
        KeyPathComparator(\.address, order: .forward)
    ]

    private var hasActiveFilters: Bool { query.hasFilters }

    private func rebuildResourceRows(resetFilters: Bool = false) {
        resourceRows = (workspace.state?.root_module.resources ?? []).map(ResourceBrowserRow.init)
        index = ResourceBrowserIndex(records: resourceRows.map(\.record))
        if resetFilters { query = ResourceBrowserQuery() }
        normalizeFilterOptions()
        rebuildVisibleRows()
    }

    private func normalizeFilterOptions() {
        if query.type != "All resource types" && !index.types.contains(query.type) { query.type = "All resource types" }
        if query.provider != "All providers" && !index.providers.contains(query.provider) { query.provider = "All providers" }
        if query.module != "All modules" && !index.modules.contains(query.module) { query.module = "All modules" }
        if query.mode != "All categories" && !["managed", "data"].contains(query.mode) { query.mode = "All categories" }
    }

    private func rebuildVisibleRows() {
        let ids = index.matchingIDs(for: query)
        let rowsByID = Dictionary(resourceRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matches = ids.compactMap { rowsByID[$0] }
        visibleRows = matches.sorted(using: sortOrder)
    }

    private func resetFilters() {
        query = ResourceBrowserQuery()
    }

    func refresh() {
        workspace.refreshResources()
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            GeometryReader { geometry in
                if workspace.state == nil {
                    statusView.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleRows.isEmpty {
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
                        Label("Refresh", systemImage: "arrow.clockwise").help("Refresh state")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workspace.locked)
                }
            }
        }
        .onChange(of: query) { _ in rebuildVisibleRows() }
        .onChange(of: sortOrder) { _ in rebuildVisibleRows() }
        .onChange(of: visibleRows.map(\.id)) { addresses in
            selection = ResourceBrowserIndex.safeSelection(selection, visibleIDs: addresses)
        }
        .onAppear { rebuildResourceRows() }
        .onChange(of: workspace.state?.id) { _ in
            rebuildResourceRows()
            selection = ResourceBrowserIndex.safeSelection(selection, visibleIDs: resourceRows.map(\.id))
        }
        .onChange(of: workspace.workingDirectory) { _ in
            rebuildResourceRows(resetFilters: true)
            selection = ResourceBrowserIndex.safeSelection(selection, visibleIDs: resourceRows.map(\.id))
        }
    }

    private var filterBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                SearchField(search: $query.search, accessibilityLabel: "Search resources")
                    .frame(maxWidth: .infinity)
                Text("\(visibleRows.count) of \(resourceRows.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(visibleRows.count) of \(resourceRows.count) resources shown")
                if hasActiveFilters {
                    Button("Reset") { resetFilters() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Clear search and filters")
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                filterPicker("All categories", selection: $query.mode, options: ["managed", "data"])
                filterPicker("All resource types", selection: $query.type, options: index.types)
                filterPicker("All providers", selection: $query.provider, options: index.providers)
                filterPicker("All modules", selection: $query.module, options: index.modules)
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func filterPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            Text(title).tag(title)
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .help("Filter by \(title.replacingOccurrences(of: "All ", with: "").lowercased())")
    }

    private var resourceTable: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Address", value: \.address) { row in
                Text(row.address).font(.system(.callout, design: .monospaced)).lineLimit(1).help(row.address)
            }
            TableColumn("Provider", value: \.provider) { row in Text(row.provider).lineLimit(1).help(row.provider) }
            TableColumn("Type", value: \.type) { row in Text(row.type).lineLimit(1).help(row.type) }
            TableColumn("Module", value: \.module) { row in Text(row.module).lineLimit(1).help(row.module) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var compactList: some View {
        List(selection: $selection) {
            ForEach(visibleRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.address).font(.system(.callout, design: .monospaced)).lineLimit(2).help(row.address)
                    Text([row.record.mode == "data" ? "Data source" : "Managed", row.type,
                          row.provider == "—" ? nil : row.provider].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)

                }
                .padding(.vertical, 6)
                .tag(row.id)
            }
        }
        .listStyle(.inset)
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
            .environmentObject(Workspace(dir: URL(fileURLWithPath: "/Users/thrashr888/workspace/Habitable")))
    }
}
