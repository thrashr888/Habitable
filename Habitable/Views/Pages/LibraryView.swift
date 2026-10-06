import SwiftUI

/// The Library: every workspace you can reach, local folders and HCP Terraform
/// workspaces, as cards (Exploration A; DESIGN.md §2 "Home is a library").
/// Shown in a local window that has no folder open.
struct LibraryView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var cloud: HCPWorkspaceViewerModel
    let recentFolders: [URL]
    let onOpenFolder: (URL) -> Void
    let onChooseFolder: () -> Void
    let onOpenCloud: (HCPWorkspace, String, String) -> Void
    let onOpenConnections: () -> Void

    private enum Section: Hashable { case all, thisMac, cloud(String) }
    @State private var section: Section = .all
    @State private var filter = ""
    @StateObject private var checkout = WorkspaceCheckoutCoordinator()

    private var cloudEntries: [LibraryEntry] {
        guard cloud.isConnected, !cloud.selectedOrganization.isEmpty else { return [] }
        return LibraryModel.cloudEntries(workspaces: cloud.workspaces, organization: cloud.selectedOrganization,
                                         hostname: cloud.hostname)
    }

    private func matches(_ entry: LibraryEntry) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.title.localizedCaseInsensitiveContains(query)
            || entry.location.localizedCaseInsensitiveContains(query)
    }

    private var refreshKey: String {
        library.localEntries.map(\.id).joined(separator: "|") + "||" + cloudEntries.map(\.id).joined(separator: "|")
    }

    private var visibleLocal: [LibraryEntry] {
        switch section {
        case .all, .thisMac: library.localEntries.filter(matches)
        case .cloud: []
        }
    }

    private var visibleCloud: [LibraryEntry] {
        switch section {
        case .all: cloudEntries.filter(matches)
        case .thisMac: []
        case .cloud(let organization):
            organization == cloud.selectedOrganization ? cloudEntries.filter(matches) : []
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            sheet
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Check Out", isPresented: Binding(get: { checkout.errorMessage != nil }, set: { if !$0 { checkout.errorMessage = nil } })) {
            Button("OK", role: .cancel) { checkout.errorMessage = nil }
        } message: { Text(checkout.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in checkout.store.reload() }
        .task(id: recentFolders.map(\.path)) { await library.refreshLocal(folders: recentFolders) }
        .task { if !cloud.isConnected && !cloud.isLoading && cloud.hasStoredCredential { await cloud.connect() } }
        // Cards fill in the background, a few at a time, and refresh every five
        // minutes while the Library is open; a card never waits to be scrolled to.
        .task(id: refreshKey) { await library.refreshAll(library.localEntries + cloudEntries, cloud: cloud) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await library.refreshAll(library.localEntries + cloudEntries, cloud: cloud)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow("All infrastructure", symbol: "globe", count: library.localEntries.count + cloudEntries.count, tag: .all)
                sidebarRow("This Mac", symbol: "folder", count: library.localEntries.count, tag: .thisMac)
            }
            .padding(.top, 12)
            Text("HCP Terraform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
            if cloud.isConnected {
                ForEach(cloud.organizations.isEmpty ? [HCPOrganization(name: cloud.selectedOrganization, email: nil)] : cloud.organizations) { organization in
                    sidebarRow(organization.name, symbol: "cloud",
                               count: organization.name == cloud.selectedOrganization && !cloud.isLoadingWorkspaces ? cloudEntries.count : nil,
                               tag: .cloud(organization.name),
                               busy: organization.name == cloud.selectedOrganization && cloud.isLoadingWorkspaces)
                }
            } else if cloud.isLoading {
                LoadingIndicator(size: 16, label: "Connecting…").padding(.horizontal, 18).padding(.vertical, 6)
            } else {
                Button(action: onOpenConnections) {
                    Label("Connect…", systemImage: "cloud")
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }.buttonStyle(.plain).padding(.horizontal, 8)
                    .help("Sign in to HCP Terraform in Settings")
            }
            Spacer()
            Divider()
            Button(action: onChooseFolder) {
                Label("Open Folder…", systemImage: "folder.badge.plus").font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 12)
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 0)
    }

    private func sidebarRow(_ title: String, symbol: String, count: Int?, tag: Section, busy: Bool = false) -> some View {
        let selected = section == tag
        return Button {
            section = tag
            if case .cloud(let organization) = tag, organization != cloud.selectedOrganization {
                // Switching organizations keeps the connection; only the workspace list reloads.
                Task { await cloud.switchOrganization(organization) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if busy { LoadingIndicator(size: 12) }
                else if let count { Text(count, format: .number).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            if let job = checkout.job {
                HStack(spacing: 10) {
                    LoadingIndicator(size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checking out \(job.title)").font(.system(size: 13, weight: .medium))
                        Text(checkout.progressLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel") { checkout.cancel() }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 24).padding(.vertical, 10)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Library").font(.system(size: 22, weight: .semibold))
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Filter workspaces", text: $filter).textFieldStyle(.plain)
                                .accessibilityLabel("Filter workspaces")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 260)
                        Button("Open Folder…", action: onChooseFolder).buttonStyle(.bordered)
                    }
                    if visibleLocal.isEmpty && visibleCloud.isEmpty {
                        if cloud.isLoadingWorkspaces || (cloud.isLoading && !cloud.isConnected) {
                            LoadingIndicator(size: 22, label: cloud.isConnected ? "Loading \(cloud.selectedOrganization) workspaces…" : "Connecting to HCP Terraform…")
                                .padding(.top, 20)
                        } else {
                            emptyState
                        }
                    }
                    if !visibleLocal.isEmpty {
                        group("This Mac", entries: visibleLocal)
                    }
                    if !visibleCloud.isEmpty {
                        group("\(cloud.selectedOrganization) · HCP Terraform", entries: visibleCloud)
                    }
                    if case .cloud = section, cloud.workspaceHasNextPage {
                        Button("Load More Workspaces") { Task { await cloud.loadNextWorkspacePage() } }
                            .buttonStyle(.borderless).disabled(cloud.isLoading)
                    }
                }
                .padding(24)
            }
            Divider()
            Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
        }
    }

    private var statusLine: String {
        var parts = ["\(library.localEntries.count) folder\(library.localEntries.count == 1 ? "" : "s")"]
        if cloud.isConnected {
            parts.append("\(cloudEntries.count) cloud workspace\(cloudEntries.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !filter.isEmpty {
                Text("No workspaces match “\(filter)”.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else if case .thisMac = section {
                Text("No folders yet. Open a Terraform folder to add it here.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else if case .cloud = section, !cloud.isConnected {
                Text("Connect to HCP Terraform to see its workspaces here.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text("Open a Terraform folder, or connect to HCP Terraform, and its workspaces appear here.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(.top, 20)
    }

    private func group(_ title: String, entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 212, maximum: 260), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 20) {
                ForEach(entries) { entry in
                    LibraryCard(entry: entry, summary: summary(for: entry),
                                isLoading: library.loading.contains(entry.id),
                                failure: library.failures[entry.id],
                                checkoutNote: checkoutNote(for: entry)) { open(entry) }
                        .contextMenu { cardMenu(entry) }
                }
            }
        }
    }

    /// A remote-state folder borrows the summary of the cloud workspace it links to.
    private func summary(for entry: LibraryEntry) -> LibraryStateSummary? {
        if let own = library.summaries[entry.id] { return own }
        if case .localFolder(_, let remote) = entry.kind, let remote, let name = remote.workspaceName,
           let twin = cloudEntries.first(where: { if case .cloud(let workspace, _, _) = $0.kind { return workspace.name == name }; return false }) {
            return library.summaries[twin.id]
        }
        return nil
    }

    /// "Checked out from Rookery" on a folder, "On this Mac" on its workspace.
    private func checkoutNote(for entry: LibraryEntry) -> String? {
        switch entry.kind {
        case .localFolder(let url, _):
            return checkout.store.record(forPath: url).map { "Checked out from \($0.workspaceName)" }
        case .cloud(let workspace, let organization, let hostname):
            let count = checkout.store.records(hostname: hostname, organization: organization, workspaceID: workspace.id).count
            return count > 0 ? "On this Mac" : nil
        }
    }

    @ViewBuilder private func cardMenu(_ entry: LibraryEntry) -> some View {
        switch entry.kind {
        case .localFolder(let url, _):
            Button("Open") { onOpenFolder(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .cloud(let workspace, let organization, let hostname):
            Button("Open in HCP Terraform Window") { onOpenCloud(workspace, organization, hostname) }
            let folders = checkout.store.records(hostname: hostname, organization: organization, workspaceID: workspace.id)
            ForEach(folders, id: \.path) { record in
                Button("Open \(LibraryModel.abbreviatedPath(record.path))") {
                    onOpenFolder(URL(fileURLWithPath: record.path, isDirectory: true))
                }
            }
            if workspace.vcs?.cloneURL != nil {
                Divider()
                Button("Check Out…") {
                    checkout.checkOut(workspace: workspace, organization: organization, hostname: hostname, onOpen: onOpenFolder)
                }.disabled(checkout.job != nil)
            }
            if let url = workspace.htmlURL { Divider(); Link("Open on the Web", destination: url) }
        }
    }

    private func open(_ entry: LibraryEntry) {
        switch entry.kind {
        case .localFolder(let url, _): onOpenFolder(url)
        case .cloud(let workspace, let organization, let hostname): onOpenCloud(workspace, organization, hostname)
        }
    }
}

/// One workspace: a miniature of its map, then what it is and how much it holds.
private struct LibraryCard: View {
    let entry: LibraryEntry
    let summary: LibraryStateSummary?
    let isLoading: Bool
    let failure: String?
    var checkoutNote: String? = nil
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                thumb
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(hovering ? 0.2 : 0.1)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.isCloud ? "cloud" : "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(entry.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    }
                    Text(entry.location).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(detailLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if let checkoutNote {
                        Label(checkoutNote, systemImage: "arrow.down.to.line")
                            .font(.system(size: 12)).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                }.padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel("\(entry.isCloud ? "Cloud workspace" : "Folder") \(entry.title), \(entry.location). \(detailLine)")
    }

    private var detailLine: String {
        if let summary {
            var parts = ["\(summary.resourceCount) resource\(summary.resourceCount == 1 ? "" : "s")"]
            if summary.groupCount > 0 { parts.append("\(summary.groupCount) group\(summary.groupCount == 1 ? "" : "s")") }
            if let recordedAt = summary.recordedAt {
                parts.append(recordedAt.formatted(.relative(presentation: .named)))
            }
            return parts.joined(separator: " · ")
        }
        if isLoading { return "Reading state…" }
        if let failure { return failure }
        if case .localFolder(_, let remote) = entry.kind, remote != nil { return "State in HCP Terraform" }
        return "No recorded state"
    }

    private var helpText: String {
        var lines = [entry.location]
        if let summary, let serial = summary.serial { lines.append("State revision \(serial)") }
        return lines.joined(separator: "\n")
    }

    /// A miniature of the real Map: one band per populated kind, tiles as small
    /// rounded blocks colored by kind, scaled to fit so a workspace is
    /// recognizable by shape. Drawn in a Canvas so it always fits its frame.
    @ViewBuilder private var thumb: some View {
        if let summary, summary.groupCount > 0 {
            let rows = MapKind.allCases.filter { (summary.kindCounts[$0] ?? 0) > 0 }
            Canvas { context, size in
                let inset = 10.0, gap = 5.0
                let bandHeight = min(26, (size.height - inset * 2 - gap * Double(rows.count - 1)) / Double(rows.count))
                let totalHeight = bandHeight * Double(rows.count) + gap * Double(rows.count - 1)
                var y = inset + max(0, (size.height - inset * 2 - totalHeight) / 2)
                for kind in rows {
                    let count = summary.kindCounts[kind] ?? 0
                    let band = CGRect(x: inset, y: y, width: size.width - inset * 2, height: bandHeight)
                    context.fill(Path(roundedRect: band, cornerRadius: 6), with: .color(Color.accentColor.opacity(0.06)))
                    let shown = min(count, 9)
                    let tileGap = 4.0, tileHeight = max(6, bandHeight - 10)
                    let available = band.width - 12 - (count > shown ? 28 : 0)
                    let tileWidth = min(22, (available - tileGap * Double(shown - 1)) / Double(shown))
                    var x = band.minX + 6
                    for _ in 0..<shown {
                        let tile = CGRect(x: x, y: band.midY - tileHeight / 2, width: tileWidth, height: tileHeight)
                        context.fill(Path(roundedRect: tile, cornerRadius: 3), with: .color(kind.libraryColor.opacity(0.9)))
                        x += tileWidth + tileGap
                    }
                    if count > shown {
                        context.draw(Text("+\(count - shown)").font(.system(size: 11)).foregroundColor(.secondary),
                                     at: CGPoint(x: x + 12, y: band.midY), anchor: .center)
                    }
                    y += bandHeight + gap
                }
            }
            .accessibilityHidden(true)
        } else {
            // Ruled lines hold the space until a summary exists, so cards never jump.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                        .frame(width: [120, 160, 90][index], height: 10)
                }
                if isLoading { LoadingIndicator(size: 14).padding(.top, 4) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
        }
    }
}

private extension MapKind {
    /// Mirrors the Map's kind colors (DESIGN.md §3).
    var libraryColor: Color {
        switch self {
        case .frontDoor: .teal
        case .appsAndAI: .orange
        case .code: .mint
        case .messaging: .pink
        case .data: .cyan
        case .network: .blue
        case .identityAndMonitoring, .other: .secondary
        }
    }
}

/// Checks a repository-backed cloud workspace out onto this Mac: asks where,
/// clones with git, remembers the link, and opens the folder.
@MainActor
final class WorkspaceCheckoutCoordinator: ObservableObject {
    struct Job: Equatable { let workspaceID: String; let title: String }
    @Published private(set) var job: Job?
    @Published private(set) var progressLine = ""
    @Published var errorMessage: String?
    let store = WorkspaceCheckoutStore()
    private var task: Task<Void, Never>?

    func checkOut(workspace: HCPWorkspace, organization: String, hostname: String, onOpen: @escaping (URL) -> Void) {
        guard job == nil, let vcs = workspace.vcs, let repository = vcs.cloneURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Check Out \(workspace.name)"
        panel.message = "Choose where to put the \(vcs.displayName) repository."
        panel.prompt = "Check Out Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Workspace", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let parent = panel.url, let self else { return }
            let folderName = GitCheckout.suggestedFolderName(identifier: vcs.identifier, repositoryURL: repository, workspaceName: workspace.name)
            let destination = parent.appendingPathComponent(folderName, isDirectory: true)
            self.start(workspace: workspace, organization: organization, hostname: hostname,
                       repository: repository, vcs: vcs, destination: destination, onOpen: onOpen)
        }
    }

    private func start(workspace: HCPWorkspace, organization: String, hostname: String, repository: URL,
                       vcs: HCPVCSRepository, destination: URL, onOpen: @escaping (URL) -> Void) {
        job = Job(workspaceID: workspace.id, title: workspace.name)
        progressLine = "Cloning \(vcs.displayName)…"
        errorMessage = nil
        let report: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.progressLine = line }
        }
        task = Task {
            do {
                let folder = try await GitCheckout.clone(repository: repository, branch: vcs.branch,
                    workingDirectory: vcs.workingDirectory, destination: destination, progress: report)
                guard !Task.isCancelled else { return }
                store.record(path: folder, hostname: hostname, organization: organization,
                             workspaceName: workspace.name, workspaceID: workspace.id)
                job = nil
                onOpen(folder)
            } catch {
                job = nil
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Check out failed."
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        job = nil
        progressLine = ""
    }
}
