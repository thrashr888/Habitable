import SwiftUI

struct HCPWorkspaceViewer: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    @State private var workspaceSearch = ""
    @State private var showingMap = true
    @State private var inspectorRequest: HCPMapInspectorRequest?

    init(model: HCPWorkspaceViewerModel) { self.model = model }

    private var filteredWorkspaces: [HCPWorkspace] {
        let query = workspaceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.workspaces }
        return model.workspaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionPanel
            if model.isConnected {
                Picker("Workspace view", selection: $showingMap) {
                    Text("Map").tag(true)
                    Text("Runs").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180).padding(.bottom, 8)
                if showingMap {
                    compactSelection
                    Divider()
                    cloudMap
                } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 960 {
                        HSplitView {
                            workspaceColumn.frame(minWidth: 210, idealWidth: 250, maxWidth: 330)
                            runColumn.frame(minWidth: 260, idealWidth: 320, maxWidth: 390)
                            runDetail.frame(minWidth: 360, maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            compactSelection
                            Divider()
                            runDetail
                        }
                    }
                }
                }
            } else {
                disconnectedState
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.mapRequestKey) { _ in inspectorRequest = nil }
        .sheet(item: $inspectorRequest) { request in
            HCPMapResourceSheet(resources: model.mapSnapshot?.resources ?? [],
                                title: model.selectedWorkspace?.name ?? "Workspace", selectedAddress: request.address)
        }
        .alert("HCP Terraform", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
    }

    // Only user selection starts a request. Model refreshes already load their
    // selected workspace/run and must not be duplicated when layouts remount.
    private var workspaceSelection: Binding<String?> {
        Binding(get: { model.selectedWorkspaceID }, set: { id in
            guard model.selectedWorkspaceID != id else { return }
            model.selectedWorkspaceID = id
            if id != nil { Task { await model.refreshRuns(force: true) } }
        })
    }

    private var runSelection: Binding<String?> {
        Binding(get: { model.selectedRunID }, set: { id in
            guard model.selectedRunID != id else { return }
            model.selectedRunID = id
            guard let id, let run = model.runs.first(where: { $0.id == id }) else { return }
            Task { await model.load(run: run) }
        })
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 160), alignment: .leading),
                                GridItem(.flexible(minimum: 160), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hostname").font(.caption).foregroundStyle(.secondary)
                    TextField("app.terraform.io", text: $model.hostname)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("HCP Terraform hostname")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization").font(.caption).foregroundStyle(.secondary)
                    if model.organizations.isEmpty {
                        TextField("Organization name", text: $model.selectedOrganization)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("HCP Terraform organization")
                    } else {
                        Picker("Organization", selection: $model.selectedOrganization) {
                            ForEach(model.organizations) { organization in Text(organization.name).tag(organization.name) }
                        }
                        .labelsHidden().lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("HCP Terraform organization")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.isConnected ? model.connectionSummary : "Credentials are stored in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
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
            if model.isImporting {
                Label("Importing credential into Keychain…", systemImage: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    /// Keep the selected workspace represented when search narrows the menu.
    /// Filtering must not silently change the workspace or selected run.
    private var compactWorkspaces: [HCPWorkspace] {
        var choices = filteredWorkspaces
        if let selected = model.selectedWorkspace, !choices.contains(where: { $0.id == selected.id }) {
            choices.insert(selected, at: 0)
        }
        return choices
    }

    private var compactSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Filter workspaces", text: $workspaceSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Filter HCP workspaces")
                Text("\(filteredWorkspaces.count) of \(model.workspaces.count) workspaces")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.workspaceHasNextPage {
                    Button("Load more") { Task { await model.loadNextWorkspacePage() } }
                        .disabled(model.isLoading)
                        .accessibilityLabel("Load more workspaces")
                }
            }
            HStack(spacing: 12) {
                Picker("Workspace", selection: workspaceSelection) {
                    Text("Choose a workspace").tag(nil as String?)
                    ForEach(compactWorkspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let workspace = model.selectedWorkspace {
                    if let version = workspace.terraformVersion {
                        Text("Terraform \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if workspace.locked { Image(systemName: "lock").help("Workspace locked").accessibilityLabel("Workspace locked") }
                    if let url = workspace.htmlURL {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Open workspace in HCP Terraform")
                            .accessibilityLabel("Open workspace in HCP Terraform")
                    }
                }
            }
            if !showingMap {
            HStack(spacing: 12) {
                Picker("Run", selection: runSelection) {
                    Text(model.runs.isEmpty ? "No remote runs loaded" : "Choose a run").tag(nil as String?)
                    if let id = model.selectedRunID, !model.runs.contains(where: { $0.id == id }) {
                        Text("Selected run · \(id)").tag(Optional(id))
                    }
                    ForEach(model.runs) { run in
                        Text("\(run.status.replacingOccurrences(of: "_", with: " ").capitalized) · \(run.message?.isEmpty == false ? run.message! : run.operation ?? run.id)")
                            .tag(Optional(run.id))
                    }
                }
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .disabled(model.selectedWorkspaceID == nil)
                if model.runHasNextPage {
                    Button("Load more") { Task { await model.loadNextRunPage() } }
                        .disabled(model.isLoading)
                        .accessibilityLabel("Load more remote runs")
                }
                Button { Task { await model.refreshRuns(force: false) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh run history").accessibilityLabel("Refresh remote run history")
                    .disabled(model.isLoading || model.selectedWorkspaceID == nil)
            }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var cloudMap: some View {
        if model.selectedWorkspace == nil {
            Text("Choose a workspace to view its resource map.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        ResourceMapContent(title: model.selectedWorkspace?.name ?? "Choose a workspace",
            identity: model.mapRequestKey + "|" + (model.mapSnapshot?.versionID ?? ""),
            map: model.mapSnapshot?.map, resources: model.mapSnapshot?.resources ?? [],
            notice: model.mapSnapshot?.notice ?? (model.mapSnapshot == nil ? nil : "HCP Terraform · current state · read-only"),
            errorMessage: model.mapError,
            isLoading: model.isLoadingMap, canRefresh: model.selectedWorkspace != nil && !model.isLoadingMap,
            refresh: { Task { await model.refreshMap() } },
            onShowList: { inspectorRequest = HCPMapInspectorRequest(address: nil) },
            onOpenResource: { address in inspectorRequest = HCPMapInspectorRequest(address: address) },
            emptyDetail: "This workspace has no managed resources in its current state. Data sources remain available in List; remote run history is available in Runs.")
        .task(id: model.mapRequestKey) { await model.refreshMap() }
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(model.hasStoredCredential ? "Connect to load your organization" : "Import a credential to get started")
                .font(.headline)
            Text("Habitable uses read-only HCP Terraform API requests. It does not queue or apply remote runs.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480) }
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workspaces").font(.headline)
                Spacer()
                Text("\(model.workspaces.count)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Filter workspaces", text: $workspaceSearch)
                .textFieldStyle(.roundedBorder)
            List(selection: workspaceSelection) {
                ForEach(filteredWorkspaces) { workspace in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.name).lineLimit(1)
                        HStack(spacing: 5) {
                            if let version = workspace.terraformVersion { Text("Terraform \(version)") }
                            if workspace.locked { Text("Locked") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(Optional(workspace.id))
                    .contextMenu {
                        if let url = workspace.htmlURL { Link("Open in HCP Terraform", destination: url) }
                    }
                }
            }
            .listStyle(.inset)
            if model.workspaceHasNextPage {
                Button("Load More Workspaces") { Task { await model.loadNextWorkspacePage() } }
                    .buttonStyle(.borderless).disabled(model.isLoading)
            }
        }
        .padding(.trailing, 8)
    }

    private var runColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote runs").font(.headline)
                Spacer()
                Button { Task { await model.refreshRuns(force: false) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh run history")
                    .disabled(model.isLoading || model.selectedWorkspaceID == nil)
            }
            if let workspace = model.selectedWorkspace {
                Text(workspace.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            List(selection: runSelection) {
                ForEach(model.runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(run.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline.weight(.medium))
                            Spacer()
                            if run.isDestroy { Image(systemName: "trash").foregroundStyle(.orange).help("Destroy run") }
                        }
                        Text(run.message?.isEmpty == false ? run.message! : run.operation ?? "Terraform run")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let date = run.createdAt {
                            Text(date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(run.id))
                }
            }
            .listStyle(.inset)
            if model.runHasNextPage {
                Button("Load More Runs") { Task { await model.loadNextRunPage() } }
                    .buttonStyle(.borderless).disabled(model.isLoading)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var runDetail: some View {
        if let details = model.selectedRunDetails {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details.run.message?.isEmpty == false ? details.run.message! : "Remote run")
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(details.run.id) · \(details.run.status)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = details.runURL { Link("Open in HCP Terraform", destination: url).font(.callout) }
                    }
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                              alignment: .leading, spacing: 12) {
                        phase(label: "Plan", status: details.planStatus ?? (details.run.planID == nil ? "Not available" : "Available"))
                        phase(label: "Apply", status: details.applyStatus ?? (details.run.applyID == nil ? "Not part of this run" : "Available"))
                        if let changes = details.run.hasChanges {
                            Label(changes ? "Changes" : "No changes", systemImage: changes ? "arrow.triangle.2.circlepath" : "checkmark")
                                .font(.callout)
                        }
                    }
                    if let plan = details.planReviewURL { Link("Review plan in HCP Terraform", destination: plan).font(.callout) }
                    if let logs = details.planLogs { logSection("Plan output", text: logs) }
                    if let logs = details.applyLogs { logSection("Apply output", text: logs) }
                    if details.planLogs == nil && details.applyLogs == nil {
                        Text("Run output is unavailable for this account or run phase. Open the run in HCP Terraform for the full event timeline.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Select a remote run").font(.headline)
                Text("Choose a run to review its phase status, output, and HCP Terraform links.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func phase(label: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline)
        }
    }

    private func logSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(12).background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct HCPMapInspectorRequest: Identifiable {
    let id = UUID()
    let address: String?
}

private struct HCPMapResourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let resources: [MapDisplayResource]
    let title: String
    @State private var selectedMapResource: String?

    init(resources: [MapDisplayResource], title: String, selectedAddress: String?) {
        self.resources = resources
        self.title = title
        _selectedMapResource = State(initialValue: selectedAddress)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(title) · Resources").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HSplitView {
                List(selection: $selectedMapResource) {
                    ForEach(resources, id: \.address) { resource in
                        Text(resource.address).font(.system(.callout, design: .monospaced)).tag(resource.address)
                    }
                }.frame(minWidth: 260, idealWidth: 340)
                ScrollView {
                    if let resource = resources.first(where: { $0.address == selectedMapResource }) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(resource.address).font(.headline).textSelection(.enabled)
                            Text(resource.type).foregroundStyle(.secondary)
                            if resource.displayAttributes.isEmpty {
                                Text("Attribute details are unavailable for this state version.").foregroundStyle(.secondary)
                            }
                            ForEach(resource.displayAttributes) { attribute in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(attribute.path).font(.caption).foregroundStyle(.secondary)
                                    Text(attribute.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else {
                        Text("Select a resource to inspect its details.").foregroundStyle(.secondary).padding(24)
                    }
                }.frame(minWidth: 300, maxWidth: .infinity)
            }
        }.frame(minWidth: 700, idealWidth: 850, minHeight: 500)
    }

}
