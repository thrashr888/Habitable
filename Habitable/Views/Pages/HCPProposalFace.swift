import AppKit
import SwiftUI

/// The "Proposal" face of the cloud inspector (Exploration G). A change to a
/// workspace starts from a folder on this Mac. For a repository-backed
/// workspace Habitable commits, pushes and opens the pull request; HCP
/// Terraform plans it and the plan lands on the Map. For an API-driven
/// workspace Habitable uploads the folder as a configuration version and
/// starts the run. Every apply happens in HCP Terraform and is confirmed here.
struct HCPProposalFace: View {
    @ObservedObject var model: HCPWorkspaceViewerModel
    /// Folders on this Mac that belong to the selected workspace (checkouts, or
    /// folders whose backend names it).
    let folders: [URL]
    let onCheckOut: (() -> Void)?
    let onChooseFolder: () -> Void
    /// Shows a run's plan on the Map.
    let onShowRun: (HCPRun) -> Void
    /// Opens the Settings face (for the Terraform version hint).
    var onOpenSettings: (() -> Void)? = nil

    @State private var message = ""
    @State private var gitStatus: GitProposal.Status?
    @State private var gitError: String?
    @State private var pullRequest: GitProposal.PullRequest?
    @State private var openPullRequests: [GitProposal.PullRequest] = []
    @State private var isWorking = false
    @State private var workingLabel = ""

    private var workspace: HCPWorkspace? { model.selectedWorkspace }
    private var isRepositoryBacked: Bool { workspace?.vcs != nil }
    private var folder: URL? { folders.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let proposal = model.proposal {
                    proposalCard(proposal)
                } else if folder == nil {
                    noFolder
                } else if isRepositoryBacked {
                    repositorySection
                } else {
                    apiSection
                }
                if let error = model.proposalError ?? gitError {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                recentRuns
                footnote
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: folder?.path) { await refreshGit() }
        .onChange(of: model.runs.count) { _ in Task { await refreshGit() } }
    }

    // MARK: Source folder

