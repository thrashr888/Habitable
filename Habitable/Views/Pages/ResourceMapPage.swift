import SwiftUI

private extension MapKind {
    var title: String {
        switch self {
        case .frontDoor: "Front door"
        case .appsAndAI: "Apps & AI"
        case .code: "Code & delivery"
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
        case .code: "chevron.left.forwardslash.chevron.right"
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
        case .code: .mint
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
    var onShowHistory: (() -> Void)? = nil

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
            workspaceDirectory: workspace.workingDirectory,
            onShowHistory: onShowHistory,
            onShowVariables: onShowVariables)
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
    var workspaceDirectory: URL? = nil
    var workspaceURL: URL? = nil
    var stateVersionID: String? = nil
    var stateCreatedAt: Date? = nil
    var stateSerial: Int? = nil
    var onShowHistory: (() -> Void)? = nil
    var onShowVariables: (() -> Void)? = nil
    var variablesPanel: AnyView? = nil
    @State private var showingVariables = false
    @State private var showingInventory = true
    @StateObject private var renderCache = MapRenderCache()
    @State private var selectedTileID: String?
    @State private var selectedMember: String?
    @State private var search = ""
    @State private var showsConnections = true
    @State private var selectedReference: String?
    @State private var canvasZoom = 1.0
    @State private var sourceDeclaration: TerraformResourceDeclaration?
    @State private var sourceDeclarationIdentity = ""
    private var sourceIdentity: String { identity + "|" + (selectedMember ?? "") }

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
            VSplitView {
                HStack(spacing: 0) {
                    // The inventory slides like a Finder sidebar; HSplitView cannot animate.
                    if showingInventory, !tiles.isEmpty {
                        inventory.frame(width: 204).frame(maxHeight: .infinity)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Divider()
                    }
                    HSplitView {
                        canvas.frame(minWidth: 330, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        if selectedTile != nil {
                            inspector.frame(minWidth: 280, idealWidth: 330, maxWidth: 390, maxHeight: .infinity)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: showingInventory)
                .frame(minHeight: 220, maxHeight: .infinity)
                if showingVariables, let variablesPanel {
                    VStack(spacing: 0) {
                        HStack {
                            Label("Workspace variables", systemImage: "slider.horizontal.3").font(.headline)
                            Spacer()
                            Button { showingVariables = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Close workspace variables")
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                        Divider()
                        variablesPanel
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .frame(minHeight: 190, idealHeight: 240, maxHeight: 280)
                }
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if map != nil {
                    statusChip(count: tiles.reduce(0) { $0 + $1.resources.count }, label: "resources")
                    statusChip(count: search.isEmpty ? tiles.count : visibleTiles.count,
                               label: search.isEmpty ? "groups" : "of \(tiles.count) groups")
                    if let count = map?.dataSources.count, count > 0 {
                        Button(action: onShowList) { statusChip(count: count, label: "data sources") }
                            .buttonStyle(.plain).help("Open the data sources in List")
                    }
                    Spacer()
                    Text(notice ?? "This Mac · Current state").foregroundStyle(.tertiary)
                } else {
                    Text(isLoading ? "Reading state…" : (errorMessage == nil ? "No recorded state" : "State unavailable"))
                    Spacer()
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .task(id: sourceIdentity) {
            sourceDeclaration = nil
            sourceDeclarationIdentity = ""
            let requestIdentity = sourceIdentity
            guard let address = selectedMember, let directory = workspaceDirectory else { return }
            let task = Task.detached(priority: .utility) {
                TerraformConfigurationInspector.declarations(for: [address], directory: directory)[address]
            }
            let declaration = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, sourceIdentity == requestIdentity else { return }
            sourceDeclaration = declaration
            sourceDeclarationIdentity = requestIdentity
        }
        .onChange(of: identity) { _ in
            renderCache.reset()
            search = ""; selectedTileID = nil; selectedMember = nil; selectedReference = nil
        }
        .onChange(of: map) { _ in renderCache.reset() }
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

    /// One compact row: the window title already names the workspace, so the
    /// Map keeps only its own controls (Exploration B).
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
                Button { showingInventory.toggle() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless).accessibilityLabel(showingInventory ? "Hide resource inventory" : "Show resource inventory")
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .help("Show or hide the resource inventory")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a resource or group", text: $search).textFieldStyle(.plain)
                        .accessibilityLabel("Search map")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear map search")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 360)
                .help("Find a service, resource type or Terraform address. Arrows point to dependencies.")
                Spacer()
                Menu {
                    Button("Zoom In") { stepZoom(1) }.keyboardShortcut("=", modifiers: .command)
                        .disabled(canvasZoom >= Self.zoomLevels.last!)
                    Button("Zoom Out") { stepZoom(-1) }.keyboardShortcut("-", modifiers: .command)
                        .disabled(canvasZoom <= Self.zoomLevels.first!)
                    Button("Actual Size") { canvasZoom = 1 }.keyboardShortcut("0", modifiers: .command)
                    Divider()
                    ForEach(Self.zoomLevels, id: \.self) { level in
                        Button("\(Int(level * 100))%") { canvasZoom = level }
                    }
                } label: { Text("\(Int(canvasZoom * 100))%").monospacedDigit() }
                .accessibilityLabel("Map zoom")
                .help("Zoom the Map. ⌘= and ⌘- step; ⌘0 returns to actual size.")
                Toggle(isOn: $showsConnections) { Image(systemName: "point.3.connected.trianglepath.dotted") }
                    .toggleStyle(.button).accessibilityLabel("Show dependency connections")
                    .help("Show Terraform dependencies between groups")
                Button(action: onShowList) { Label("List", systemImage: "list.bullet") }
                    .buttonStyle(.bordered).help("Open the resource list")
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).disabled(!canRefresh)
                    .accessibilityLabel("Refresh map").help("Refresh map from Terraform state")
                // Variables and Inputs live in the window toolbar now (far right per the
                // settled decision); the Map header keeps only its own controls.
                if variablesPanel != nil {
                    Toggle(isOn: $showingVariables) { Label("Variables", systemImage: "rectangle.bottomthird.inset.filled") }
                        .toggleStyle(.button).help("Show or hide workspace variables")
                        .accessibilityLabel("Show workspace variables")
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
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
        renderCache.presentation(key: identity + "|" + tile.id) {
            MapResourcePresentation.summarize(tile: tile, resources: resources)
        }
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
                        let layout = cachedLayout(width: viewport.size.width)
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
        let layout = cachedLayout(width: width)
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

    private static let zoomLevels: [Double] = [0.5, 0.75, 1, 1.25, 1.5]

    private func stepZoom(_ direction: Int) {
        let levels = Self.zoomLevels
        guard let index = levels.firstIndex(where: { abs($0 - canvasZoom) < 0.001 }) else { canvasZoom = 1; return }
        canvasZoom = levels[max(0, min(levels.count - 1, index + direction))]
    }

    /// Layout and routes are memoized per visible tiles, width step and zoom, so
    /// toggling panels or re-rendering never re-runs obstacle routing needlessly.
    private func cachedLayout(width: Double) -> MapCanvasLayout {
        // Snap widths so an animating panel yields a handful of layouts, not one per frame.
        let steppedWidth = (max(580, (width - 24) / canvasZoom) / 24).rounded(.down) * 24
        let key = "\(identity)|\(search)|\(steppedWidth)"
        return renderCache.layout(key: key) {
            MapCanvasLayout(map: ResourceMap(tiles: visibleTiles, connections: map?.connections ?? [], dataSources: []),
                            width: steppedWidth)
        }
    }

    private func connectionLines(_ layout: MapCanvasLayout) -> some View {
        let routes = renderCache.routes(key: "\(identity)|\(search)|\(layout.width)|\(layout.tiles.count)") {
            let positions = Dictionary(uniqueKeysWithValues: layout.tiles.map { ($0.id, $0) })
            return (map?.connections ?? []).compactMap { connection -> (MapConnection, [CGPoint])? in
                guard let source = positions[connection.source], let target = positions[connection.target] else { return nil }
                let points = MapConnectionRoute.points(from: source, to: target, avoiding: layout.tiles, canvasWidth: layout.width)
                return points.count >= 2 ? (connection, points) : nil
            }
        }
        return Canvas { context, _ in
            for (connection, points) in routes {
                let emphasized = connection.source == selectedTileID || connection.target == selectedTileID
                let color = emphasized ? Color.accentColor : Color.secondary.opacity(selectedTileID == nil ? 0.28 : 0.10)
                let line = roundedPath(points)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: emphasized ? 1.8 : 1, lineCap: .round, lineJoin: .round))
                guard connection.relationship == .dependency else { continue }
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

    private func roundedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        for segment in MapConnectionRoute.roundedSegments(for: points, radius: 12) {
            switch segment {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .quadCurve(let control, let point): path.addQuadCurve(to: point, control: control)
            }
        }
        return path
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
                    let path = roundedPath([start,
                        CGPoint(x: start.x, y: start.y - 8),
                        CGPoint(x: gutter, y: start.y - 8),
                        CGPoint(x: gutter, y: end.y - 8),
                        CGPoint(x: end.x, y: end.y - 8), end])
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
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Inspector").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { selectedTileID = nil; selectedMember = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Close inspector")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(for: tile)).font(.title2).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(tile.kind.color, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.title).font(.title3.weight(.semibold))
                            Text(presentation(for: tile).subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Label("Recorded in Terraform state", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .help("This describes the loaded state. Live health and configuration drift have not been checked.")
                    Divider()
                    Text("At a glance").font(.headline)
                    if presentation(for: tile).facts.isEmpty {
                        Text("\(tile.resources.count) managed resources · \(tile.kind.title)").font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation(for: tile).facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(fact.label).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(fact.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                            MapCopyButton(value: fact.value, label: fact.label)
                        }.font(.callout)
                    }
                    }
                    if !presentation(for: tile).endpoints.isEmpty {
                        Divider()
                        Text("Endpoints").font(.headline)
                        ForEach(presentation(for: tile).endpoints) { endpoint in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(endpoint.label).font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    MapCopyButton(value: endpoint.value, label: endpoint.label)
                                }
                                if let url = endpoint.url {
                                    Link(endpoint.value, destination: url).lineLimit(3)
                                } else {
                                    Text(endpoint.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    connections(for: tile)
                    Divider()
                    sourceSection
                    Divider()
                    historySection
                    Divider()
                    DisclosureGroup("Resources · \(tile.resources.count)") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(tile.resources, id: \.self) { address in
                                HStack(alignment: .top, spacing: 8) {
                                    Button { selectedMember = address } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: selectedMember == address ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedMember == address ? Color.accentColor : Color.secondary)
                                            Text(address).font(.system(.callout, design: .monospaced)).multilineTextAlignment(.leading)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    MapCopyButton(value: address, label: "resource address")
                                }.padding(8)
                                    .background(selectedMember == address ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }.padding(.top, 8)
                    }
                    if let resource = selectedResource {
                        HStack {
                            Text("Resource details").font(.headline)
                            Spacer()
                            Button("Full inspector") { onOpenResource(resource.address) }.buttonStyle(.link)
                        }
                        HStack {
                            Text(resource.type).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            MapCopyButton(value: resource.type, label: "resource type")
                        }
                        DisclosureGroup("Attributes") {
                            ForEach(Array(resource.displayAttributes.prefix(14))) { attribute in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(attribute.path).font(.callout).foregroundStyle(.secondary)
                                        Spacer()
                                        if !attribute.value.contains("(sensitive value)") {
                                            MapCopyButton(value: attribute.value, label: "attribute value")
                                        }
                                    }
                                    Text(attribute.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                            if resource.displayAttributes.count > 14 {
                                Text("Open the full inspector for all attributes.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(18)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .id(selectedTileID)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Defined in").font(.headline)
            if let resource = selectedResource {
                HStack(alignment: .top) {
                    Text(resource.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    MapCopyButton(value: resource.address, label: "resource address")
                }
                if sourceDeclarationIdentity == sourceIdentity, let declaration = sourceDeclaration, let directory = workspaceDirectory,
                   let filename = TerraformDiagnosticSource.currentWorkspaceFile(filename: declaration.sourceFile, workspaceDirectory: directory) {
                    HStack {
                        Button {
                            NSWorkspace.shared.open(directory.appendingPathComponent(filename))
                        } label: { Label(declaration.sourceLocation, systemImage: "chevron.left.forwardslash.chevron.right") }
                            .buttonStyle(.link).help("Open declaration in your default editor")
                        Spacer()
                        MapCopyButton(value: declaration.sourceLocation, label: "source location")
                    }
                } else {
                    Text(workspaceDirectory == nil ? "File and line are not included in remote Terraform state." : "No matching source declaration found in this folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let workspaceURL { Link("Open workspace in HCP Terraform", destination: workspaceURL).font(.callout) }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.headline)
            if let stateCreatedAt {
                Text("State recorded \(stateCreatedAt.formatted(date: .abbreviated, time: .shortened))").font(.callout)
            }
            if let stateSerial { Text("State revision \(stateSerial)").font(.callout).foregroundStyle(.secondary) }
            if let stateVersionID {
                HStack(alignment: .top) {
                    Text(stateVersionID).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    MapCopyButton(value: stateVersionID, label: "state version")
                }
            }
            Text("Current state does not include this resource’s creation or last-change history.")
                .font(.callout).foregroundStyle(.secondary)
            if let onShowHistory { Button("Open workspace runs", action: onShowHistory).buttonStyle(.link) }
        }
    }

    @ViewBuilder private func connections(for tile: MapTile) -> some View {
        let outgoing = map?.connections.filter { $0.relationship == .dependency && $0.source == tile.id } ?? []
        let incoming = map?.connections.filter { $0.relationship == .dependency && $0.target == tile.id } ?? []
        let mixed = map?.connections.filter { $0.relationship == .mixed && ($0.source == tile.id || $0.target == tile.id) } ?? []
        if !outgoing.isEmpty || !incoming.isEmpty || !mixed.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Connected to").font(.headline)
                connectionGroup("Depends on", connections: outgoing, selected: tile.id)
                connectionGroup("Used by", connections: incoming, selected: tile.id)
                if !mixed.isEmpty {
                    Text("Grouped connections").font(.callout).foregroundStyle(.secondary)
                    Text("Different resources inside these groups have dependencies in both directions. A two-way group link does not imply a circular resource dependency.")
                        .font(.callout).foregroundStyle(.secondary)
                    connectionGroup(nil, connections: mixed, selected: tile.id)
                }
            }
        }
    }

    @ViewBuilder private func connectionGroup(_ label: String?, connections: [MapConnection], selected: String) -> some View {
        if !connections.isEmpty {
            if let label { Text(label).font(.callout).foregroundStyle(.secondary) }
            ForEach(connections, id: \.self) { connection in
                let neighbor = connection.source == selected ? connection.target : connection.source
                if let tile = tiles.first(where: { $0.id == neighbor }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button { select(tile) } label: { Label(tile.title, systemImage: tile.kind.symbol) }.buttonStyle(.link)
                        if !connection.evidence.isEmpty {
                            DisclosureGroup("Resource dependencies · \(connection.evidence.count)") {
                                ForEach(connection.evidence, id: \.self) { evidence in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .top) {
                                            Text(evidence.sourceResource).textSelection(.enabled)
                                            Spacer(minLength: 4)
                                            MapCopyButton(value: evidence.sourceResource, label: "dependent resource address")
                                        }
                                        Label("depends on", systemImage: "arrow.down").foregroundStyle(.secondary)
                                        HStack(alignment: .top) {
                                            Text(evidence.targetResource).textSelection(.enabled)
                                            Spacer(minLength: 4)
                                            MapCopyButton(value: evidence.targetResource, label: "dependency resource address")
                                        }
                                    }.font(.system(.caption, design: .monospaced)).padding(.vertical, 6)
                                }
                            }.font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func select(_ tile: MapTile) {
        if !visibleTiles.contains(where: { $0.id == tile.id }) { search = "" }
        selectedTileID = tile.id
        selectedMember = tile.anchors.first ?? tile.resources.first
    }
    /// Status chips mirror the mock's "23 resources · 22 in sync" row. Only
    /// recorded facts appear here; sync and drift are never inferred.
    private func statusChip(count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text(count, format: .number).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            Text(label)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// Copies only the displayed, already-redacted value supplied by a presentation view.
struct MapCopyButton: View {
    let value: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12)).frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless).foregroundStyle(copied ? Color.accentColor : Color.secondary)
        .accessibilityLabel(copied ? "Copied \(label)" : "Copy \(label)")
        .help(copied ? "Copied" : "Copy \(label)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// Memoizes per-render Map work (service facts, layout, obstacle routing). The
/// values depend only on the keys they are stored under; `reset()` runs whenever
/// the map identity or contents change, so stale geometry is never reused.
@MainActor
private final class MapRenderCache: ObservableObject {
    private var presentations: [String: MapResourcePresentation] = [:]
    private var layouts: [String: MapCanvasLayout] = [:]
    private var routes: [String: [(MapConnection, [CGPoint])]] = [:]

    func reset() {
        presentations.removeAll(keepingCapacity: true)
        layouts.removeAll(keepingCapacity: true)
        routes.removeAll(keepingCapacity: true)
    }

    func presentation(key: String, make: () -> MapResourcePresentation) -> MapResourcePresentation {
        if let cached = presentations[key] { return cached }
        let value = make(); presentations[key] = value; return value
    }

    func layout(key: String, make: () -> MapCanvasLayout) -> MapCanvasLayout {
        if let cached = layouts[key] { return cached }
        let value = make()
        if layouts.count > 24 { layouts.removeAll(keepingCapacity: true) }
        layouts[key] = value; return value
    }

    func routes(key: String, make: () -> [(MapConnection, [CGPoint])]) -> [(MapConnection, [CGPoint])] {
        if let cached = routes[key] { return cached }
        let value = make()
        if routes.count > 24 { routes.removeAll(keepingCapacity: true) }
        routes[key] = value; return value
    }
}
