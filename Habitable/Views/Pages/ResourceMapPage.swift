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
        case .appsAndAI: .orange
        case .messaging: .pink
        case .data: .cyan
        case .network: .blue
        case .identityAndMonitoring: .secondary
        case .other: .secondary
        }
    }
}

struct ResourceMapPage: View {
    @EnvironmentObject private var workspace: Workspace
    let onShowVariables: () -> Void
    let onShowList: () -> Void
    let onOpenResource: (String) -> Void

    var body: some View {
        ResourceMapContent(
            title: workspace.isMapDemo ? "Acme · Sample workspace" : (workspace.workingDirectory?.lastPathComponent ?? "Infrastructure"),
            identity: "\(workspace.workingDirectory?.path ?? "sample")|\(workspace.state?.id.uuidString ?? "")",
            map: workspace.resourceMap,
            resources: (workspace.state?.resources ?? []).compactMap { resource in
                guard let address = resource.address, let type = resource.type else { return nil }
                return MapDisplayResource(address: address, type: type, displayAttributes: resource.displayAttributes)
            },
            notice: workspace.mapNotice, errorMessage: workspace.errorMessage,
            isLoading: workspace.locked, canRefresh: !workspace.locked && !workspace.isMapDemo,
            refresh: workspace.refreshResources, onShowList: onShowList, onOpenResource: onOpenResource,
            variablesPanel: AnyView(VStack(alignment: .leading, spacing: 12) {
                Text("Variables").font(.headline)
                Text("Local workspace inputs").foregroundStyle(.secondary)
                Button("Manage variables", action: onShowVariables).buttonStyle(.bordered)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(workspace.terraformVariables, id: \.id) { variable in
                            TerraformVariableSummaryView(variable: variable)
                            Divider()
                        }
                        if workspace.terraformVariables.isEmpty {
                            Text("No Terraform inputs found in this workspace.").foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(16).frame(maxHeight: .infinity, alignment: .topLeading)))
    }
}

/// Shared presentation has no local runner or cloud credentials.
struct ResourceMapContent: View {
    let title: String
    let identity: String
    let map: ResourceMap?
    let resources: [MapDisplayResource]
    let notice: String?
    let errorMessage: String?
    let isLoading: Bool
    let canRefresh: Bool
    let refresh: () -> Void
    let onShowList: () -> Void
    let onOpenResource: (String) -> Void
    var emptyDetail = "Resources appear here after they are recorded in Terraform state. You can still inspect configuration, inputs, and outputs in the sidebar."
    var variablesPanel: AnyView? = nil
    @State private var showingVariables = false
    @State private var showingInventory = true
    @State private var selectedTileID: String?
    @State private var selectedMember: String?
    @State private var search = ""
    @State private var showsConnections = true
    @State private var selectedReference: String?
    @State private var canvasZoom = 1.0

    private var tiles: [MapTile] { map?.tiles ?? [] }
    private var selectedTile: MapTile? { tiles.first { $0.id == selectedTileID } }
    private var selectedResource: MapDisplayResource? {
        resources.first { $0.address == selectedMember }
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
                if showingInventory, !tiles.isEmpty {
                    inventory.frame(minWidth: 170, idealWidth: 195, maxWidth: 235, minHeight: 0, maxHeight: .infinity)
                }
                canvas.frame(minWidth: 330, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if selectedTile != nil {
                    inspector.frame(minWidth: 270, idealWidth: 310, maxWidth: 390, maxHeight: .infinity)
                } else if showingVariables, let variablesPanel {
                    variablesPanel.frame(minWidth: 280, idealWidth: 320, maxWidth: 390, maxHeight: .infinity)
                }
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack(spacing: 16) {
                if map != nil {
                    Label(search.isEmpty ? "\(tiles.count) groups" : "\(visibleTiles.count) of \(tiles.count) groups", systemImage: "square.grid.2x2")
                    Text("\(tiles.reduce(0) { $0 + $1.resources.count }) managed resources")
                    if let count = map?.dataSources.count, count > 0 {
                        Button("\(count) data sources", action: onShowList).buttonStyle(.link)
                    }
                    Spacer()
                    Text("Current state").foregroundStyle(.tertiary)
                } else {
                    Text(isLoading ? "Reading state…" : (errorMessage == nil ? "No recorded state" : "State unavailable"))
                    Spacer()
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
        }
        .onChange(of: identity) { _ in search = ""; selectedTileID = nil; selectedMember = nil; selectedReference = nil }
        .onChange(of: search) { _ in
            if let selectedTileID, !visibleTiles.contains(where: { $0.id == selectedTileID }) {
                self.selectedTileID = nil
                selectedMember = nil
            }
        }
        .onChange(of: map) { _ in
            if let tile = selectedTile {
                if !tile.resources.contains(selectedMember ?? "") { selectedMember = tile.anchors.first ?? tile.resources.first }
            } else { selectedTileID = nil; selectedMember = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Toggle(isOn: $showingInventory) { Image(systemName: "sidebar.left") }
                    .toggleStyle(.button).accessibilityLabel("Show resource inventory")
                    .help("Show or hide the resource inventory")
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold)).lineLimit(1)
                    Text(notice ?? "This Mac · Current state")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("100%") { canvasZoom = 1 }
                    Button("125%") { canvasZoom = 1.25 }
                    Button("150%") { canvasZoom = 1.5 }
                } label: { Text("\(Int(canvasZoom * 100))%") }
                .accessibilityLabel("Map zoom")
                Toggle(isOn: $showsConnections) { Image(systemName: "point.3.connected.trianglepath.dotted") }
                    .toggleStyle(.button).accessibilityLabel("Show dependency connections")
                    .help("Show Terraform dependencies between groups")
                Button(action: onShowList) { Label("List", systemImage: "list.bullet") }
                    .buttonStyle(.bordered).help("Open the resource list")
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).disabled(!canRefresh)
                    .accessibilityLabel("Refresh map").help("Refresh map from Terraform state")
                if variablesPanel != nil {
                    Toggle(isOn: Binding(get: { showingVariables && selectedTileID == nil }, set: { show in
                        showingVariables = show
                        if show { selectedTileID = nil; selectedMember = nil }
                    })) { Label("Variables", systemImage: "sidebar.right") }
                        .toggleStyle(.button).help("Show or hide workspace variables")
                        .accessibilityLabel("Show workspace variables")
                }
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
            .help("Find a service, resource type or Terraform address. Arrows point to dependencies.")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var inventory: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                let endpointTiles = visibleTiles.filter { !presentation(for: $0).endpoints.isEmpty }
                if !endpointTiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Endpoints").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(endpointTiles, id: \.id) { tile in
                            if let endpoint = presentation(for: tile).endpoints.first {
                                Button { select(tile) } label: {
                                    Label(endpoint.value, systemImage: "arrow.up.right")
                                        .font(.callout).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                    .help("\(tile.title) · \(endpoint.value)")
                                    .accessibilityLabel("Inspect endpoint for \(tile.title)")
                            }
                        }
                    }.padding(.horizontal, 8)
                }
                ForEach(MapKind.allCases.filter { kind in visibleTiles.contains { $0.kind == kind } }, id: \.rawValue) { kind in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                        ForEach(visibleTiles.filter { $0.kind == kind }, id: \.id) { tile in
                            Button { select(tile) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: symbol(for: tile)).foregroundStyle(tile.kind.color).frame(width: 16)
                                    Text(tile.title).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(tile.resources.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }.padding(8).contentShape(Rectangle())
                                    .background(selectedTileID == tile.id ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityLabel("Inspect \(tile.title)")
                        }
                    }
                }
            }.padding(12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func presentation(for tile: MapTile) -> MapResourcePresentation {
        MapResourcePresentation.summarize(tile: tile, resources: resources)
    }

    private var canvas: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    if let error = errorMessage, map == nil {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Couldn’t read state for \(title)", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text("The Map needs readable Terraform state. Check that you opened the intended workspace, then refresh after resolving the state error.")
                                .font(.body).foregroundStyle(.secondary)
                            Text(identity.components(separatedBy: "|").first ?? "")
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            DisclosureGroup("Technical details") {
                                Text(error).font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                            Button("Refresh state", action: refresh).disabled(!canRefresh)
                        }
                        .padding(24)
                        .frame(width: viewport.size.width, alignment: .leading)
                    } else if isLoading && map == nil {
                        ProgressView("Reading your infrastructure…")
                            .frame(width: viewport.size.width, height: 180)
                    } else if tiles.isEmpty {
                        empty("No managed resources yet", detail: emptyDetail, symbol: "square.dashed")
                            .frame(width: viewport.size.width)
                    } else if visibleTiles.isEmpty {
                        VStack {
                            empty("No matching resources", detail: "Try a group name, resource type, or Terraform address.", symbol: "magnifyingglass")
                            Button("Clear search") { search = "" }.buttonStyle(.bordered)
                        }.frame(width: viewport.size.width)
                    } else {
                        let filteredMap = ResourceMap(tiles: visibleTiles, connections: map?.connections ?? [], dataSources: [])
                        let layout = MapCanvasLayout(map: filteredMap, width: max(580, (viewport.size.width - 24) / canvasZoom))
                        let references = map?.workspaceReferences ?? []
                        let portColumns = max(1, Int((layout.width - 56) / 260))
                        let portHeight = references.isEmpty ? 0.0 : Double((references.count + portColumns - 1) / portColumns) * 46 + 46
                        ZStack(alignment: .topLeading) {
                            canvasBackground(layout)
                            // Real layout anchors let inventory selection scroll after panel resizing.
                            // Card offsets alone are not reliable ScrollViewReader targets.
                            let rows = Array(Set(layout.tiles.map(\.y))).sorted()
                            VStack(spacing: 0) {
                                Color.clear.frame(height: max(0, (rows.first ?? 0) - 38))
                                ForEach(Array(rows.enumerated()), id: \.element) { index, y in
                                    Color.clear.frame(height: 1).id("map-row-\(y)")
                                    let next = index + 1 < rows.count ? rows[index + 1] : layout.height
                                    Color.clear.frame(height: max(0, next - y - 1))
                                }
                            }.frame(width: 1).allowsHitTesting(false).accessibilityHidden(true)
                            if !references.isEmpty {
                                Text("WORKSPACE REFERENCES").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                    .offset(x: 20, y: layout.height + 16)
                                ForEach(Array(references.enumerated()), id: \.element.address) { index, reference in
                                    Button { selectedReference = reference.address } label: {
                                        Label(reference.name.replacingOccurrences(of: "_", with: " "), systemImage: "link")
                                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                            .foregroundStyle(Color.accentColor).padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4)))
                                    }.buttonStyle(.plain).help(reference.address)
                                        .accessibilityLabel("Workspace reference \(reference.name)")
                                        .popover(isPresented: Binding(get: { selectedReference == reference.address }, set: { if !$0 { selectedReference = nil } })) {
                                            VStack(alignment: .leading, spacing: 12) {
                                                Text(reference.name).font(.headline)
                                                Text(reference.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                                Text("This data-source alias is recorded in this workspace’s state. The destination workspace has not been verified.")
                                                    .font(.callout).foregroundStyle(.secondary)
                                                ForEach(reference.consumers, id: \.self) { id in
                                                    if let tile = tiles.first(where: { $0.id == id }) {
                                                        Button("Used by \(tile.title)") { selectedReference = nil; select(tile) }.buttonStyle(.link)
                                                    }
                                                }
                                                Button("Open data sources", action: onShowList)
                                            }.padding(20).frame(width: 300)
                                        }
                                        .frame(width: 224, alignment: .leading)
                                        .offset(x: 28 + Double(index % portColumns) * 260, y: layout.height + 42 + Double(index / portColumns) * 46)
                                }
                            }
                            if showsConnections {
                                connectionLines(layout).allowsHitTesting(false).accessibilityHidden(true)
                                referenceLines(layout).allowsHitTesting(false).accessibilityHidden(true)
                            }
                            ForEach(layout.tiles, id: \.id) { placement in
                                if let tile = visibleTiles.first(where: { $0.id == placement.id }) {
                                    tileButton(tile)
                                        .frame(width: placement.width, height: placement.height)
                                        .offset(x: placement.x, y: placement.y).id(tile.id)
                                }
                            }
                        }
                        .frame(width: layout.width, height: layout.height + portHeight, alignment: .topLeading)
                        .scaleEffect(canvasZoom, anchor: .topLeading)
                        .frame(width: layout.width * canvasZoom, height: (layout.height + portHeight) * canvasZoom, alignment: .topLeading)
                        .padding(12)
                    }
                }
                .onChange(of: selectedTileID) { _ in
                    scrollToSelection(proxy, width: viewport.size.width)
                }
                .onChange(of: viewport.size.width) { width in
                    scrollToSelection(proxy, width: width)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, width: Double) {
        guard let selectedTileID else { return }
        let filteredMap = ResourceMap(tiles: visibleTiles, connections: map?.connections ?? [], dataSources: [])
        let layout = MapCanvasLayout(map: filteredMap, width: max(580, (width - 24) / canvasZoom))
        guard let tile = layout.tiles.first(where: { $0.id == selectedTileID }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("map-row-\(tile.y)", anchor: .top)
        }
    }

    private func canvasBackground(_ layout: MapCanvasLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for x in stride(from: 9.0, to: size.width, by: 18) {
                    for y in stride(from: 9.0, to: size.height, by: 18) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.15)))
                    }
                }
            }.accessibilityHidden(true)
            ForEach(layout.bands, id: \.kind.rawValue) { band in
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.075)))
                    .frame(width: layout.width - 16, height: band.height)
                    .offset(x: 8, y: band.y)
                Text(band.kind.title.uppercased())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .offset(x: 20, y: band.y + 10)
            }
        }
    }

    private func connectionLines(_ layout: MapCanvasLayout) -> some View {
        let positions = Dictionary(uniqueKeysWithValues: layout.tiles.map { ($0.id, $0) })
        let routes = (map?.connections ?? []).compactMap { connection -> (MapConnection, [CGPoint])? in
            guard let source = positions[connection.source], let target = positions[connection.target] else { return nil }
            let points = MapConnectionRoute.points(from: source, to: target, avoiding: layout.tiles, canvasWidth: layout.width)
            return points.count >= 2 ? (connection, points) : nil
        }
        return Canvas { context, _ in
            for (connection, points) in routes {
                let emphasized = connection.source == selectedTileID || connection.target == selectedTileID
                let color = emphasized ? Color.accentColor : Color.secondary.opacity(selectedTileID == nil ? 0.28 : 0.10)
                var line = Path()
                line.addLines(points)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: emphasized ? 1.8 : 1, lineCap: .round, lineJoin: .round))
                let end = points[points.count - 1], previous = points[points.count - 2]
                let angle = atan2(end.y - previous.y, end.x - previous.x)
                let length = 5.0
                var head = Path()
                head.addLines([
                    CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)), end,
                    CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))
                ])
                context.stroke(head, with: .color(color), lineWidth: emphasized ? 1.8 : 1)
            }
        }
    }

    private func referenceLines(_ layout: MapCanvasLayout) -> some View {
        Canvas { context, _ in
            let positions = Dictionary(uniqueKeysWithValues: layout.tiles.map { ($0.id, $0) })
            let columns = max(1, Int((layout.width - 56) / 260))
            for (index, reference) in (map?.workspaceReferences ?? []).enumerated() {
                let end = CGPoint(x: 140 + Double(index % columns) * 260, y: layout.height + 42 + Double(index / columns) * 46)
                for consumer in reference.consumers {
                    guard let tile = positions[consumer] else { continue }
                    let start = CGPoint(x: tile.x + tile.width / 2, y: tile.y)
                    let gutter = layout.width - 12 - Double(index % 3) * 3
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: CGPoint(x: start.x, y: start.y - 8))
                    path.addLine(to: CGPoint(x: gutter, y: start.y - 8))
                    path.addLine(to: CGPoint(x: gutter, y: end.y - 8))
                    path.addLine(to: CGPoint(x: end.x, y: end.y - 8))
                    path.addLine(to: end)
                    context.stroke(path, with: .color(Color.accentColor.opacity(selectedTileID == nil || selectedTileID == consumer ? 0.65 : 0.15)),
                                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                }
            }
        }
    }

    private func type(for tile: MapTile) -> String {
        resources.first(where: { $0.address == (tile.anchors.first ?? tile.id) })?.type ?? ""
    }

    private func symbol(for tile: MapTile) -> String {
        let type = type(for: tile)
        if type.contains("bedrock") { return "sparkles" }
        if type.contains("lambda") { return "bolt.fill" }
        if type.contains("db_instance") || type.contains("elasticache") { return "cylinder.split.1x2" }
        if type.contains("sns") { return "bell" }
        if type.contains("cloudwatch_event") { return "waveform.path.ecg" }
        if type.contains("chatbot") { return "bubble.left" }
        if type.contains("bucket") { return "externaldrive" }
        return tile.kind.symbol
    }

    private func stackCount(for tile: MapTile) -> Int {
        let anchors = resources.filter { tile.anchors.contains($0.address) }
        return Dictionary(grouping: anchors, by: \.type).values.map(\.count).max() ?? 1
    }

    private func tileButton(_ tile: MapTile) -> some View {
        let copies = stackCount(for: tile)
        return Button { select(tile) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: tile)).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white).frame(width: 34, height: 34)
                    .background(tile.kind.color, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(presentation(for: tile).subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    Text("\(tile.resources.count) \(tile.resources.count == 1 ? "resource" : "resources")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selectedTileID == tile.id ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selectedTileID == tile.id ? 2 : 1))
            .background {
                if copies > 1 {
                    RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.12)))
                        .offset(x: 4, y: 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if copies > 1 {
                    Text("×\(copies)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary, in: Capsule()).offset(x: 5, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.title), \(tile.resources.count) \(tile.resources.count == 1 ? "resource" : "resources"), \(tile.kind.title)")
        .accessibilityAddTraits(selectedTileID == tile.id ? [.isSelected] : [])
        .help(tile.resources.joined(separator: "\n"))
    }

    private var inspector: some View {
        ScrollView {
            if let tile = selectedTile {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Inspector").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { selectedTileID = nil; selectedMember = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Close inspector")
                    }
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: tile)).font(.title).foregroundStyle(tile.kind.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.title).font(.title3.weight(.semibold))
                            Text(tile.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(presentation(for: tile).subtitle).font(.body).foregroundStyle(.secondary)
                    ForEach(presentation(for: tile).facts) { fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(fact.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.font(.callout)
                    }
                    if !presentation(for: tile).endpoints.isEmpty {
                        Divider()
                        Text("Endpoints").font(.headline)
                        ForEach(presentation(for: tile).endpoints) { endpoint in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(endpoint.label).font(.callout).foregroundStyle(.secondary)
                                if let url = endpoint.url {
                                    Link(endpoint.value, destination: url).lineLimit(3)
                                } else {
                                    Text(endpoint.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                }
                                Button("Copy endpoint") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(endpoint.value, forType: .string)
                                }.buttonStyle(.link)
                            }
                        }
                    }
                    connections(for: tile)
                    Divider()
                    DisclosureGroup("Resources · \(tile.resources.count)") {
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
                    }
                    if let resource = selectedResource {
                        Divider()
                        HStack {
                            Text("Details").font(.headline)
                            Spacer()
                            Button("Full inspector") { onOpenResource(selectedMember!) }.buttonStyle(.link)
                        }
                        Text(resource.type).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        DisclosureGroup("Attributes") {
                        ForEach(Array(resource.displayAttributes.prefix(14))) { attribute in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attribute.path).font(.caption).foregroundStyle(.secondary)
                                Text(attribute.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
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
        .id(selectedMember)
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
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity).padding(.top, 60)
    }
}