    private var noFolder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make a change").font(.headline)
            Text(isRepositoryBacked
                 ? "A change starts from a checkout of this workspace's repository on this Mac. Habitable commits, pushes and opens the pull request; HCP Terraform plans it."
                 : "A change starts from a folder on this Mac. Habitable uploads it to HCP Terraform and starts the run there.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isRepositoryBacked, let onCheckOut {
                    Button("Check Out…", action: onCheckOut).buttonStyle(.borderedProminent)
                }
                Button("Choose Folder…", action: onChooseFolder)
            }
        }
    }

    private func folderRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
            Text(abbreviated(url)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Open in Editor") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.system(size: 13))
        }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Repository-backed workspaces

    @ViewBuilder private var repositorySection: some View {
        if let folder {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pull request").font(.headline)
                folderRow(folder)
                if let pullRequest {
                    pullRequestCard(pullRequest, folder: folder)
                } else if let status = gitStatus {
                    if status.changedFiles.isEmpty {
                        Text("No edits yet. Edit the files in your editor; Habitable commits, pushes and opens the pull request.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        changedFiles(status.changedFiles)
                        TextField("What does this change do?", text: $message)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button(isWorking ? workingLabel : "Open Pull Request…") { Task { await openPullRequest(in: folder, base: status.defaultBranch) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(isWorking || message.trimmingCharacters(in: .whitespaces).isEmpty)
                            if isWorking { ProgressView().controlSize(.small) }
                        }
                        Text("Creates a branch, commits and pushes, then opens the pull request on \(status.githubRepository ?? "the repository"). HCP Terraform plans the pull request; the plan shows here on the Map.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if gitError == nil {
                    LoadingIndicator(size: 16, label: "Reading the checkout…")
                }
                if !openPullRequests.isEmpty {
                    otherProposals
                }
            }
        }
    }

    private func changedFiles(_ files: [GitProposal.ChangedFile]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files changed").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(files, id: \.path) { file in
                HStack(spacing: 8) {
                    Text(file.kind.rawValue.prefix(1).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 18, height: 18)
                        .background(kindColor(file.kind).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(kindColor(file.kind))
                    Text(file.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private func kindColor(_ kind: GitProposal.ChangedFile.Kind) -> Color {
        switch kind {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .modified, .renamed: return .orange
        }
    }

    private func pullRequestCard(_ pr: GitProposal.PullRequest, folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(pr.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                Text(pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            }
            Text("\(pr.headBranch) → \(pr.baseBranch)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                statusDot(pr.state == "OPEN" ? .green : .secondary, pr.state.capitalized)
                if let decision = pr.reviewDecision, !decision.isEmpty {
                    statusDot(decision == "APPROVED" ? .green : .orange, decision.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                if let add = pr.additions, let del = pr.deletions {
                    Text("+\(add) −\(del)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(pr.url) }
                Spacer()
                Button("Close Proposal") { Task { await closePullRequest(pr, in: folder) } }.disabled(isWorking)
                Button("Merge…") { Task { await merge(pr, in: folder) } }.buttonStyle(.borderedProminent).disabled(isWorking)
            }
            Text("Merging starts a run on \(pr.baseBranch) in HCP Terraform; confirm its apply here once its plan matches the preview.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var otherProposals: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other open pull requests").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(openPullRequests.filter { $0.number != pullRequest?.number }, id: \.number) { pr in
                Button { NSWorkspace.shared.open(pr.url) } label: {
                    HStack(spacing: 8) {
                        Text("#\(pr.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Text(pr.title).font(.system(size: 13)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: API-driven workspaces

    @ViewBuilder private var apiSection: some View {
        if let folder {
            VStack(alignment: .leading, spacing: 12) {
                Text("New run").font(.headline)
                folderRow(folder)
                TextField("What does this change do?", text: $message)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(model.isProposing ? "Uploading…" : "Start Run in HCP Terraform") {
                        let text = message.trimmingCharacters(in: .whitespaces)
                        Task { await model.propose(folder: folder, message: text.isEmpty ? "Change from Habitable" : text) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isProposing)
                    if model.isProposing { ProgressView().controlSize(.small) }
                }
                Text("Uploads this folder's configuration to HCP Terraform and starts a run there. The plan shows here on the Map; nothing changes until you confirm the apply.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func proposalCard(_ proposal: HCPProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.message).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text("Run in HCP Terraform · \(proposal.folder.lastPathComponent)").font(.system(size: 13)).foregroundStyle(.secondary)
            steps(for: proposal.step)
            if case .errored(let detail) = proposal.step {
                Text(detail).font(.system(size: 13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if let log = model.proposalLog {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Run log").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            MapCopyButton(value: log, label: "run log")
                        }
                        Text(log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    if let hint = terraformVersionHint(log: log) {
                        Text(hint).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let onOpenSettings {
                            Button("Change Terraform Version…", action: onOpenSettings).controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                if let run = model.runs.first(where: { $0.id == proposal.runID }), let url = run.htmlURL {
                    Button("Open in HCP Terraform") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                switch proposal.step {
                case .needsConfirmation:
                    Button("Discard") { Task { await model.discardProposal() } }
                    Button("Confirm Apply") { Task { await model.confirmProposalApply() } }.buttonStyle(.borderedProminent)
                case .applied, .errored, .discarded:
                    Button("Done") { model.dismissProposal() }
                default:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func steps(for step: HCPProposal.Step) -> some View {
        let order: [(String, Int)] = [("Uploaded", 0), ("Planned", 1), ("Confirmed", 2), ("Applied", 3)]
        let reached: Int = {
            switch step {
            case .uploading: return -1
            case .planning: return 0
            case .needsConfirmation: return 1
            case .applying: return 2
            case .applied: return 3
            case .errored, .discarded: return 0
            }
        }()
        // Labels never wrap; the row scrolls sideways if the pane is narrow.
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(order, id: \.1) { label, index in
                    HStack(spacing: 4) {
                        Circle().fill(index <= reached ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                        Text(label).font(.system(size: 12)).foregroundStyle(index <= reached ? .primary : .secondary)
                            .fixedSize()
                    }
                    if index < order.count - 1 { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 12, height: 1) }
                }
                if case .planning = step { ProgressView().controlSize(.mini) }
                if case .applying = step { ProgressView().controlSize(.mini) }
            }
        }
    }

    // MARK: Runs

    /// The latest remote runs, each with a way to put its plan on the Map; a
    /// planned run waiting for confirmation can be applied or discarded here.
    @ViewBuilder private var recentRuns: some View {
        let runs = model.runs.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(4)
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest runs").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                ForEach(Array(runs)) { run in
                    HStack(spacing: 8) {
                        statusDot(runColor(run.status), statusWord(run.status))
                        Text(run.message?.isEmpty == false ? run.message! : "Run").font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        if run.planID != nil || run.status != "pending" {
                            Button(model.previewedRunID == run.id ? "On the Map" : "Show on Map") { onShowRun(run) }
                                .buttonStyle(.link).font(.system(size: 13))
                                .disabled(model.previewedRunID == run.id)
                        }
                        if ["planned", "cost_estimated", "policy_checked"].contains(run.status) {
                            Button("Discard") { Task { await model.discard(run: run) } }
                            Button("Confirm Apply") { Task { await model.confirmApply(run: run) } }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func statusWord(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func runColor(_ status: String) -> Color {
        if status == "applied" { return .green }
        if status.contains("error") || status.contains("cancel") { return .red }
        if ["planned", "cost_estimated", "policy_checked"].contains(status) { return .accentColor }
        if ["pending", "plan_queued", "planning", "applying", "apply_queued", "confirmed"].contains(status) { return .orange }
        return .secondary
    }

    private func statusDot(_ color: Color, _ word: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(word).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    /// A `cloud` block needs Terraform 1.1 or later; older workspaces reject it at init.
    private func terraformVersionHint(log: String) -> String? {
        guard log.contains("Blocks of type \"cloud\" are not expected") || log.contains("Unsupported block type"),
              let version = workspace?.terraformVersion else { return nil }
        return "This workspace runs Terraform \(version). The folder's cloud block needs 1.1 or later; change the workspace's Terraform version in Settings, or use a remote backend block instead."
    }

    private var footnote: some View {
        Text("Habitable never applies from your Mac. Runs happen in HCP Terraform; you confirm them here.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Git actions (off the main actor)

    private func refreshGit() async {
        guard isRepositoryBacked, let folder else { gitStatus = nil; pullRequest = nil; openPullRequests = []; return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(GitProposal.Status, GitProposal.PullRequest?, [GitProposal.PullRequest]), Error> in
            do {
                let status = try GitProposal.status(in: folder)
                let pr = status.branch.hasPrefix("habitable/") ? try? GitProposal.pullRequest(in: folder, forBranch: status.branch) : nil
                let open = (try? GitProposal.openPullRequests(in: folder)) ?? []
                return .success((status, pr, open))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (status, pr, open)):
            gitStatus = status; pullRequest = pr; openPullRequests = open; gitError = nil
        case .failure(let error):
            gitStatus = nil; gitError = error.localizedDescription
        }
    }

    private func openPullRequest(in folder: URL, base: String) async {
        let title = message.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        isWorking = true; workingLabel = "Committing and pushing…"; gitError = nil
        let body = "Opened from Habitable. HCP Terraform plans this pull request; the plan is reviewed on the Map before merge."
        let result = await Task.detached(priority: .userInitiated) { () -> Result<GitProposal.PullRequest, Error> in
            do {
                _ = try GitProposal.commitAndPush(in: folder, message: title)
                return .success(try GitProposal.openPullRequest(in: folder, title: title, body: body, base: base))
            } catch { return .failure(error) }
        }.value
        isWorking = false
        switch result {
        case .success(let pr): pullRequest = pr; message = ""; await model.refreshRuns(force: true); await refreshGit()
        case .failure(let error): gitError = error.localizedDescription
        }
    }

    private func merge(_ pr: GitProposal.PullRequest, in folder: URL) async {
        isWorking = true; workingLabel = "Merging…"; gitError = nil
        let result = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try GitProposal.merge(pullRequest: pr.number, in: folder); return nil } catch { return error }
        }.value
        isWorking = false
        if let result { gitError = result.localizedDescription } else { pullRequest = nil; await model.refreshRuns(force: true); await refreshGit() }
    }

    private func closePullRequest(_ pr: GitProposal.PullRequest, in folder: URL) async {
        isWorking = true; workingLabel = "Closing…"; gitError = nil
        let result = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try GitProposal.closePullRequest(pr.number, in: folder); return nil } catch { return error }
        }.value
        isWorking = false
        if let result { gitError = result.localizedDescription } else { pullRequest = nil; await refreshGit() }
    }
}
