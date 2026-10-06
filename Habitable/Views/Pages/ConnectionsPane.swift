import SwiftUI
import AppKit

/// HCP Terraform / Terraform Enterprise and local cloud sign-in, as grouped
/// forms inside the Settings window. The cloud window only links here.
struct ConnectionsPane: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    var onOpenWorkspaces: () -> Void = {}
    @StateObject private var localConnections = LocalCloudConnectionsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("HCP Terraform & Terraform Enterprise", footer: "Browse remote workspace state and runs. Credentials are stored in Keychain.") {
                SettingsRow("Hostname") {
                    TextField("app.terraform.io", text: $model.hostname)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                        .accessibilityLabel("HCP Terraform hostname")
                }
                SettingsRow("Organization") { organizationPicker }
                SettingsRow(model.isConnected ? model.connectionSummary : "Not connected") { connectionActions }
                if model.isConnected {
                    SettingsRow("Remote workspaces") {
                        Button("Open Workspaces", action: onOpenWorkspaces).buttonStyle(.bordered)
                    }
                }
            }
            SettingsGroup("Local cloud access",
                          footer: "Authentication checks do not run a plan or change infrastructure. Provider settings in each workspace determine which profile, subscription, and project Terraform uses.",
                          accessory: {
                if localConnections.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh cloud connections") { Task { await localConnections.refresh() } }
                    .buttonStyle(.borderless)
                    .disabled(localConnections.isRefreshing || localConnections.connectingID != nil)
            }) {
                ForEach(localConnections.connections) { connection in
                    LocalCloudConnectionRow(connection: connection, isRefreshing: localConnections.isRefreshing,
                                            isConnecting: localConnections.connectingID == connection.id,
                                            canConnect: localConnections.canConnect(connection.id),
                                            loginMessage: localConnections.loginMessages[connection.id]) {
                        Task { await localConnections.connect(connection.id) }
                    }
                }
            }
        }
        .task { await localConnections.refresh() }
    }

    @ViewBuilder private var organizationPicker: some View {
        if model.organizations.isEmpty {
            TextField("Organization name", text: $model.selectedOrganization)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .accessibilityLabel("HCP Terraform organization")
        } else {
            Picker("Organization", selection: Binding(get: { model.selectedOrganization }, set: { organization in
                guard organization != model.selectedOrganization else { return }
                if model.isConnected {
                    // Keep the connection and the organization list; reload only workspaces.
                    Task { await model.switchOrganization(organization) }
                } else {
                    model.selectedOrganization = organization
                }
            })) {
                ForEach(model.organizations) { organization in Text(organization.name).tag(organization.name) }
            }
            .labelsHidden().lineLimit(1).frame(width: 240, alignment: .trailing).accessibilityLabel("HCP Terraform organization")
            .help(model.hostname)
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 12) {
            if model.isImporting {
                Label("Importing credential into Keychain…", systemImage: "key.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if model.isConnected {
                Button("Refresh") { Task { await model.refreshWorkspaces() } }
                    .disabled(model.isLoading)
                Button("Disconnect") { model.disconnect() }
            } else {
                Button("Import CLI credential") { Task { await model.importTerraformCredentialFile() } }
                    .help("Import the Terraform CLI credential into Keychain")
                    .disabled(model.isImporting || model.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "app.terraform.io")
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isLoading || !model.hasStoredCredential)
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct LocalCloudConnectionRow: View {
    let connection: LocalCloudConnection
    let isRefreshing: Bool
    let isConnecting: Bool
    let canConnect: Bool
    let loginMessage: String?
    let onConnect: () -> Void
    @State private var expanded = false
    @State private var copied = false

    private var statusWord: String { isRefreshing ? "Checking…" : connection.status }
    private var statusColor: Color { connection.isAuthenticated && !isRefreshing ? .green : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(connection.name).font(.system(size: 13))
                            if let secondary = secondaryLine {
                                Text(secondary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(connection.name) details")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusWord).font(.system(size: 13)).foregroundStyle(connection.isAuthenticated && !isRefreshing ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                if isConnecting { ProgressView().controlSize(.small) }
                Button(connection.isAuthenticated ? "Connected" : isConnecting ? "Connecting…" : "Connect", action: onConnect)
                    .buttonStyle(.bordered).disabled(!canConnect)
                    .accessibilityLabel("Connect \(connection.name)")
            }
            .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 40)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(connection.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Text(connection.loginCommand).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(copied ? "Copied" : "Copy sign-in command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(connection.loginCommand, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy \(connection.name) sign-in command")
                    }
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.leading, 30).padding(.trailing, 12).padding(.bottom, 12)
            }
        }
        .settingsRowDivider()
    }

    private var secondaryLine: String? {
        if let loginMessage { return loginMessage }
        if !connection.isAuthenticated && !isRefreshing { return "Opens Terminal and your browser to sign in." }
        return nil
    }
}
