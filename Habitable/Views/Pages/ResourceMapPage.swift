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
    var selectionRequest: MapSelectionRequest? = nil
    var listMode = false
    var onShowOnMap: ((String) -> Void)? = nil
    var onOpenSource: ((String) -> Void)? = nil
    var onShowPlanOutput: (() -> Void)? = nil
    var autoApplyBadge: String? = nil
    var welcome: MapWelcome? = nil
    var onPreviewChanges: (() -> Void)? = nil
    var onReadReadme: (() -> Void)? = nil
    var liveApply: [String: MapLiveApplyState] = [:]

    var body: some View {
        ResourceMapContent(
            title: workspace.isMapDemo ? "Acme · Sample workspace" : (workspace.workingDirectory?.lastPathComponent ?? "Infrastructure"),
            identity: "\(workspace.workingDirectory?.path ?? "sample")|\(workspace.state?.id.uuidString ?? "")|\(workspace.viewingLocalVersion?.id ?? "")",
            map: workspace.viewingLocalVersion != nil ? workspace.historicalMap : workspace.resourceMap,
            resources: ((workspace.viewingLocalVersion != nil ? workspace.historicalState : workspace.state)?.resources ?? []).compactMap { resource in
                guard let address = resource.address, let type = resource.type else { return nil }
                return MapDisplayResource(address: address, type: type, displayAttributes: resource.displayAttributes,
                                          providerName: resource.provider_name)
            },
            notice: workspace.viewingLocalVersion.map { "State as recorded \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? workspace.mapNotice,
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
            historyBanner: workspace.viewingLocalVersion.map { version in
                (text: "State as recorded \(version.date.formatted(date: .abbreviated, time: .shortened)) · \(version.resourceCount) resources",
                 dismiss: { workspace.returnToCurrentLocalState() })
            },
            preview: preview, onDiscardPreview: onDiscardPreview, onReviewPreview: onReviewPreview,
            onShowPlanOutput: onShowPlanOutput, autoApplyBadge: autoApplyBadge,
            selectionRequest: selectionRequest,
            listMode: listMode, onShowOnMap: onShowOnMap, onOpenSource: onOpenSource,
            welcome: welcome, onPreviewChanges: onPreviewChanges, onReadReadme: onReadReadme,
            liveApply: liveApply,
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

/// Asks the Map's right pane to show a face; a new `id` repeats the request.
struct MapSideFaceRequest: Equatable {
    let id = UUID()
    let faceID: String
}

/// Exploration D's empty-map welcome: a folder that describes things which do
/// not exist yet. Says what is true in a sentence, then the one next action.
struct MapWelcome: Equatable {
    struct Declared: Equatable, Identifiable {
        let address: String
        let type: String
        var sourceFile: String = ""
        var id: String { address }
    }
    /// A `module` block: the folder calls it, and it brings its own resources.
    struct DeclaredModule: Equatable, Identifiable {
        let name: String
        let source: String
        var version: String? = nil
        var sourceFile: String = ""
        var id: String { name }
        /// Public Registry page when the source is a `namespace/name/provider` path.
        var registryURL: URL? {
            let parts = source.split(separator: "/")
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && !$0.contains(".") && !$0.contains(":") }) else { return nil }
            return URL(string: "https://registry.terraform.io/modules/\(source)" + (version.map { "/\($0)" } ?? ""))
        }
    }
    let declared: [Declared]
    let hasReadme: Bool
    let previewTitle: String
    /// Required inputs with no value yet, by name.
    var neededInputs: [String] = []
    var modules: [DeclaredModule] = []

    /// "2 resources", "1 module", or "2 resources and calls 1 module".
    var declaresPhrase: String {
        let count = declared.count
        let resources = "\(count) \(count == 1 ? "resource" : "resources")"
        let calls = "\(modules.count) \(modules.count == 1 ? "module" : "modules")"
        if modules.isEmpty { return "declares \(resources)" }
        if declared.isEmpty { return "calls \(calls)" }
        return "declares \(resources) and calls \(calls)"
    }

    /// "main.tf" or "main.tf and 2 other files".
    var filesPhrase: String {
        let files = Array(Set((declared.map(\.sourceFile) + modules.map(\.sourceFile)).filter { !$0.isEmpty })).sorted()
        guard let first = files.first else { return "The configuration" }
        if files.count == 1 { return first }
        return "\(first) and \(files.count - 1) other \(files.count == 2 ? "file" : "files")"
    }
}

/// Asks the Map to select a resource (from the List or a palette); a new `id` repeats it.
struct MapSelectionRequest: Equatable {
    let id = UUID()
    let address: String
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
    /// Review-bar verbs. Local: discard the saved plan, open it to apply. Cloud:
    /// discard the remote run, confirm its apply.
    var previewDiscardTitle = "Discard Preview"
    var previewReviewTitle = "Review and Apply…"
    /// A caption under the counts, e.g. which remote run the preview came from.
    var previewCaption: String? = nil
    /// Opens the raw plan output (the run page) for anyone who wants the exact text.
    var onShowPlanOutput: (() -> Void)? = nil
    /// "Applies automatically" / "Applies without confirmation": shown as a
    /// persistent badge, never a silent setting.
    var autoApplyBadge: String? = nil
    /// True when the review action applies directly (cloud Confirm Apply): a
    /// preview that replaces or removes then needs a press-and-hold.
    var previewReviewIsApply = false
    /// Another part of the window asking the right pane to show a face.
    var faceRequest: MapSideFaceRequest? = nil
    /// Another part of the window asking the Map to select a resource.
    var selectionRequest: MapSelectionRequest? = nil
    /// The List (Exploration E): the same workspace as a table where the canvas
    /// was, with the same Inspector and faces beside it.
    var listMode = false
    var onShowOnMap: ((String) -> Void)? = nil
    var onOpenSource: ((String) -> Void)? = nil
    /// Shown instead of the empty state when the folder declares resources but none exist yet.
    var welcome: MapWelcome? = nil
    var onPreviewChanges: (() -> Void)? = nil
    var onReadReadme: (() -> Void)? = nil
    /// Per-resource apply progress while Terraform is applying (design: "Changes that arrive").
    var liveApply: [String: MapLiveApplyState] = [:]
    @State private var listSelection: Set<String> = []

    private var listRows: [ResourceListRow] {
        var actions: [String: String] = [:]
        for (address, action) in preview?.resourceActions ?? [:] where action != .none { actions[address] = "\(action)" }
        return ResourceListBuilder.rows(resources: resources, tiles: tiles, actions: actions, drifted: preview?.driftedAddresses ?? [])
    }

    private var listTable: some View {
        ResourceTableView(rows: listRows, selection: $listSelection,
                          isLoading: isLoading && map == nil,
                          emptyTitle: emptyTitle ?? "No resources",
                          emptyDetail: emptyDetail ?? "Resources appear here after they are recorded in Terraform state.",
                          onShowOnMap: onShowOnMap,
                          onOpenReference: { row in
                              if let url = TerraformRegistryDocsModel.documentationURL(type: row.type, providerName: row.provider, mode: row.isDataSource ? "data" : "managed") {
                                  NSWorkspace.shared.open(url)
                              }
                          },
                          onOpenSource: onOpenSource)
            .onChange(of: listSelection) { ids in
                if ids.count == 1, let address = ids.first { select(address: address) }
                else if ids.isEmpty { selectedTileID = nil; selectedMember = nil }
            }
    }
    @State private var changesOnly = false
    var terraformExecutableURL: URL? = nil
    var workspaceInitialized = false
    @SceneStorage("map.sideFace") private var sideFaceID = "inspector"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            if !listMode {
                header
                Divider()
            }
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
                    if showingInventory, !tiles.isEmpty, !listMode {
                        inventory.frame(width: 224).frame(maxHeight: .infinity)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Divider()
                    }
                    HSplitView {
                        if listMode {
                            listTable.frame(minWidth: 330, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        } else {
                            canvas.frame(minWidth: 330, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        }
                        if selectedTile != nil || !sideFaces.isEmpty {
                            sidePane.frame(minWidth: 320, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
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
        .onChange(of: faceRequest?.id) { _ in if let faceRequest { sideFaceID = faceRequest.faceID } }
        .onChange(of: selectionRequest?.id) { _ in if let selectionRequest { select(address: selectionRequest.address) } }
        // A request made before this content existed (the window was still connecting).
        .onAppear { if let faceRequest { sideFaceID = faceRequest.faceID } }
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
                    } else if tiles.isEmpty, let welcome, emptyTitle == nil {
                        welcomeView(welcome).frame(width: viewport.size.width, alignment: .leading)
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
                                        // Time travel: tiles arrive and leave rather than blink.
                                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                                }
                            }
                        }
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78), value: visibleTiles.map(\.id))
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
        return tileButtonBody(tile, copies: copies)
            .quickHelp(tile.title, "A tile is one thing on the Map: \(tile.resources.count == 1 ? "one resource" : "\(tile.resources.count) resources that belong together"), placed in the \(tile.kind.title) row because of what its resources do. Click it to inspect facts, connections and where it is defined.")
    }

    private func tileButtonBody(_ tile: MapTile, copies: Int) -> some View {
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
            .overlay {
                if tileDrifted(tile) { DriftPulse() }
            }
            .modifier(LiveApplyTileEffect(state: liveState(for: tile)))
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

    private func tileDrifted(_ tile: MapTile) -> Bool {
        guard let preview, !preview.driftedAddresses.isEmpty else { return false }
        return tile.resources.contains { preview.driftedAddresses.contains($0) }
    }

    /// The tile's state during an apply: failed beats applying beats done.
    private func liveState(for tile: MapTile) -> MapLiveApplyState? {
        guard !liveApply.isEmpty else { return nil }
        let states = tile.resources.compactMap { liveApply[$0] }
        if states.contains(.failed) { return .failed }
        if let applying = states.first(where: { if case .applying = $0 { return true }; return false }) { return applying }
        return states.isEmpty ? nil : .done
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
                // A mode announces itself: the title on the left, the way out on the right.
                Text("Preview").font(.headline).accessibilityAddTraits(.isHeader)
                consequence(c.create, "to add", .green)
                consequence(c.update, "to change", .orange)
                consequence(c.replace, "to replace", actionColor(.replace))
                consequence(c.destroy, "to remove", .red)
                if let autoApplyBadge {
                    Label(autoApplyBadge, systemImage: "bolt.fill").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(.orange).background(Color.orange.opacity(0.14), in: Capsule())
                        .help("This workspace applies as soon as a plan succeeds.")
                }
                Spacer()
                Picker("Show", selection: Binding(get: { changesOnly ? 1 : 0 }, set: { changesOnly = $0 == 1 })) {
                    Text("Everything").tag(0)
                    Text("Changes only").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if let onShowPlanOutput { Button("Show Plan Output", action: onShowPlanOutput).buttonStyle(.link).font(.system(size: 13)) }
                if let onDiscardPreview { Button(previewDiscardTitle, action: onDiscardPreview).buttonStyle(.bordered) }
                if let onReviewPreview {
                    if previewReviewIsApply, c.replace + c.destroy > 0 {
                        HoldToConfirmButton(title: previewReviewTitle, action: onReviewPreview)
                    } else {
                        Button(previewReviewTitle, action: onReviewPreview).buttonStyle(.borderedProminent)
                    }
                }
            }
            if let previewCaption {
                Text(previewCaption).font(.system(size: 13)).foregroundStyle(.secondary)
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
        .quickHelp(glossary: label == "to replace" ? "replace" : (label == "to remove" ? "remove" : (label == "to add" ? "plan" : "apply")))
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
                if listMode, selectedTile != nil, let address = selectedMember { listInspector(address) } else { inspector }
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
                        Text("\(tile.resources.count) managed \(tile.resources.count == 1 ? "resource" : "resources") · \(tile.kind.title)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation(for: tile).facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(fact.label).foregroundStyle(.secondary)
                                .quickHelp(fact.label, "\(fact.label) as recorded in Terraform state for this resource. Habitable reads it from state; it does not query the provider live.")
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
                    if let resource = selectedResource, let drift = preview?.drift(for: resource.address) {
                        Divider()
                        driftSection(drift, address: resource.address)
                    }
                    Divider()
                    sourceSection
                    Divider()
                    referenceSection.id(selectedMember)
                    Divider()
                    historySection(forResource: true)
                    Divider()
                    // Each resource owns its attributes; the open one is the selected member.
                    Text("Resources · \(tile.resources.count)").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tile.resources, id: \.self) { address in
                            DisclosureGroup(isExpanded: Binding(
                                get: { selectedMember == address },
                                set: { expanded in selectedMember = expanded ? address : (selectedMember == address ? nil : selectedMember) })) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let change = preview?.change(for: address) { whatChanges(change) }
                                    memberDetails(address)
                                }
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
                        historySection(forResource: false)
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
                .quickHelp("Defined in", "The file and line in this folder's configuration that declares the resource. Edit it there; Habitable never becomes an editor.")
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
            if let workspaceURL { ExternalLink(title: "Open workspace in HCP Terraform", url: workspaceURL) }
        }
    }

    @ViewBuilder private var referenceSection: some View {
        if let resource = selectedResource {
            MapResourceReference(resource: resource, workspaceDirectory: workspaceDirectory,
                                 terraformExecutableURL: terraformExecutableURL,
                                 workspaceInitialized: workspaceInitialized)
        }
    }

    private func historySection(forResource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.headline).quickHelp(glossary: "state")
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
                 : (forResource ? "Current state does not include this resource’s creation or last-change history."
                                : "State records what exists now, not when each resource was created or last changed. The Changes strip has the runs."))
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

    /// "This folder describes 2 things. None of them exist yet." Then the action,
    /// the three steps, and the declared resources as cards that will be created.
    private func welcomeView(_ welcome: MapWelcome) -> some View {
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Declared, not built.").font(.system(size: 20, weight: .semibold))
                Text("\(welcome.filesPhrase) \(welcome.declaresPhrase). None exist yet. \(welcome.previewTitle) shows what Terraform would create; nothing changes until you apply.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
            }
            if !welcome.neededInputs.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Needs from you").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(welcome.neededInputs.joined(separator: ", ")).font(.system(size: 13, design: .monospaced))
                    Text("· set them in Inputs before previewing").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .quickHelp(glossary: "variable")
            }
            HStack(spacing: 10) {
                if let onPreviewChanges {
                    Button(welcome.previewTitle, action: onPreviewChanges).buttonStyle(.borderedProminent)
                }
                if welcome.hasReadme, let onReadReadme {
                    Button("Read the README", action: onReadReadme)
                }
            }
            HStack(spacing: 8) {
                Text("Steps").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(Array(["Preview", "Review", "Apply"].enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 6) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(index == 0 ? Color.white : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(index == 0 ? Color.accentColor : Color.secondary.opacity(0.18), in: Circle())
                        Text(step).font(.system(size: 13, weight: index == 0 ? .medium : .regular))
                    }
                    if index < 2 { Text("→").foregroundStyle(.tertiary) }
                }
            }
            if !welcome.declared.isEmpty || !welcome.modules.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Declared in \(welcome.filesPhrase)").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(welcome.modules) { module in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(module.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(module.source + (module.version.map { " v\($0)" } ?? ""))
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 8) {
                                    Text("Module · its resources appear after Preview").font(.system(size: 12)).foregroundStyle(.secondary)
                                    if let url = module.registryURL {
                                        ExternalLink(title: "Registry", url: url, font: .system(size: 12))
                                    }
                                }
                            }
                            .quickHelp(glossary: "module")
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color.green.opacity(0.6)))
                        }
                        ForEach(welcome.declared.prefix(12)) { declared in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(declared.address.split(separator: ".").last.map(String.init) ?? declared.address)
                                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(declared.type).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                Text("Will be created").font(.system(size: 12)).foregroundStyle(.green)
                            }
                            .quickHelp("Declared, not created", "This resource is described in the folder's files. It does not exist anywhere yet; Preview Changes shows what creating it would do.")
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color.green.opacity(0.6)))
                        }
                    }
                    if welcome.declared.count > 12 {
                        Text("and \(welcome.declared.count - 12) more").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
    }

    /// The List's inspector is about one resource: its name and type, address,
    /// status, what the plan changes, where it is defined, its reference, its
    /// attributes, and history. The tile it belongs to is one fact among others.
    private func listInspector(_ address: String) -> some View {
        let row = listRows.first { $0.address == address }
        let tile = selectedTile
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Inspector").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Button { listSelection = []; selectedTileID = nil; selectedMember = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Deselect resource").help("Deselect")
                }
                HStack(alignment: .top, spacing: 12) {
                    if let tile {
                        Image(systemName: symbol(for: tile)).font(.title2).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(tile.kind.color, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row?.name ?? address).font(.title3.weight(.semibold))
                        Text(row?.type ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(address).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MapCopyButton(value: address, label: "resource address")
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let row {
                        listFact("Status", row.status == "unchanged" ? "In state" : row.status.capitalized)
                        listFact("Module", row.module)
                        if !row.kind.isEmpty { listFact("Kind", row.kind) }
                        if let tile, tile.resources.count > 1 { listFact("Tile", "\(tile.title) · \(tile.resources.count) resources") }
                        listFact("Provider", row.provider)
                    }
                }
                if let change = preview?.change(for: address) { whatChanges(change) }
                Divider()
                Text("Attributes").font(.headline)
                memberDetails(address)
                Divider()
                sourceSection
                Divider()
                referenceSection.id(selectedMember)
                Divider()
                historySection(forResource: true)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func listFact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
    }

    /// Exploration C's "What changes": each attribute the plan changes, before → after,
    /// with the ones that force a replacement called out.
    private func whatChanges(_ change: PlanResourceChange) -> some View {
        let word: String = {
            switch MapChangePreview.action(for: change) {
            case .create: return "Will be created"
            case .update: return "Will change"
            case .replace: return "Will be replaced · delete, then create"
            case .delete: return "Will be removed"
            case .read: return "Will be read"
            case .none: return "No change"
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text("What changes").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(word).font(.system(size: 13, weight: .medium)).foregroundStyle(actionColor(MapChangePreview.action(for: change)))
            ForEach(change.attributes.prefix(12)) { attribute in
                HStack(alignment: .top, spacing: 6) {
                    Text(attribute.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading).lineLimit(1).truncationMode(.middle)
                    if change.replacementPaths.contains(attribute.path) {
                        Text("forces replacement").font(.system(size: 11, weight: .medium)).foregroundStyle(actionColor(.replace))
                    }
                    Text(attribute.before.displayValue).font(.system(size: 12, design: .monospaced)).lineLimit(2).strikethrough(attribute.after != attribute.before && attribute.before != .absent)
                    Text("→").foregroundStyle(.secondary)
                    Text(attribute.after.displayValue).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                }
            }
            if change.attributes.count > 12 {
                Text("and \(change.attributes.count - 12) more attributes").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(actionColor(MapChangePreview.action(for: change)).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Drift: what the refresh found versus what state recorded, and the two honest
    /// answers. "Put it back" reviews the plan that restores the code's version;
    /// "Keep it" opens the declaration with the live values on the clipboard.
    private func driftSection(_ drift: PlanResourceChange, address: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(.orange)
                Text("Changed outside Terraform").font(.headline)
            }
            .quickHelp(glossary: "drift")
            Text("Someone or something changed this resource without Terraform. State recorded the left value; the resource now has the right one.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(drift.attributes.prefix(12)) { attribute in
                HStack(alignment: .top, spacing: 6) {
                    Text(attribute.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading).lineLimit(1).truncationMode(.middle)
                    Text(attribute.before.displayValue).font(.system(size: 12, design: .monospaced)).lineLimit(2).strikethrough()
                    Text("→").foregroundStyle(.secondary)
                    Text(attribute.after.displayValue).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                }
            }
            if drift.attributes.count > 12 {
                Text("and \(drift.attributes.count - 12) more attributes").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let onReviewPreview {
                    Button("Put it back", action: onReviewPreview).buttonStyle(.borderedProminent)
                        .help("Review and apply the plan, which restores what the code declares")
                }
                if let onOpenSource {
                    Button("Keep it and update code") {
                        let snippet = drift.attributes.map { "\($0.path) = \($0.after.displayValue)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        onOpenSource(address)
                    }
                    .help("Opens the declaration in your editor; the live values are on the clipboard")
                }
            }
            Text("Nothing changes until you apply. Put it back needs an apply; keeping it needs a code change, then a plan that shows no changes.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Selects the tile holding an address and opens that resource in the Inspector.
    private func select(address: String) {
        guard let tile = tiles.first(where: { $0.resources.contains(address) || $0.anchors.contains(address) || $0.id == address }) else { return }
        search = ""
        selectedTileID = tile.id
        selectedMember = address
        sideFaceID = "inspector"
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
            Text("Reference").font(.headline).quickHelp(glossary: "provider")
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

// MARK: - Signature details: drift pulse and live apply

/// An amber pulse on a drifted tile; a steady amber edge with Reduce Motion.
struct DriftPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: 13)
            .strokeBorder(Color.orange, lineWidth: 2)
            .shadow(color: Color.orange.opacity(on ? 0.55 : 0.1), radius: on ? 10 : 2)
            .opacity(on ? 1 : 0.55)
            .onAppear {
                guard !reduceMotion else { on = true; return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Ring while applying, a settle when done, a shake on failure.
struct LiveApplyTileEffect: ViewModifier {
    let state: MapLiveApplyState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var shakes = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                switch state {
                case .applying(let elapsed):
                    HStack(spacing: 5) {
                        ApplyRing().frame(width: 14, height: 14)
                        if let elapsed, let seconds = Double(elapsed), seconds >= 1 {
                            Text("\(Int(seconds))s").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(6).background(Color(nsColor: .controlBackgroundColor), in: Capsule()).padding(6)
                    .accessibilityLabel("Applying")
                case .done:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(.green)
                        .padding(8).accessibilityLabel("Applied")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(.red)
                        .padding(8).accessibilityLabel("Failed")
                case nil:
                    EmptyView()
                }
            }
            .scaleEffect(settled ? 1 : (state == .done && !reduceMotion ? 1.05 : 1))
            .modifier(ShakeEffect(shakes: CGFloat(shakes)))
            .onChange(of: state) { new in
                if new == .done, !reduceMotion {
                    settled = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { settled = true }
                } else if new == .failed, !reduceMotion {
                    withAnimation(.default) { shakes += 1 }
                }
            }
    }
}

private struct ApplyRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0.1, to: 0.8)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

/// A horizontal shake; `shakes` counts the number of full oscillations.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(shakes * .pi * 4), y: 0))
    }
}
