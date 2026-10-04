import SwiftUI

private extension MapKind {
    var title: String {
        switch self {
        case .frontDoor: "Front door"
        case .appsAndAI: "Apps & AI"
        case .messaging: "Messaging & events"
        case .data: "Data"
        case .network: "Network"
        case .identityAndMonitoring: "Identity & monitoring"
        case .other: "Other resources"
        }
    }
    var symbol: String {
        switch self {
        case .frontDoor: "globe"
        case .appsAndAI: "shippingbox"
        case .messaging: "arrow.triangle.branch"
        case .data: "externaldrive"
        case .network: "network"
        case .identityAndMonitoring: "lock.shield"
        case .other: "cube.transparent"
        }
    }
    var color: Color {
        switch self {
        case .frontDoor: .teal
        case .appsAndAI: .accentColor
        case .messaging: .orange
        case .data: .blue
        case .network: .cyan
        case .identityAndMonitoring: .secondary
        case .other: .secondary
        }
    }
}

struct ResourceMapPage: View {
    @EnvironmentObject private var workspace: Workspace
    let onShowList: () -> Void
    let onOpenResource: (String) -> Void
    @State private var selectedTileID: String?
    @State private var selectedMember: String?
    @State private var search = ""

    private var map: ResourceMap? { workspace.resourceMap }
    private var tiles: [MapTile] { map?.tiles ?? [] }
    private var selectedTile: MapTile? { tiles.first { $0.id == selectedTileID } }
    private var selectedResource: ShowResource? {
        workspace.state?.resources.first { $0.address == selectedMember }
    }
    private var visibleTiles: [MapTile] {
        guard !search.isEmpty else { return tiles }
        return tiles.filter { $0.title.localizedCaseInsensitiveContains(search) ||
            $0.resources.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                canvas.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(minWidth: 270, idealWidth: 310, maxWidth: 390, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                Label("\(tiles.count) groups", systemImage: "square.grid.2x2")
                Text("\(tiles.reduce(0) { $0 + $1.resources.count }) managed resources")
                if let count = map?.dataSources.count, count > 0 {
                    Button("\(count) data sources", action: onShowList).buttonStyle(.link)
                }
                Spacer()
                Text("Current state").foregroundStyle(.tertiary)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
        }
        .onChange(of: workspace.state?.id) { _ in selectedTileID = nil; selectedMember = nil }
        .onChange(of: workspace.workingDirectory) { _ in search = ""; selectedTileID = nil; selectedMember = nil }
        .onChange(of: map) { _ in
            if let tile = selectedTile {
                if !tile.resources.contains(selectedMember ?? "") { selectedMember = tile.anchors.first ?? tile.resources.first }
            } else { selectedTileID = nil; selectedMember = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.isMapDemo ? "Acme · Sample workspace" : (workspace.workingDirectory?.lastPathComponent ?? "Infrastructure"))
                        .font(.title2.weight(.semibold)).lineLimit(1)
                    Label("Resource map", systemImage: "square.grid.3x3")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onShowList) { Label("List", systemImage: "list.bullet") }
                    .buttonStyle(.bordered).help("Open the resource list")
                Button { workspace.refreshResources() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).disabled(workspace.locked || workspace.isMapDemo)
                    .accessibilityLabel("Refresh map").help("Refresh map from Terraform state")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a resource or group", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search map")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear map search")
                }
            }
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let notice = workspace.mapNotice {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var canvas: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let error = workspace.errorMessage, map == nil {
                empty("Couldn’t read this workspace", detail: error, symbol: "exclamationmark.triangle")
            } else if workspace.locked && map == nil {
                VStack(spacing: 12) { ProgressView(); Text("Reading your infrastructure…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).padding(.top, 100)
            } else if tiles.isEmpty {
                empty("No managed resources yet", detail: "Resources appear here after they are recorded in Terraform state. You can still inspect configuration, inputs, and outputs in the sidebar.", symbol: "square.dashed")
            } else if visibleTiles.isEmpty {
                empty("No matching resources", detail: "Try a group name, resource type, or Terraform address.", symbol: "magnifyingglass")
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(MapKind.allCases, id: \.rawValue) { kind in
                        let row = visibleTiles.filter { $0.kind == kind }
                        if !row.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: kind.symbol).foregroundStyle(kind.color)
                                    Text(kind.title).font(.subheadline.weight(.semibold))
                                    Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                                    ForEach(row, id: \.id) { tile in tileButton(tile).id(tile.id) }
                                }
                            }
                        }
                    }
                }.padding(24)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: selectedTileID) { id in
            if let id { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }

    private func tileButton(_ tile: MapTile) -> some View {
        Button { select(tile) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: tile.kind.symbol).font(.title3)
                        .foregroundStyle(tile.kind.color).frame(width: 34, height: 34)
                        .background(tile.kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tile.title).font(.headline).lineLimit(2)
                        Text(category(for: tile)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Text("\(tile.resources.count) \(tile.resources.count == 1 ? "resource" : "resources")")
                    Spacer()
                    if tile.anchors.count > 1 { Label("\(tile.anchors.count)", systemImage: "square.3.layers.3d") }
                    Image(systemName: "chevron.right").font(.caption2)
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedTileID == tile.id ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selectedTileID == tile.id ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.title), \(tile.resources.count) resources, \(tile.kind.title)")
        .accessibilityAddTraits(selectedTileID == tile.id ? [.isSelected] : [])
        .help(tile.resources.joined(separator: "\n"))
    }

    private var inspector: some View {
        ScrollView {
            if let tile = selectedTile {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: tile.kind.symbol).font(.title).foregroundStyle(tile.kind.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.title).font(.title3.weight(.semibold))
                            Text(tile.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(tile.resources.count) resources make up this group.").foregroundStyle(.secondary).font(.callout)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Resources").font(.headline)
                        ForEach(tile.resources, id: \.self) { address in
                            Button { selectedMember = address } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: selectedMember == address ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedMember == address ? Color.accentColor : Color.secondary)
                                    Text(address).font(.system(.caption, design: .monospaced))
                                        .multilineTextAlignment(.leading).textSelection(.disabled)
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedMember == address ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }
                    connections(for: tile)
                    if let resource = selectedResource {
                        Divider()
                        HStack {
                            Text("Details").font(.headline)
                            Spacer()
                            Button("Full inspector") { onOpenResource(selectedMember!) }.buttonStyle(.link)
                        }
                        Text(resource.type ?? "Resource").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(Array(resource.displayAttributes.prefix(14))) { attribute in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attribute.path).font(.caption).foregroundStyle(.secondary)
                                Text(attribute.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if resource.displayAttributes.count > 14 {
                            Text("Open the full inspector for all attributes and source links.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(20)
            } else {
                empty("Your infrastructure, explained", detail: "Select a group to see its resources, connections, and details.", symbol: "sidebar.right")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func connections(for tile: MapTile) -> some View {
        let dependencies = map?.connections.filter { $0.source == tile.id }.map(\.target) ?? []
        let dependents = map?.connections.filter { $0.target == tile.id }.map(\.source) ?? []
        if !dependencies.isEmpty || !dependents.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Connections").font(.headline)
                connectionGroup("Depends on", ids: dependencies)
                connectionGroup("Used by", ids: dependents)
            }
        }
    }

    @ViewBuilder private func connectionGroup(_ label: String, ids: [String]) -> some View {
        if !ids.isEmpty {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ForEach(ids, id: \.self) { id in
                if let tile = tiles.first(where: { $0.id == id }) {
                    Button { select(tile) } label: { Label(tile.title, systemImage: tile.kind.symbol) }.buttonStyle(.link)
                }
            }
        }
    }

    private func select(_ tile: MapTile) {
        if !visibleTiles.contains(where: { $0.id == tile.id }) { search = "" }
        selectedTileID = tile.id
        selectedMember = tile.anchors.first ?? tile.resources.first
    }
    private func category(for tile: MapTile) -> String {
        guard let resource = workspace.state?.resources.first(where: { $0.address == (tile.anchors.first ?? tile.id) }),
              let type = resource.type else { return tile.kind.title }
        return ResourceMapCategories.values[type] ?? type
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity).padding(.top, 60)
    }
}
