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
        .task(id: recentFolders.map(\.path)) { await library.refreshLocal(folders: recentFolders) }
        .task { if !cloud.isConnected && !cloud.isLoading && cloud.hasStoredCredential { await cloud.connect() } }
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
                               count: organization.name == cloud.selectedOrganization ? cloudEntries.count : nil,
                               tag: .cloud(organization.name))
                }
            } else {
                Button(action: onOpenConnections) {
                    Label(cloud.isLoading ? "Connecting…" : "Connect…", systemImage: "cloud")
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

    private func sidebarRow(_ title: String, symbol: String, count: Int?, tag: Section) -> some View {
        let selected = section == tag
        return Button {
            section = tag
            if case .cloud(let organization) = tag, organization != cloud.selectedOrganization {
                cloud.selectedOrganization = organization
                Task { await cloud.connect() }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text(count, format: .number).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary) }
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
                        emptyState
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
                                failure: library.failures[entry.id]) { open(entry) }
                        .task(id: entry.id) { await library.loadSummary(for: entry, cloud: cloud) }
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
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                thumb
                    .frame(height: 118)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(hovering ? 0.2 : 0.1)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.isCloud ? "cloud" : "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(entry.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    }
                    Text(entry.location).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(detailLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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

    /// Rows per populated kind, tiles as small rounded blocks colored by kind:
    /// a miniature of the real Map, so a workspace is recognizable by shape.
    @ViewBuilder private var thumb: some View {
        if let summary, summary.groupCount > 0 {
            let rows = MapKind.allCases.filter { (summary.kindCounts[$0] ?? 0) > 0 }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.rawValue) { kind in
                    HStack(spacing: 4) {
                        ForEach(0..<min(summary.kindCounts[kind] ?? 0, 8), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3).fill(kind.libraryColor.opacity(0.85))
                                .frame(width: 18, height: 10)
                        }
                        if (summary.kindCounts[kind] ?? 0) > 8 {
                            Text("+\((summary.kindCounts[kind] ?? 0) - 8)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
        } else {
            // Ruled lines hold the space until a summary exists, so cards never jump.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                        .frame(width: [120, 160, 90][index], height: 10)
                }
                if isLoading { ProgressView().controlSize(.small).padding(.top, 4) }
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
