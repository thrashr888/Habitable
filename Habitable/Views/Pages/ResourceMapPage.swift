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
    var sideFaces: [MapSideFace] = []
    var emptyTitle: String? = nil
    var emptyDetail: String? = nil
    var emptySymbol: String? = nil
    var emptyAction: MapEmptyAction? = nil
    var preview: MapChangePreview? = nil
    var onDiscardPreview: (() -> Void)? = nil
    var onReviewPreview: (() -> Void)? = nil

    var body: some View {
        ResourceMapContent(
            title: workspace.isMapDemo ? "Acme · Sample workspace" : (workspace.workingDirectory?.lastPathComponent ?? "Infrastructure"),
            identity: "\(workspace.workingDirectory?.path ?? "sample")|\(workspace.state?.id.uuidString ?? "")",
            map: workspace.resourceMap,
            resources: (workspace.state?.resources ?? []).compactMap { resource in
                guard let address = resource.address, let type = resource.type else { return nil }
                return MapDisplayResource(address: address, type: type, displayAttributes: resource.displayAttributes,
                                          providerName: resource.provider_name)
            },
            notice: workspace.mapNotice,
            // A remote-state handoff is the explanation; the local state-read error
            // would only restate that there is nothing to read here.
            errorMessage: emptyTitle == nil ? workspace.errorMessage : nil,
            isLoading: workspace.locked, canRefresh: !workspace.locked && !workspace.isMapDemo,
            refresh: workspace.refreshResources, onShowList: onShowList, onOpenResource: onOpenResource,
            emptyDetail: emptyDetail ?? "Resources appear here after they are recorded in Terraform state. Inputs and Changes stay available on the right.",
            emptyTitle: emptyTitle, emptySymbol: emptySymbol ?? "square.dashed", emptyAction: emptyAction,
            workspaceDirectory: workspace.workingDirectory,
            onShowHistory: onShowHistory,
            onShowVariables: onShowVariables,
            sideFaces: sideFaces,
            preview: preview, onDiscardPreview: onDiscardPreview, onReviewPreview: onReviewPreview,
            terraformExecutableURL: workspace.runner.executableURL,
            workspaceInitialized: workspace.isInitialized)
    }
}

/// Shared presentation has no local runner or cloud credentials.
/// One face of the Map's right pane besides the Inspector (Changes, Inputs,
/// Runs, Variables). The pane is an inspector with segmented faces, like a
/// Studio or Finder inspector; the Map never grows a second sidebar.
struct MapSideFace: Identifiable {
    let id: String
    let title: String
    var count: Int? = nil
    let content: AnyView

    init<Content: View>(id: String, title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.id = id; self.title = title; self.count = count; self.content = AnyView(content())
    }
}

