import SwiftUI
import AppKit

enum SettingsPaneID: String, CaseIterable, Identifiable {
    case general, connections, agents, terraform, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .connections: "Connections"
        case .agents: "Agents"
        case .terraform: "Terraform"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connections: "network"
        case .agents: "cpu"
        case .terraform: "shippingbox"
        case .about: "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .connections: .blue
        case .agents: .green
        case .terraform: .accentColor
        case .about: .secondary
        }
    }
    var blurb: String {
        switch self {
        case .general: "Preferences that apply to every window."
        case .connections: "Sign in to HCP Terraform and your clouds."
        case .agents: "Let AI agents read this Mac’s open workspace."
        case .terraform: "Which Terraform runs your local previews."
        case .about: "Open source, on GitHub."
        }
    }
}

/// System Settings shape: a sidebar of sections and one pane.
struct SettingsWindow: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @ObservedObject var agentAccess: HabitableAgentAccess
    let onOpenWorkspaces: () -> Void
    let onOpenLocalWorkspace: () -> Void
    @AppStorage("settings.section") private var selectionRaw = SettingsPaneID.general.rawValue

    private var selection: SettingsPaneID { SettingsPaneID(rawValue: selectionRaw) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            pane
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)
            VStack(spacing: 2) {
                ForEach(SettingsPaneID.allCases) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var identity: some View {
        HStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40)
            } else {
                Image(systemName: "cloud").font(.system(size: 28)).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Habitable").font(.system(size: 15, weight: .semibold))
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("Version \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sidebarRow(_ section: SettingsPaneID) -> some View {
        let selected = section == selection
        return Button { selectionRaw = section.rawValue } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(selected ? Color.accentColor : section.tint,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(section.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Pane

    private var pane: some View {
        VStack(spacing: 0) {
            header.padding(.top, 24).padding(.bottom, 16).padding(.horizontal, 24)
            ScrollView {
                content
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: selection.symbol)
                .font(.system(size: 28)).foregroundStyle(selection.tint)
                .frame(width: 56, height: 56)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(selection.title).font(.system(size: 22, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(selection.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .general: GeneralPane(onOpenWorkspaces: onOpenWorkspaces, onOpenLocalWorkspace: onOpenLocalWorkspace)
        case .connections: ConnectionsPane(model: model, onOpenWorkspaces: onOpenWorkspaces)
        case .agents: AgentsSettingsPage(access: agentAccess)
        case .terraform: TerraformPane(onOpenLocalWorkspace: onOpenLocalWorkspace)
        case .about: AboutPane()
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    static let repository = URL(string: "https://github.com/thrashr888/Habitable")!
    static let releases = URL(string: "https://github.com/thrashr888/Habitable/releases")!
    static let issues = URL(string: "https://github.com/thrashr888/Habitable/issues")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Habitable") {
                SettingsRow("Version") { Text(version).foregroundStyle(.secondary).textSelection(.enabled) }
                SettingsRow("Updates") {
                    Text("Check the Releases page for now; in-app updates come later.").foregroundStyle(.secondary)
                }
                SettingsRow("Copyright") { Text("© 2026 Paul Thrasher").foregroundStyle(.secondary) }
            }
            SettingsGroup("Source") {
                SettingsRow("Repository") { Link("github.com/thrashr888/Habitable", destination: Self.repository) }
                SettingsRow("Releases") { Link("Releases", destination: Self.releases) }
                SettingsRow("Problems and ideas") { Link("Open an issue", destination: Self.issues) }
            }
            Text("Habitable never applies from your Mac. Runs happen in HCP Terraform; you confirm them here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(WorkspaceCheckoutStore.folderDefaultsKey) private var checkoutFolderPath = ""

    private func chooseCheckoutFolder() {
        let panel = NSOpenPanel()
        panel.title = "Checkout Folder"
        panel.message = "Choose where Habitable checks out repositories."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = WorkspaceCheckoutStore.ensureCheckoutFolder()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            checkoutFolderPath = url.path
        }
    }

    let onOpenWorkspaces: () -> Void
    let onOpenLocalWorkspace: () -> Void
    @AppStorage("general.restoreLastFolder") private var restoreLastFolder = true
    @AppStorage("map.showInventory") private var showInventory = true
    @AppStorage(Workspace.autoInitializeKey) private var autoInitialize = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("Windows", footer: "Applies to new local workspace windows.") {
                SettingsRow("Open last folder at launch") {
                    Toggle("Open last folder at launch", isOn: $restoreLastFolder).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Show inventory when a map opens") {
                    Toggle("Show inventory when a map opens", isOn: $showInventory).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Initialize folders automatically", subtitle: "Runs terraform init when a folder with configuration opens or before Preview Changes.") {
                    Toggle("Initialize folders automatically", isOn: $autoInitialize).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup("Checkouts", footer: "Repositories checked out from HCP Terraform workspaces go here, each in its own folder.") {
                SettingsRow("Check out into", subtitle: LibraryModel.abbreviatedPath(WorkspaceCheckoutStore.checkoutFolder.path)) {
                    HStack(spacing: 8) {
                        Button("Choose…") { chooseCheckoutFolder() }.buttonStyle(.bordered)
                            .accessibilityLabel("Choose the checkout folder")
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([WorkspaceCheckoutStore.ensureCheckoutFolder()])
                        }.buttonStyle(.borderless)
                    }
                }
            }
            SettingsGroup("Links") {
                SettingsRow("HCP Terraform window") {
                    Button("Open", action: onOpenWorkspaces).buttonStyle(.bordered)
                        .accessibilityLabel("Open HCP Terraform window")
                }
                SettingsRow("Local workspace window") {
                    Button("Open", action: onOpenLocalWorkspace).buttonStyle(.bordered)
                        .accessibilityLabel("Open local workspace window")
                }
            }
        }
    }
}

// MARK: - Terraform

private struct TerraformPane: View {
    let onOpenLocalWorkspace: () -> Void
    @StateObject private var catalog = TerraformReleaseCatalog()
    @State private var selectedVersion = UserDefaults.standard.string(forKey: TerraformReleaseService.selectionKey)

    private var executablePath: String {
        TerraformReleaseService.selectedExecutable(defaults: .standard)?.path ?? "Terraform on your PATH"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("Terraform", footer: "Versions are chosen per workspace window. Changes apply to the next command in each window.") {
                SettingsRow("Active version") {
                    Text(selectedVersion.map { "\($0) · Managed" } ?? "System")
                        .font(.system(size: 13)).monospacedDigit()
                }
                SettingsRow("Executable") {
                    Text(executablePath).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let latest = catalog.releases.first {
                    SettingsRow("Latest stable") {
                        Text(latest.version).font(.system(size: 13)).monospacedDigit()
                    }
                }
                SettingsRow("Version") {
                    Button("Change in Workspace settings…", action: onOpenLocalWorkspace).buttonStyle(.bordered)
                }
            }
        }
        .task {
            await catalog.refreshIfNeeded()
            selectedVersion = UserDefaults.standard.string(forKey: TerraformReleaseService.selectionKey)
        }
    }
}

// MARK: - Grouped form pieces (shared with ConnectionsPane)

struct SettingsGroup<Content: View, Accessory: View>: View {
    let title: String?
    let footer: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String? = nil, footer: String? = nil,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title {
                        Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.horizontal, 4)
            }
            // Rows draw a bottom hairline; the last one is pushed outside the clip.
            VStack(spacing: 0) { content }
                .padding(.bottom, -1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 40)
        .settingsRowDivider()
    }
}

extension View {
    /// Hairline under a grouped-form row (the group hides the last one).
    func settingsRowDivider() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
    }
}
