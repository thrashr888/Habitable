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
                } else if let merge = model.recentMerge {
                    mergeCard(merge)
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
        // After a merge, follow the run HCP starts until it settles.
        .task(id: model.recentMerge?.number) {
            guard model.recentMerge != nil else { return }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let merge = model.recentMerge else { return }
                if let run = model.run(for: merge), !run.isActive { return }
                await model.refreshRuns(force: true)
            }
        }
        // While a pull request is open, its checks and review state change on GitHub's side.
        .task(id: pullRequest?.number) {
            guard pullRequest != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshGit()
            }
        }
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
                if pullRequest == nil { folderRow(folder) }
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
                if openPullRequests.contains(where: { $0.number != pullRequest?.number }) {
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

    /// Exploration G: the pull request as a short timeline, opened → plan → checks
    /// → review → merge → apply, with the actions at the end.
    private func pullRequestCard(_ pr: GitProposal.PullRequest, folder: URL) -> some View {
        let planCheck = pr.checks.first { isThisWorkspace($0) && GitProposal.PullRequest.runID(in: $0) != nil }
        let planRunID = planCheck.flatMap { GitProposal.PullRequest.runID(in: $0) }
        let specRun = specultativeRun(for: pr)
        let passed = pr.checks.filter { $0.state == .success }.count
        let failed = pr.checks.filter { $0.state == .failure }.count
        let pending = pr.checks.filter { $0.state == .pending }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(pr.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                Text(pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !pr.files.isEmpty {
                    timelineRow(done: true, color: .green, title: "Edited",
                                detail: "\(pr.files.count) \(pr.files.count == 1 ? "file" : "files") on \(pr.headBranch)", trailing: nil)
                }
                timelineRow(done: true, color: .green, title: "Pull request opened",
                            detail: "\(pr.headBranch) → \(pr.baseBranch)" + ((pr.additions != nil && pr.deletions != nil) ? " · +\(pr.additions!) −\(pr.deletions!)" : ""),
                            trailing: AnyView(Button("GitHub") { NSWorkspace.shared.open(pr.url) }.buttonStyle(.link).font(.system(size: 13))))
                if !pr.files.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Files changed").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(pr.files.prefix(6), id: \.path) { file in
                            HStack(spacing: 8) {
                                Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("+\(file.additions) −\(file.deletions)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        if pr.files.count > 6 {
                            Text("and \(pr.files.count - 6) more").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 19).padding(.bottom, 10)
                }
                // The run HCP actually recorded outranks GitHub's status context for it.
                timelineRow(done: specRun.map { $0.status == "planned_and_finished" } ?? (planCheck?.state == .success),
                            color: specRun.map { run in run.status == "errored" ? Color.red : (run.status == "planned_and_finished" ? .green : .orange) }
                                ?? (planCheck?.state == .failure ? .red : (planCheck?.state == .success ? .green : .orange)),
                            title: "Plan in HCP Terraform",
                            detail: specRun.map { run in "\(statusWord(run.status))" + (run.createdAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "") }
                                ?? (planCheck == nil ? "Waiting for HCP Terraform to pick up the pull request" : "Running"),
                            trailing: (specRun ?? planRunID.map { id in placeholderRun(id: id, title: pr.title) }).map { run in
                                AnyView(Button(model.previewedRunID == run.id ? "On the Map" : "Show on Map") { onShowRun(run) }
                                    .buttonStyle(.link).font(.system(size: 13)).disabled(model.previewedRunID == run.id))
                            })
                if !pr.checks.isEmpty {
                    timelineRow(done: failed == 0 && pending == 0, color: failed > 0 ? .red : (pending > 0 ? .orange : .green),
                                title: "Checks",
                                detail: [passed > 0 ? "\(passed) passed" : nil, failed > 0 ? "\(failed) failed" : nil, pending > 0 ? "\(pending) running" : nil]
                                    .compactMap { $0 }.joined(separator: " · "),
                                trailing: AnyView(Button(showChecks ? "Hide" : "Details") { withAnimation { showChecks.toggle() } }.buttonStyle(.link).font(.system(size: 13))))
                    if showChecks { checksList(pr.checks).padding(.leading, 19).padding(.bottom, 8) }
                }
                timelineRow(done: pr.reviewDecision == "APPROVED",
                            color: pr.reviewDecision == "APPROVED" ? .green : (pr.reviewDecision == "CHANGES_REQUESTED" ? .red : .secondary),
                            title: pr.reviewDecision == "APPROVED" ? "Approved" : (pr.reviewDecision == "CHANGES_REQUESTED" ? "Changes requested" : "Review"),
                            detail: pr.approvedBy.map { review in
                                review.author + (review.submittedAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "")
                            } ?? (pr.reviewDecision == "CHANGES_REQUESTED" ? "A reviewer asked for changes" : "No review yet"),
                            trailing: nil)
                timelineRow(done: false, color: .secondary, title: "Merge",
                            detail: "Starts a run on \(pr.baseBranch) in HCP Terraform", trailing: nil)
                timelineRow(done: false, color: .secondary, title: "Confirm apply",
                            detail: "Here, once that run's plan matches this preview", trailing: nil, last: true)
            }
            if let preview = model.proposalPreview, model.previewedRunID == (specRun?.id ?? planRunID) {
                changesList(preview)
            }
            HStack {
                Button("Close Proposal") { Task { await closePullRequest(pr, in: folder) } }.disabled(isWorking)
                Spacer()
                Button("Merge…") { Task { await merge(pr, in: folder) } }.buttonStyle(.borderedProminent).disabled(isWorking)
            }
            let conversation = pr.reviews.filter { !$0.body.isEmpty } .map { ($0.author, $0.state == "APPROVED" ? "approved" : ($0.state == "CHANGES_REQUESTED" ? "requested changes" : "commented"), $0.body, $0.submittedAt) }
                + pr.comments.map { ($0.author, "commented", $0.body, $0.createdAt) }
            if !conversation.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Conversation").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(Array(conversation.suffix(3).enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(entry.0).font(.system(size: 13, weight: .semibold))
                                Text(entry.1).font(.system(size: 13)).foregroundStyle(.secondary)
                                if let when = entry.3 { Text("· " + when.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                            Text(entry.2).font(.system(size: 13)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    /// "3 changes": the tiles the previewed plan touches, each with its action word.
    private func changesList(_ preview: MapChangePreview) -> some View {
        let changed = preview.map.tiles.filter { (preview.tileActions[$0.id] ?? .none) != .none }
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(changed.count) \(changed.count == 1 ? "change" : "changes")").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(changed, id: \.id) { tile in
                let action = preview.tileActions[tile.id] ?? .none
                HStack(spacing: 8) {
                    Text(tile.title).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Text(actionWord(action)).font(.system(size: 12, weight: .medium)).foregroundStyle(actionTint(action))
                }
            }
        }
    }

    private func actionWord(_ action: MapChangeAction) -> String {
        switch action {
        case .create: return "new"
        case .update: return "update"
        case .replace: return "replace"
        case .delete: return "remove"
        case .read: return "read"
        case .none: return ""
        }
    }

    private func actionTint(_ action: MapChangeAction) -> Color {
        switch action {
        case .create: return .green
        case .update: return .orange
        case .replace: return Color(red: 0.93, green: 0.33, blue: 0.62)
        case .delete: return .red
        default: return .secondary
        }
    }

    @State private var showChecks = false

    /// Exploration G, after Merge: the run on the base branch, and its apply.
    private func mergeCard(_ merge: HCPMergedPullRequest) -> some View {
        let run = model.run(for: merge)
        let status = run?.status ?? ""
        let waiting = ["planned", "cost_estimated", "policy_checked"].contains(status)
        let applied = status == "applied"
        let failed = ["errored", "canceled", "force_canceled", "discarded"].contains(status)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(merge.number)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                Text(merge.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 0) {
                timelineRow(done: true, color: .green, title: "Merged",
                            detail: "Into \(merge.baseBranch) · " + merge.mergedAt.formatted(.relative(presentation: .named)), trailing: nil)
                timelineRow(done: run != nil && (applied || waiting || status == "confirmed" || status == "applying" || status == "apply_queued"),
                            color: run == nil ? .orange : (failed ? .red : (applied || waiting ? .green : .orange)),
                            title: "Run on \(merge.baseBranch)",
                            detail: run.map { statusWord($0.status) + ($0.createdAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "") }
                                ?? "Waiting for HCP Terraform to start it",
                            trailing: run.map { run in
                                AnyView(Button(model.previewedRunID == run.id ? "On the Map" : "Show on Map") { onShowRun(run) }
                                    .buttonStyle(.link).font(.system(size: 13)).disabled(model.previewedRunID == run.id || run.planID == nil && run.status == "pending"))
                            })
                timelineRow(done: applied, color: applied ? .green : (waiting ? .accentColor : (failed ? .red : .secondary)),
                            title: applied ? "Applied" : "Confirm apply",
                            detail: applied ? "The workspace's state now includes this change."
                                : (waiting ? "The plan is ready. Confirm here to apply it in HCP Terraform."
                                   : (failed ? "The run did not apply. Open it in HCP Terraform for the log." : "After the plan finishes")),
                            trailing: nil, last: true)
            }
            HStack {
                if let url = run?.htmlURL { Button("Open in HCP Terraform") { NSWorkspace.shared.open(url) } }
                Spacer()
                if waiting, let run {
                    Button("Discard") { Task { await model.discard(run: run) } }
                    confirmApplyButton(runID: run.id) { Task { await model.confirmApply(run: run) } }
                } else if applied || failed || run == nil {
                    Button("Done") { model.clearMerge() }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One step: a dot on a rail, a title, a quiet detail line, an optional action.
    private func timelineRow(done: Bool, color: Color, title: String, detail: String, trailing: AnyView?, last: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(done || color != .secondary ? color : Color.secondary.opacity(0.35)).frame(width: 9, height: 9).padding(.top, 4)
                if !last { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(done || color != .secondary ? .primary : .secondary)
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            .padding(.bottom, last ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func checksList(_ checks: [GitProposal.Check]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(checks, id: \.name) { check in
                HStack(spacing: 8) {
                    Circle().fill(checkColor(check.state)).frame(width: 7, height: 7)
                    Text(shortCheckName(check.name)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let url = check.url {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
        }
    }

    /// "Terraform Cloud/org/ws" reads as "org/ws"; "sentinel/org/ws" keeps its prefix.
    private func shortCheckName(_ name: String) -> String {
        name.hasPrefix("Terraform Cloud/") ? String(name.dropFirst("Terraform Cloud/".count)) : name
    }

    /// HCP's speculative run for the pull request: the newest plan-only run whose
    /// message is the pull request's title or commit.
    private func specultativeRun(for pr: GitProposal.PullRequest) -> HCPRun? {
        model.runs.filter { run in
            ["planned_and_finished", "planning", "plan_queued", "pending", "errored"].contains(run.status)
                && (run.message ?? "").localizedCaseInsensitiveContains(pr.title)
        }
        .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    private func placeholderRun(id: String, title: String) -> HCPRun {
        HCPRun(id: id, workspaceID: workspace?.id ?? "", workspaceName: workspace?.name ?? "", status: "planned_and_finished",
               message: title, operation: "plan", createdAt: nil, hasChanges: nil, isDestroy: false, planID: nil, applyID: nil, htmlURL: nil)
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
                    confirmApplyButton(runID: proposal.runID) { Task { await model.confirmProposalApply() } }
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
    /// Runs waiting for a confirmation here. The Changes strip is the full list.
    @ViewBuilder private var recentRuns: some View {
        let waiting = model.runs.filter { ["planned", "cost_estimated", "policy_checked"].contains($0.status) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Waiting for confirmation").font(.headline)
                ForEach(waiting) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.message?.isEmpty == false ? run.message! : "Run").font(.system(size: 13, weight: .medium)).lineLimit(1)
                        HStack(spacing: 8) {
                            statusDot(.accentColor, statusWord(run.status))
                            Spacer()
                            Button(model.previewedRunID == run.id ? "On the Map" : "Show on Map") { onShowRun(run) }
                                .buttonStyle(.link).font(.system(size: 13)).disabled(model.previewedRunID == run.id)
                            Button("Discard") { Task { await model.discard(run: run) } }.controlSize(.small)
                            confirmApplyButton(runID: run.id) { Task { await model.confirmApply(run: run) } }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// HCP's check for this very workspace is named "Terraform Cloud/<org>/<workspace>".
    private func isThisWorkspace(_ check: GitProposal.Check) -> Bool {
        guard let workspace else { return false }
        return check.name.hasSuffix("/\(model.selectedOrganization)/\(workspace.name)")
    }

    private func checkColor(_ state: GitProposal.Check.State) -> Color {
        switch state {
        case .success: return .green
        case .failure: return .red
        case .pending: return .orange
        case .neutral: return .secondary
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

    /// Confirm Apply holds when the previewed plan for this run replaces or removes
    /// anything (Exploration C); additive plans apply on a click.
    @ViewBuilder private func confirmApplyButton(runID: String, action: @escaping () -> Void) -> some View {
        if model.previewedRunID == runID, let c = model.proposalPreview?.consequences, c.replace + c.destroy > 0 {
            HoldToConfirmButton(title: "Confirm Apply", action: action)
        } else {
            Button("Confirm Apply", action: action).buttonStyle(.borderedProminent)
        }
    }

    private var footnote: some View {
        Text("Habitable never applies from your Mac. Runs happen in HCP Terraform; you confirm them here.")
            .quickHelp(glossary: "speculative-plan")
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
            model.openPullRequest = pr
            if let pr {
                model.pullRequestActions = PullRequestActions(
                    merge: { Task { await merge(pr, in: folder) } },
                    close: { Task { await closePullRequest(pr, in: folder) } })
            } else {
                model.pullRequestActions = nil
            }
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
        if let result { gitError = result.localizedDescription; return }
        pullRequest = nil
        guard let workspace else { return }
        model.noteMerge(HCPMergedPullRequest(number: pr.number, title: pr.title, baseBranch: pr.baseBranch, mergedAt: Date(), workspaceID: workspace.id))
        // Back to the base branch at its new tip, so the next change starts from main.
        let returned = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try GitProposal.returnToBase(in: folder, base: pr.baseBranch); return nil } catch { return error }
        }.value
        if let returned { gitError = returned.localizedDescription }
        await model.refreshRuns(force: true)
        await refreshGit()
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