/// One prominent action offered by the Map's empty state (e.g. opening the
/// remote workspace that holds this folder's state).
struct MapEmptyAction {
    let title: String
    let run: () -> Void
}

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
    var emptyDetail = "Resources appear here after they are recorded in Terraform state. Inputs and Changes stay available on the right."
    var emptyTitle: String? = nil
    var emptySymbol = "square.dashed"
    var emptyAction: MapEmptyAction? = nil
    var workspaceDirectory: URL? = nil
    var workspaceURL: URL? = nil
    var stateVersionID: String? = nil
    var stateCreatedAt: Date? = nil
    var stateSerial: Int? = nil
    var onShowHistory: (() -> Void)? = nil
    var onShowVariables: (() -> Void)? = nil
    var variablesPanel: AnyView? = nil
    var sideFaces: [MapSideFace] = []
    /// A checked-out repository for this workspace: resolves "Defined in" when the
    /// window itself has no folder, and links file and line to the repository host.
    var sourceDirectory: URL? = nil
    var repository: HCPVCSRepository? = nil
    /// Shown while the Map displays a recorded earlier state rather than the current one.
    var historyBanner: (text: String, dismiss: () -> Void)? = nil
    /// The workspace's own description, shown when nothing is selected.
    var workspaceDescription: String? = nil
    /// Preview Changes (Exploration C): the same map in a review state.
    var preview: MapChangePreview? = nil
    var onDiscardPreview: (() -> Void)? = nil
    var onReviewPreview: (() -> Void)? = nil
    @State private var changesOnly = false
    var terraformExecutableURL: URL? = nil
    var workspaceInitialized = false
    @SceneStorage("map.sideFace") private var sideFaceID = "inspector"
    @State private var showingVariables = false
    // Settings › General › "Show inventory when a map opens".
    @State private var showingInventory = UserDefaults.standard.object(forKey: "map.showInventory") as? Bool ?? true
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

    private var tiles: [MapTile] { (preview?.map ?? map)?.tiles ?? [] }
    private func action(for tile: MapTile) -> MapChangeAction { preview?.tileActions[tile.id] ?? .none }
    private var selectedTile: MapTile? { tiles.first { $0.id == selectedTileID } }
    private var selectedResource: MapDisplayResource? {
        resources.first { $0.address == selectedMember }
    }
    private var visibleTiles: [MapTile] {
        var result = tiles
        if preview != nil, changesOnly { result = result.filter { action(for: $0) != .none } }
        guard !search.isEmpty else { return result }
        return result.filter { $0.title.localizedCaseInsensitiveContains(search) ||
            $0.resources.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let historyBanner {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
                    Text(historyBanner.text).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Return to current state", action: historyBanner.dismiss).buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
                Divider()
            }
            VSplitView {
                HStack(spacing: 0) {
                    // The inventory slides like a Finder sidebar; HSplitView cannot animate.
                    if showingInventory, !tiles.isEmpty {
                        inventory.frame(width: 224).frame(maxHeight: .infinity)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Divider()
                    }
                    HSplitView {
                        canvas.frame(minWidth: 330, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        if selectedTile != nil || !sideFaces.isEmpty {
                            sidePane.frame(minWidth: 280, idealWidth: 330, maxWidth: 390, maxHeight: .infinity)
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
            if let preview {
                reviewBar(preview)
            } else {
            HStack(spacing: 8) {
                if map != nil {
                    statusChip(count: tiles.reduce(0) { $0 + $1.resources.count }, label: "resources")
                    statusChip(count: search.isEmpty ? tiles.count : visibleTiles.count,
                               label: search.isEmpty ? "tiles" : "of \(tiles.count) tiles")
                    if let count = map?.dataSources.count, count > 0 {
                        Button(action: onShowList) { statusChip(count: count, label: "data sources") }
                            .buttonStyle(.plain).help("Open the data sources in List")
                    }
                    Spacer()
                    Text(notice ?? "This Mac · Current state").foregroundStyle(.secondary)
                } else {
                    Text(isLoading ? "Reading state…" : (errorMessage == nil ? "No recorded state" : "State unavailable"))
                    Spacer()
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task(id: sourceIdentity) {
            sourceDeclaration = nil
            sourceDeclarationIdentity = ""
            let requestIdentity = sourceIdentity
            guard let address = selectedMember, let directory = workspaceDirectory ?? sourceDirectory else { return }
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
        .onChange(of: selectedTileID) { id in if id != nil { sideFaceID = "inspector" } }
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
                        Text("Endpoints").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(endpointTiles, id: \.id) { tile in
                            if let endpoint = presentation(for: tile).endpoints.first {
                                Button { select(tile) } label: {
                                    Label(endpoint.value, systemImage: "arrow.up.right")
                                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
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
                        Text(kind.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                        ForEach(visibleTiles.filter { $0.kind == kind }, id: \.id) { tile in
                            Button { select(tile) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: symbol(for: tile)).foregroundStyle(tile.kind.color).frame(width: 16)
                                    Text(tile.title).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        .opacity(preview != nil && action(for: tile) == .none ? 0.5 : 1)
                                    if preview != nil, action(for: tile) != .none, action(for: tile) != .read {
                                        Circle().fill(actionColor(action(for: tile))).frame(width: 7, height: 7)
                                    }
                                    Text("\(tile.resources.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
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
                            if let workspaceDirectory {
                                Text(workspaceDirectory.path)
                                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            }
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
                        LoadingIndicator(size: 24, label: "Reading your infrastructure…")
                            .frame(width: viewport.size.width, height: 180)
                    } else if tiles.isEmpty {
                        VStack(spacing: 14) {
                            empty(emptyTitle ?? "No managed resources yet", detail: emptyDetail, symbol: emptySymbol)
                            if let emptyAction {
                                Button(emptyAction.title, action: emptyAction.run).buttonStyle(.borderedProminent)
                            }
                        }.frame(width: viewport.size.width)
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
                                Text("WORKSPACE REFERENCES").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
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
                                                Text(reference.address).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                                Text("This data-source alias is recorded in this workspace’s state. The destination workspace has not been verified.")
                                                    .font(.system(size: 13)).foregroundStyle(.secondary)
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
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
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
            MapCanvasLayout(map: ResourceMap(tiles: visibleTiles, connections: (preview?.map ?? map)?.connections ?? [], dataSources: []),
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
            .overlay(tileOutline(tile))
            .overlay(alignment: .bottomTrailing) {
                if preview != nil, let word = actionWord(action(for: tile)) {
                    Text(word).font(.system(size: 12, weight: .semibold)).foregroundStyle(actionColor(action(for: tile)))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(actionColor(action(for: tile)).opacity(0.14), in: Capsule())
                        .padding(8)
                }
            }
            .opacity(preview != nil && action(for: tile) == .none ? 0.45 : 1)
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

    // MARK: Preview Changes

    /// Change semantics never share a color with resource kinds (DESIGN.md §3).
    private func actionColor(_ action: MapChangeAction) -> Color {
        switch action {
        case .create: .green
        case .update: .orange
        case .replace: Color(red: 0.86, green: 0.25, blue: 0.55)
        case .delete: .red
        case .read, .none: .secondary
        }
    }

    private func actionWord(_ action: MapChangeAction) -> String? {
        switch action {
        case .create: "New"
        case .update: "Will change"
        case .replace: "Will be replaced"
        case .delete: "Will be removed"
        case .read: "Read"
        case .none: nil
        }
    }

    @ViewBuilder private func tileOutline(_ tile: MapTile) -> some View {
        let selected = selectedTileID == tile.id
        let action = action(for: tile)
        if preview != nil, action != .none, action != .read {
            // New things arrive as dashed outlines; everything else gets a solid colored edge.
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(actionColor(action), style: StrokeStyle(lineWidth: selected ? 2.5 : 2, dash: action == .create ? [6, 4] : []))
                .shadow(color: actionColor(action).opacity(0.35), radius: 6)
        } else {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 1)
        }
    }

    /// Consequences beside the decision (Exploration C): counts, the one thing
    /// that can hurt you, then Discard and Review.
    private func reviewBar(_ preview: MapChangePreview) -> some View {
        let c = preview.consequences
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                consequence(c.create, "to add", .green)
                consequence(c.update, "to change", .orange)
                consequence(c.replace, "to replace", actionColor(.replace))
                consequence(c.destroy, "to remove", .red)
                Spacer()
                Toggle("Changes only", isOn: $changesOnly).toggleStyle(.checkbox).font(.system(size: 13))
                if let onDiscardPreview { Button("Discard Preview", action: onDiscardPreview).buttonStyle(.bordered) }
                if let onReviewPreview { Button("Review and Apply…", action: onReviewPreview).buttonStyle(.borderedProminent) }
            }
            if let warning = previewWarning(preview) {
                Text(warning).font(.system(size: 13)).foregroundStyle(actionColor(.replace))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func consequence(_ count: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(count, format: .number).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(count > 0 ? color : .secondary)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The first replacement or removal, named by its tile: the thing to read before applying.
    private func previewWarning(_ preview: MapChangePreview) -> String? {
        if let tile = tiles.first(where: { preview.tileActions[$0.id] == .replace }) {
            return "\(tile.title) will be replaced. Terraform recreates it; anything only it holds is lost once the new one is up."
        }
        if let tile = tiles.first(where: { preview.tileActions[$0.id] == .delete }) {
            return "\(tile.title) will be removed."
        }
        return nil
    }

    /// The right pane: a segmented control first, then the chosen face. With no
    /// extra faces it is the plain Inspector.
    private var sidePane: some View {
        VStack(spacing: 0) {
            if !sideFaces.isEmpty {
                Picker("Inspector face", selection: $sideFaceID) {
                    Text("Inspector").tag("inspector")
                    ForEach(sideFaces) { face in
                        Text(face.count.map { "\(face.title) \($0)" } ?? face.title).tag(face.id)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            if sideFaceID == "inspector" || sideFaces.first(where: { $0.id == sideFaceID }) == nil {
                inspector
            } else if let face = sideFaces.first(where: { $0.id == sideFaceID }) {
                face.content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var inspector: some View {
        ScrollView {
            if let tile = selectedTile {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Inspector").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Button { selectedTileID = nil; selectedMember = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Deselect resource")
                            .help("Deselect")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(for: tile)).font(.title2).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(tile.kind.color, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.title).font(.title3.weight(.semibold))
                            Text(presentation(for: tile).subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Label("Recorded in Terraform state", systemImage: "checkmark.circle")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .help("This describes the loaded state. Live health and configuration drift have not been checked.")
                    Divider()
                    Text("At a glance").font(.headline)
                    if presentation(for: tile).facts.isEmpty {
                        Text("\(tile.resources.count) managed resources · \(tile.kind.title)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation(for: tile).facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(fact.label).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(fact.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                            MapCopyButton(value: fact.value, label: fact.label)
                        }.font(.system(size: 13))
                    }
                    }
                    if !presentation(for: tile).endpoints.isEmpty {
                        Divider()
                        Text("Endpoints").font(.headline)
                        ForEach(presentation(for: tile).endpoints) { endpoint in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(endpoint.label).font(.system(size: 13)).foregroundStyle(.secondary)
                                    Spacer()
                                    MapCopyButton(value: endpoint.value, label: endpoint.label)
                                }
                                if let url = endpoint.url {
                                    Link(endpoint.value, destination: url).lineLimit(3)
                                } else {
                                    Text(endpoint.value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    connections(for: tile)
                    Divider()
                    sourceSection
                    Divider()
                    referenceSection.id(selectedMember)
                    Divider()
                    historySection
                    Divider()
                    // Each resource owns its attributes; the open one is the selected member.
                    Text("Resources · \(tile.resources.count)").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tile.resources, id: \.self) { address in
                            DisclosureGroup(isExpanded: Binding(
                                get: { selectedMember == address },
                                set: { expanded in selectedMember = expanded ? address : (selectedMember == address ? nil : selectedMember) })) {
                                memberDetails(address)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(address).font(.system(size: 13, design: .monospaced)).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    MapCopyButton(value: address, label: "resource address")
                                }
                            }
                            .padding(8)
                            .background(selectedMember == address ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }.padding(18)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.title3.weight(.semibold))
                        if let workspaceDescription, !workspaceDescription.isEmpty {
                            Text(workspaceDescription).font(.system(size: 13)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Select a resource on the Map or in the inventory to inspect it.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if map != nil {
                        Divider()
                        historySection
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .id(selectedTileID)
    }

    @ViewBuilder private func memberDetails(_ address: String) -> some View {
        if let resource = resources.first(where: { $0.address == address }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(resource.type).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    MapCopyButton(value: resource.type, label: "resource type")
                    Button("Full inspector") { onOpenResource(resource.address) }.buttonStyle(.link).font(.system(size: 13))
                }
                ForEach(Array(resource.displayAttributes.prefix(14))) { attribute in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(attribute.path).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            if !attribute.value.contains("(sensitive value)") {
                                MapCopyButton(value: attribute.value, label: "attribute value")
                            }
                        }
                        Text(attribute.value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }
                if resource.displayAttributes.count > 14 {
                    Text("Open the full inspector for all attributes.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.top, 6)
        } else {
            Text("Attributes are unavailable for this resource.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Link to the declaring file on the repository host when the workspace is
    /// repository-backed (GitHub-style blob URLs with a line anchor).
    private func repositoryFileURL(file: String, line: Int?) -> URL? {
        // Only https repository hosts; the URL comes from the API and must not open other schemes.
        guard let repository, let base = repository.cloneURL, base.scheme?.lowercased() == "https" else { return nil }
        var path = file
        if let directory = repository.workingDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !directory.isEmpty {
            path = directory + "/" + file
        }
        let ref = (repository.branch?.isEmpty == false) ? repository.branch! : "HEAD"
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let host = components.host?.lowercased() ?? ""
        let segment = host.contains("gitlab") ? "-/blob" : (host.contains("bitbucket") ? "src" : "blob")
        components.path = components.path.replacingOccurrences(of: ".git", with: "") + "/\(segment)/\(ref)/\(path)"
        components.fragment = line.map { host.contains("bitbucket") ? "lines-\($0)" : "L\($0)" }
        return components.url
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Defined in").font(.headline)
            if let resource = selectedResource {
                HStack(alignment: .top) {
                    Text(resource.address).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    MapCopyButton(value: resource.address, label: "resource address")
                }
                if sourceDeclarationIdentity == sourceIdentity, let declaration = sourceDeclaration,
                   let directory = workspaceDirectory ?? sourceDirectory,
                   let filename = TerraformDiagnosticSource.currentWorkspaceFile(filename: declaration.sourceFile, workspaceDirectory: directory) {
                    HStack {
                        Button {
                            NSWorkspace.shared.open(directory.appendingPathComponent(filename))
                        } label: { Label(declaration.sourceLocation, systemImage: "chevron.left.forwardslash.chevron.right") }
                            .buttonStyle(.link).help("Open declaration in your default editor")
                        Spacer()
                        MapCopyButton(value: declaration.sourceLocation, label: "source location")
                    }
                    if workspaceDirectory == nil {
                        Text("From the checkout at \(directory.path)").font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let url = repositoryFileURL(file: declaration.sourceFile, line: declaration.sourceLine) {
                        Link(destination: url) { Label("Open on \(url.host ?? "the repository")", systemImage: "arrow.up.right.square") }
                            .font(.system(size: 13))
                    }
                } else if let repository, let base = repository.cloneURL, base.scheme?.lowercased() == "https" {
                    Text(workspaceDirectory == nil && sourceDirectory == nil
                         ? "File and line are not included in remote Terraform state. Check the repository out to resolve them."
                         : "No matching source declaration found in the checkout.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Link(destination: base) { Label("Open \(repository.displayName)", systemImage: "arrow.up.right.square") }.font(.system(size: 13))
                } else {
                    Text(workspaceDirectory == nil ? "File and line are not included in remote Terraform state." : "No matching source declaration found in this folder.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let workspaceURL { Link("Open workspace in HCP Terraform", destination: workspaceURL).font(.system(size: 13)) }
        }
    }

    @ViewBuilder private var referenceSection: some View {
        if let resource = selectedResource {
            MapResourceReference(resource: resource, workspaceDirectory: workspaceDirectory,
                                 terraformExecutableURL: terraformExecutableURL,
                                 workspaceInitialized: workspaceInitialized)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.headline)
            if let stateCreatedAt {
                Text("State recorded \(stateCreatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 13))
            }
            if let stateSerial { Text("State revision \(stateSerial)").font(.system(size: 13)).foregroundStyle(.secondary) }
            if let stateVersionID {
                HStack(alignment: .top) {
                    Text(stateVersionID).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    MapCopyButton(value: stateVersionID, label: "state version")
                }
            }
            Text(notice == HCPMapSnapshot.noStateRecorded.notice
                 ? "No state has been recorded yet; the first applied run creates it."
                 : "Current state does not include this resource’s creation or last-change history.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
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
                    Text("Grouped connections").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Different resources inside these groups have dependencies in both directions. A two-way group link does not imply a circular resource dependency.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    connectionGroup(nil, connections: mixed, selected: tile.id)
                }
            }
        }
    }

    @ViewBuilder private func connectionGroup(_ label: String?, connections: [MapConnection], selected: String) -> some View {
        if !connections.isEmpty {
            if let label { Text(label).font(.system(size: 13)).foregroundStyle(.secondary) }
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
                                    }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 6)
                                }
                            }.font(.system(size: 13))
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
            Text(count, format: .number).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.primary)
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
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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

/// Registry links, installed-provider attributes and Registry documentation for one resource.
/// Owns its models, so selecting another resource (keyed by `.id`) starts clean.
private struct MapResourceReference: View {
    let resource: MapDisplayResource
    let workspaceDirectory: URL?
    let terraformExecutableURL: URL?
    let workspaceInitialized: Bool
    @StateObject private var schemaHelp = TerraformProviderSchemaHelpModel()
    @StateObject private var registryDocs = TerraformRegistryDocsModel()
    @State private var showsSchema = false
    @State private var showsDocs = false
    @State private var expandedAttributes: Set<String> = []

    private var mode: String { resource.address.hasPrefix("data.") || resource.address.contains(".data.") ? "data" : "managed" }
    private var parts: (namespace: String, name: String)? {
        resource.providerName.flatMap(TerraformRegistryDocsModel.registryParts)
    }
    private var documentation: TerraformProviderDocumentation? {
        TerraformProviderDocumentation.resolve(
            providerIdentity: resource.providerName, resourceType: resource.type, resourceMode: mode,
            lockFile: workspaceDirectory?.appendingPathComponent(".terraform.lock.hcl"))
    }
    private var version: String? { documentation?.lockedVersion ?? registryDocs.document?.version }
    private var resourceURL: URL? {
        if let url = documentation?.resourceURL { return url }
        if let url = registryDocs.document?.url { return url }
        guard let parts, let slug = TerraformRegistryDocsModel.slug(resourceType: resource.type, providerName: parts.name) else { return nil }
        return URL(string: "https://registry.terraform.io/providers/\(parts.namespace)/\(parts.name)/latest/docs/\(mode == "data" ? "data-sources" : "resources")/\(slug)")
    }
    private var providerURL: URL? {
        if let url = documentation?.providerURL { return url }
        guard let parts else { return nil }
        return URL(string: "https://registry.terraform.io/providers/\(parts.namespace)/\(parts.name)/\(version ?? "latest")")
    }
    private var canReadSchema: Bool {
        workspaceDirectory != nil && workspaceInitialized && terraformExecutableURL != nil && resource.providerName != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reference").font(.headline)
            HStack(spacing: 6) {
                Text(resource.type).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if let parts {
                    Text("\(parts.namespace)/\(parts.name)\(version.map { " \($0)" } ?? "")")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if parts != nil {
                HStack(spacing: 12) {
                    if let resourceURL { Link("Open in Registry", destination: resourceURL).font(.system(size: 13)) }
                    if let providerURL { Link("Provider", destination: providerURL).font(.system(size: 13)) }
                }
            } else {
                Text("This provider isn't in the Terraform Registry.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if canReadSchema { schemaDisclosure }
            if parts != nil { docsDisclosure }
        }
    }

    private var schemaDisclosure: some View {
        DisclosureGroup(isExpanded: $showsSchema) {
            VStack(alignment: .leading, spacing: 8) {
                if schemaHelp.isLoading(for: resource.providerName, resourceType: resource.type, mode: mode) {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading installed providers…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else if let message = schemaHelp.message(for: resource.providerName, resourceType: resource.type, mode: mode) {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let attributes = schemaHelp.attributes(for: resource.providerName, resourceType: resource.type, mode: mode) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(attributes) { attribute in attributeRow(attribute) }
                    }
                }
            }.padding(.top, 6)
        } label: { Text("Attribute reference").font(.system(size: 13)) }
        .onChange(of: showsSchema) { open in
            guard open, schemaHelp.attributes(for: resource.providerName, resourceType: resource.type, mode: mode) == nil else { return }
            schemaHelp.load(directory: workspaceDirectory, executable: terraformExecutableURL,
                            workspaceInitialized: workspaceInitialized, providerIdentity: resource.providerName,
                            resourceType: resource.type, mode: mode)
        }
    }

    private func attributeRow(_ attribute: TerraformSchemaAttribute) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(attribute.path).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if attribute.required { chip("Required") }
                if attribute.optional { chip("Optional") }
                if attribute.computed { chip("Computed") }
                if attribute.sensitive { chip("Sensitive") }
            }
            if let type = attribute.type {
                Text(type).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let text = attribute.description, !text.isEmpty {
                let open = expandedAttributes.contains(attribute.path)
                Text(verbatim: text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(open ? nil : 3).textSelection(.enabled)
                    .onTapGesture { if open { expandedAttributes.remove(attribute.path) } else { expandedAttributes.insert(attribute.path) } }
            }
        }
    }

    private func chip(_ label: String) -> some View {
        Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
    }

    private var docsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsDocs) {
            VStack(alignment: .leading, spacing: 8) {
                if registryDocs.isLoading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading from the Terraform Registry…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else if let message = registryDocs.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let document = registryDocs.document {
                    ForEach(Array(orderedSections(document.markdown).enumerated()), id: \.offset) { _, section in
                        DisclosureGroup {
                            Text(verbatim: section.body).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        } label: { Text(verbatim: section.title).font(.system(size: 13, weight: .semibold)) }
                    }
                }
            }.padding(.top, 6)
        } label: { Text("Registry documentation").font(.system(size: 13)) }
        .onChange(of: showsDocs) { open in
            guard open, registryDocs.document == nil, !registryDocs.isLoading else { return }
            Task {
                await registryDocs.load(providerIdentity: resource.providerName, resourceType: resource.type,
                                        mode: mode, preferredVersion: documentation?.lockedVersion)
            }
        }
    }

    private func orderedSections(_ markdown: String) -> [(title: String, body: String)] {
        let all = TerraformRegistryDocsModel.sections(from: markdown)
        func rank(_ title: String) -> Int {
            let lower = title.lowercased()
            if lower.hasPrefix("argument") { return 0 }
            if lower.hasPrefix("attribute") { return 1 }
            return lower == "overview" ? 3 : 2
        }
        return Array(all.enumerated().sorted { (rank($0.element.title), $0.offset) < (rank($1.element.title), $1.offset) }
            .map(\.element).prefix(12))
    }
}
