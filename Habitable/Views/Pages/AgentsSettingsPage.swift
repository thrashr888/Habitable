import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentsSettingsPage: View {
    @ObservedObject var access: HabitableAgentAccess
    @State private var clients = DetectedAgentClient.discover()
    @State private var errorMessage: String?
    @State private var showingConfigurationPicker = false
    @State private var skillInstallMessage: String?
    @State private var terraformInstallRunning = false
    @State private var codexEditing = false
    @State private var terraformInstallMessage: String?

    private var isOn: Binding<Bool> {
        Binding(get: { access.isEnabled || access.isStarting },
                set: { access.setEnabled($0) })
    }

    private var detectedClients: [DetectedAgentClient] { clients.filter(\.isDetected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            serverGroup
            clientsGroup
            toolsGroup
        }
        .fileImporter(isPresented: $showingConfigurationPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                let url = try result.get().first.unwrap()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try connect(configurationURL: url, sectionPath: ["mcpServers"])
            } catch { errorMessage = "Could not connect this configuration: \(error.localizedDescription)" }
        }
        .onAppear(perform: refreshClients)
    }

    // MARK: Groups

    private var serverGroup: some View {
        SettingsGroup("Server", footer: "Habitable shares read-only workspace metadata and diagnostics. Agents can request a plan-only run; they cannot apply or destroy infrastructure. Agents reach Habitable through MCP, the Model Context Protocol.") {
            SettingsRow("Let agents read this Mac’s open workspace",
                        subtitle: "Follows the window you used last.") {
                Toggle("Let agents read this Mac’s open workspace", isOn: isOn).labelsHidden().toggleStyle(.switch)
                    .disabled(access.isStarting)
            }
            SettingsRow("Exposes", subtitle: access.activeWorkspaceName == nil ? nil : "The local folder in your most recent window") {
                if let name = access.activeWorkspaceName {
                    Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else {
                    Text("Open a local workspace to expose it")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if access.isStarting {
                SettingsRow("Status") {
                    Label("Starting the local server…", systemImage: "hourglass")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else if let server = access.server, access.isEnabled {
                MCPServerStatusRows(server: server)
            } else if let message = access.message {
                SettingsRow("Status") {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                }
            } else {
                SettingsRow("Status") {
                    Label("Off", systemImage: "circle").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clientsGroup: some View {
        SettingsGroup("Clients", footer: errorMessage == nil ? "Detected agent apps on this Mac. Connecting adds Habitable to the app’s own configuration." : nil) {
            if detectedClients.isEmpty {
                SettingsRow("No supported agent found",
                            subtitle: "Choose a configuration file to connect another compatible client.") { EmptyView() }
            }
            ForEach(detectedClients) { client in
                clientRow(client)
            }
            SettingsRow("Another client") {
                Button("Choose configuration…") { showingConfigurationPicker = true }.buttonStyle(.bordered)
                    .accessibilityLabel("Choose another client configuration")
            }
            if let errorMessage {
                SettingsRow("Could not finish") {
                    Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }
    }

    private var toolsGroup: some View {
        SettingsGroup("Skills and tools", footer: "Each installation is separate from Habitable’s built-in server.") {
            SettingsRow("Habitable workflow skill", subtitle: skillInstallMessage) {
                Button("Install") { installHabitableSkill() }.buttonStyle(.bordered)
                    .accessibilityLabel("Install Habitable workflow skill")
            }
            SettingsRow("HashiCorp Terraform style guide") {
                Button("Install") { installTerraformSkill() }.buttonStyle(.bordered)
                    .accessibilityLabel("Install HashiCorp Terraform style guide")
            }
            SettingsRow("HashiCorp Terraform tools v1.3.0", subtitle: terraformInstallMessage) {
                HStack(spacing: 8) {
                    Button("Install") { installTerraformMCP() }.buttonStyle(.bordered)
                        .disabled(terraformInstallRunning)
                        .accessibilityLabel("Install HashiCorp Terraform MCP v1.3.0")
                    Button("Release notes") {
                        NSWorkspace.shared.open(HabitableStdioBridgeInstaller.terraformMCPReleaseURL)
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private func clientRow(_ client: DetectedAgentClient) -> some View {
        let bridgeCurrent = client.hasCurrentBridge(access.server?.bridgeIdentifier ?? "")
        let status = client.isConfigured ? (!access.isEnabled ? "Connected · Habitable server is off" : bridgeCurrent ? "Connected · not yet verified" : "Connected · reconnect required") : "Detected · not connected"
        SettingsRow(client.name, subtitle: status) {
            if client.isConfigured && (!access.isEnabled || bridgeCurrent) {
                Button("Disconnect") { disconnect(client) }.buttonStyle(.bordered)
                    .disabled(codexEditing && client.id == "codex")
                    .accessibilityLabel("Disconnect \(client.name)")
            } else {
                Button("Connect") { connect(client) }.buttonStyle(.bordered)
                    .disabled(!access.isEnabled || access.server?.endpointURL == nil || (codexEditing && client.id == "codex"))
                    .accessibilityLabel("Connect \(client.name)")
            }
        }
    }

    private func connect(_ client: DetectedAgentClient) {
        if client.id == "codex" {
            connectCodex()
            return
        }
        do { try connect(configurationURL: client.configURL, sectionPath: client.sectionPath) }
        catch { errorMessage = "Could not configure \(client.name): \(error.localizedDescription)" }
    }

    private func connect(configurationURL: URL, sectionPath: [String]) throws {
        guard let server = access.server, let endpoint = server.endpointURL else { throw HabitableStdioBridgeInstaller.InstallError.invalidEndpoint }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habitable/AgentBridge/\(server.bridgeIdentifier)", isDirectory: true)
        let script = try HabitableStdioBridgeInstaller.prepare(endpoint: endpoint, bearerToken: server.bearerToken, in: support)
        server.registerBridgeCredentialFile(support.appendingPathComponent("habitable-mcp-stdio.json"))
        try HabitableStdioBridgeInstaller.installInClientConfiguration(script: script, at: configurationURL, sectionPath: sectionPath)
        errorMessage = nil
        refreshClients()
    }

    private func connectCodex() {
        guard let server = access.server, let endpoint = server.endpointURL else { return }
        let token = server.bearerToken
        let bridgeID = server.bridgeIdentifier
        codexEditing = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () throws -> (URL?, URL) in
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Habitable/AgentBridge/\(bridgeID)", isDirectory: true)
            let script = try HabitableStdioBridgeInstaller.prepare(endpoint: endpoint, bearerToken: token, in: support)
                let backup = try CodexMCPConfigurationAdapter.install(script: script)
                return (backup, support.appendingPathComponent("habitable-mcp-stdio.json"))
            }.result
            switch result {
            case .success((_, let credentialsURL)):
                server.registerBridgeCredentialFile(credentialsURL)
                refreshClients()
                errorMessage = nil
            case .failure(let error): errorMessage = "Could not configure Codex: \(error.localizedDescription)"
            }
            codexEditing = false
        }
    }

    private func disconnect(_ client: DetectedAgentClient) {
        if client.id == "codex" {
            codexEditing = true
            Task {
                let result = await Task.detached(priority: .userInitiated) { try CodexMCPConfigurationAdapter.remove() }.result
                switch result {
                case .success: refreshClients(); errorMessage = nil
                case .failure(let error): errorMessage = "Could not disconnect Codex: \(error.localizedDescription)"
                }
                codexEditing = false
            }
            return
        }
        do {
            _ = try AgentJSONConfigurationEditor.remove(serverName: "habitable", at: client.configURL, sectionPath: client.sectionPath)
            refreshClients()
            errorMessage = nil
        } catch { errorMessage = "Could not disconnect \(client.name): \(error.localizedDescription)" }
    }

    private func installHabitableSkill() {
        do {
            let backup = try SkillInstaller.installHabitableSkill()
            skillInstallMessage = backup.map { "Installed. Previous version backed up at \($0.path)." } ?? "Installed Habitable workflow skill."
        } catch { skillInstallMessage = "Could not install the skill: \(error.localizedDescription)" }
    }

    private func installTerraformSkill() {
        Task {
            do {
                let backup = try await SkillInstaller.installOfficialTerraformStyleGuide()
                skillInstallMessage = backup.map { "Installed the pinned HashiCorp skill. Previous version backed up at \($0.path)." } ?? "Installed HashiCorp Terraform style guide v1.0.0."
            } catch { skillInstallMessage = "Could not install the pinned skill: \(error.localizedDescription)" }
        }
    }

    private func installTerraformMCP() {
        terraformInstallRunning = true
        Task {
            let result = await Task.detached(priority: .utility) { TerraformMCPInstaller.installPinnedRelease() }.value
            terraformInstallMessage = result ? "Installed HashiCorp Terraform MCP v1.3.0. It is not configured in an agent client." : "Install failed. Check that Go is installed and available on PATH."
            terraformInstallRunning = false
        }
    }

    private func refreshClients() { clients = DetectedAgentClient.discover() }
}

private struct MCPServerStatusRows: View {
    @ObservedObject var server: HabitableMCPServer

    var body: some View {
        SettingsRow("Status", subtitle: "Only this Mac can connect, with a private credential.") {
            Label("Running on this Mac", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(.green)
        }
        SettingsRow("Endpoint") {
            HStack(spacing: 8) {
                Text(server.endpointURL?.absoluteString ?? "Waiting for local address")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let endpoint = server.endpointURL {
                    Button("Copy endpoint") { NSPasteboard.general.setString(endpoint.absoluteString, forType: .string) }
                        .buttonStyle(.bordered)
                }
            }
        }
        if !server.recentActivity.isEmpty {
            SettingsRow("Recent activity", subtitle: server.recentActivity.prefix(5).joined(separator: "\n")) { EmptyView() }
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw CocoaError(.userCancelled) }
        return self
    }
}
