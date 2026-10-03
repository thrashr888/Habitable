import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentsSettingsPage: View {
    @ObservedObject var access: HabitableAgentAccess
    @ObservedObject var workspace: Workspace
    @State private var clients = DetectedAgentClient.discover()
    @State private var errorMessage: String?
    @State private var showingConfigurationPicker = false
    @State private var skillInstallMessage: String?
    @State private var terraformInstallRunning = false
    @State private var codexEditing = false
    @State private var terraformInstallMessage: String?

    private var isOn: Binding<Bool> {
        Binding(get: { access.isEnabled || access.isStarting },
                set: { access.setEnabled($0, in: workspace) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                Text("Agent connections").font(.headline)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Allow agents to access the selected workspace", isOn: isOn)
                            .disabled(workspace.workingDirectory == nil || access.isStarting)
                        Text("Habitable shares read-only workspace metadata and diagnostics. Agents can request a plan-only run; they cannot apply or destroy infrastructure.")
                            .font(.callout).foregroundStyle(.secondary)
                        if access.isStarting {
                            Label("Starting the local server…", systemImage: "hourglass")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if let server = access.server, access.isEnabled {
                            MCPServerStatusView(server: server)
                        } else if let message = access.message {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        } else {
                            Label("Off", systemImage: "circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Habitable MCP") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if clients.filter(\.isDetected).isEmpty {
                            Text("No supported agent configuration was found. Choose a configuration file to connect another compatible client.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(clients.filter(\.isDetected)) { client in
                            clientRow(client)
                            if client.id != clients.filter(\.isDetected).last?.id { Divider() }
                        }
                        Button("Choose another client configuration…") { showingConfigurationPicker = true }
                            .padding(.top, 4)
                        if let errorMessage {
                            Text(errorMessage).font(.callout).foregroundStyle(.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Detected clients") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Install Habitable’s workflow guide or optional HashiCorp tools. Each installation is separate from Habitable’s built-in server.")
                            .font(.callout).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Install Habitable workflow skill") { installHabitableSkill() }
                            Button("Install HashiCorp Terraform style guide") { installTerraformSkill() }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Install HashiCorp Terraform MCP v1.3.0") { installTerraformMCP() }
                                .disabled(terraformInstallRunning)
                            Button("Release notes") {
                                NSWorkspace.shared.open(HabitableStdioBridgeInstaller.terraformMCPReleaseURL)
                            }
                        }
                        if let skillInstallMessage { Text(skillInstallMessage).font(.caption).foregroundStyle(.secondary) }
                        if let terraformInstallMessage { Text(terraformInstallMessage).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Optional tools and skills") }
        }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        .fileImporter(isPresented: $showingConfigurationPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                let url = try result.get().first.unwrap()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try connect(configurationURL: url, sectionPath: ["mcpServers"])
            } catch { errorMessage = "Could not connect this configuration: \(error.localizedDescription)" }
        }
        .onAppear(perform: refreshClients)
        .onChange(of: workspace.workingDirectory) { _ in access.workspaceChanged(in: workspace) }
    }

    @ViewBuilder private func clientRow(_ client: DetectedAgentClient) -> some View {
        HStack(spacing: 12) {
            Image(systemName: client.isConfigured ? "checkmark.circle.fill" : "app.badge")
                .foregroundStyle(client.isConfigured ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.name)
                let bridgeCurrent = client.hasCurrentBridge(access.server?.bridgeIdentifier ?? "")
                Text(client.isConfigured ? (!access.isEnabled ? "Configured · Habitable server is off" : bridgeCurrent ? "Configured · live connection not verified" : "Configured · reconnect required") : "Detected · not configured")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if client.isConfigured && (!access.isEnabled || client.hasCurrentBridge(access.server?.bridgeIdentifier ?? "")) {
                Button("Disconnect") { disconnect(client) }.disabled(codexEditing && client.id == "codex")
            } else {
                Button("Connect") { connect(client) }
                    .disabled(!access.isEnabled || access.server?.endpointURL == nil || (codexEditing && client.id == "codex"))
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

private struct MCPServerStatusView: View {
    @ObservedObject var server: HabitableMCPServer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Running on this Mac", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            HStack {
                Text(server.endpointURL?.absoluteString ?? "Waiting for local address")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if let endpoint = server.endpointURL {
                    Button("Copy endpoint") { NSPasteboard.general.setString(endpoint.absoluteString, forType: .string) }
                }
            }
            Text("The server is loopback-only and uses a private local credential. Client configuration contains only the bridge path.")
                .font(.caption).foregroundStyle(.secondary)
            if !server.recentActivity.isEmpty {
                Divider()
                Text("Recent activity").font(.headline)
                ForEach(Array(server.recentActivity.prefix(5).enumerated()), id: \.offset) { _, item in
                    Text(item).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw CocoaError(.userCancelled) }
        return self
    }
}
