import AppKit
import SwiftUI

/// The List: the same workspace as a dense, sortable table with filter tokens
/// (Exploration E). Typing `type:aws_* module:edge status:changed ssh` narrows
/// it; tokens show as chips the way Mail and Finder search work. Select rows,
/// then Copy Addresses. The Map and the List are two views of one workspace.
struct ResourceTableView: View {
    let rows: [ResourceListRow]
    @Binding var selection: Set<String>
    /// Remembered per window so the List comes back the way it was left.
    @SceneStorage("list.query") private var queryText = ""
    @SceneStorage("list.sort") private var sortStorage = "name"
    var isLoading = false
    var emptyTitle = "No resources"
    var emptyDetail = "Resources appear here after they are recorded in Terraform state."
    /// Selects the resource on the Map and switches to it.
    var onShowOnMap: ((String) -> Void)? = nil
    /// Opens the resource's provider documentation.
    var onOpenReference: ((ResourceListRow) -> Void)? = nil
    /// Opens the declaration in the editor, when the source is on this Mac.
    var onOpenSource: ((String) -> Void)? = nil

    @State private var sortOrder: [KeyPathComparator<ResourceListRow>] = [KeyPathComparator(\.name)]

    private var query: ResourceListQuery { ResourceListQuery(text: queryText) }
    private var visible: [ResourceListRow] { ResourceListFilter.apply(query, to: rows).sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if rows.isEmpty {
                empty
            } else if visible.isEmpty {
                VStack(spacing: 8) {
                    Label("No matching resources", systemImage: "magnifyingglass").font(.headline)
                    Text("Change or remove a filter token.").foregroundStyle(.secondary)
                    Button("Clear filters") { queryText = "" }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .onChange(of: visible.map(\.id)) { ids in selection = selection.intersection(ids) }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FilterField(placeholder: "Filter · type:aws_* module:edge status:changed", text: $queryText,
                            accessibilityLabel: "Filter resources")
                    .frame(maxWidth: 520)
                addTokenMenu
                Text(countText).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(countText + " resources")
                Spacer()
                Button(selection.count == visible.count && !visible.isEmpty ? "Deselect All" : "Select All") {
                    selection = selection.count == visible.count ? [] : Set(visible.map(\.id))
                }
                .disabled(visible.isEmpty)
                Button("Copy Addresses") {
                    let chosen = selection.isEmpty ? visible : visible.filter { selection.contains($0.id) }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ResourceListFilter.addressesText(chosen), forType: .string)
                }
                .disabled(visible.isEmpty)
                .help(selection.isEmpty ? "Copies every listed address, one per line" : "Copies the selected addresses, one per line")
            }
            if !query.tokens.isEmpty {
                HStack(spacing: 6) {
                    ForEach(query.tokens, id: \.self) { token in
                        tokenChip(token)
                    }
                    if !query.freeText.isEmpty {
                        Text("“\(query.freeText)”").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var countText: String {
        visible.count == rows.count ? "\(rows.count)" : "\(visible.count) of \(rows.count)"
    }

    private func tokenChip(_ token: ResourceListToken) -> some View {
        HStack(spacing: 4) {
            Text("\(token.field.rawValue):\(token.value)").font(.system(size: 12, design: .monospaced))
            Button { queryText = query.removing(token).text } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove filter \(token.field.rawValue) \(token.value)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    /// Adds a token from the values present, so nobody has to know the grammar first.
    private var addTokenMenu: some View {
        Menu {
            ForEach([ResourceListToken.Field.type, .module, .provider, .kind, .status], id: \.self) { field in
                let values = ResourceListFilter.suggestions(for: field, in: rows)
                if !values.isEmpty {
                    Menu(field.rawValue.capitalized) {
                        ForEach(values, id: \.self) { value in
                            Button(value) { queryText = query.adding(ResourceListToken(field: field, value: value), replace: true).text }
                        }
                    }
                }
            }
            Divider()
            Button("Changed only") { queryText = query.adding(ResourceListToken(field: .status, value: "changed"), replace: true).text }
            if !queryText.isEmpty { Button("Clear Filters") { queryText = "" } }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Add a filter token")
    }

    // MARK: Table

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    Text(row.name).lineLimit(1)
                    if row.isDataSource {
                        Text("data").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Address", value: \.address) { row in
                Text(row.address).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(row.address)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Module", value: \.module) { row in Text(row.module).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn("Kind", value: \.kind) { row in Text(row.kind).lineLimit(1).foregroundStyle(row.kind.isEmpty ? .secondary : .primary) }
                .width(min: 90, ideal: 130)
            TableColumn("Type", value: \.type) { row in Text(row.type).font(.system(size: 12, design: .monospaced)).lineLimit(1).help(row.type) }
                .width(min: 120, ideal: 200)
            TableColumn("Status", value: \.status) { row in statusLabel(row.status) }
                .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { addresses in
            rowMenu(addresses)
        } primaryAction: { addresses in
            if let address = addresses.first, addresses.count == 1 { onShowOnMap?(address) }
        }
        .onChange(of: sortOrder) { order in sortStorage = order.first.map { "\($0.keyPath)" } ?? "name" }
    }

    @ViewBuilder private func rowMenu(_ addresses: Set<String>) -> some View {
        let chosen = rows.filter { addresses.contains($0.id) }
        if chosen.count == 1, let row = chosen.first {
            if let onShowOnMap { Button("Show on Map") { onShowOnMap(row.address) } }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.address, forType: .string)
            }
            if let onOpenSource { Button("Open Source…") { onOpenSource(row.address) } }
            if let onOpenReference { Button("Open in Registry") { onOpenReference(row) } }
        } else if !chosen.isEmpty {
            Button("Copy \(chosen.count) Addresses") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ResourceListFilter.addressesText(chosen), forType: .string)
            }
        }
    }

    /// Change semantics as the Map draws them: create green, change amber,
    /// replace pink, remove red; drift amber; everything else quiet.
    private func statusLabel(_ status: String) -> some View {
        let (word, color): (String, Color) = {
            switch status {
            case "new": return ("New", .green)
            case "update": return ("Change", .orange)
            case "replace": return ("Replace", Color(red: 0.93, green: 0.33, blue: 0.62))
            case "remove": return ("Remove", .red)
            case "read": return ("Read", .secondary)
            case "drifted": return ("Drifted", .orange)
            default: return ("In state", .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(word).foregroundStyle(color == .secondary ? Color.secondary : color)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
        .quickHelp(glossary: status == "replace" ? "replace" : (status == "remove" ? "remove" : (status == "drifted" ? "drift" : "state")))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            if isLoading {
                LoadingIndicator(size: 20, label: "Reading state…")
            } else {
                Image(systemName: "square.dashed").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(emptyTitle).font(.headline)
                Text(emptyDetail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
