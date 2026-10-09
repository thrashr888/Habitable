import Foundation

/// One Quick Help card: a title, a sentence or two, and an optional docs link.
struct QuickHelpEntry: Equatable, Sendable {
    let title: String
    let text: String
    var learnMoreURL: URL? = nil
    var learnMoreTitle: String = "Learn more in Terraform docs"
}

/// Glossary of Terraform and Habitable words, keyed by a stable id.
enum QuickHelpGlossary {
    static func entry(_ id: String) -> QuickHelpEntry? { all[id] }

    private static func docs(_ path: String) -> URL? {
        URL(string: "https://developer.hashicorp.com/terraform/" + path)
    }

    static let all: [String: QuickHelpEntry] = [
        "output": QuickHelpEntry(
            title: "Output",
            text: "An output is a value Terraform hands back after applying, like a website address or a database hostname. Habitable shows outputs as Endpoints you can copy or open.",
            learnMoreURL: docs("language/values/outputs")),
        "variable": QuickHelpEntry(
            title: "Variable",
            text: "A variable is an input the configuration asks you for, like a region or an instance size. Change its value and the next preview shows what that changes.",
            learnMoreURL: docs("language/values/variables")),
        "state": QuickHelpEntry(
            title: "State",
            text: "State is Terraform's record of what it has created. Habitable only reports what state recorded, so a change made outside Terraform shows up after the next refresh.",
            learnMoreURL: docs("language/state")),
        "plan": QuickHelpEntry(
            title: "Plan",
            text: "A plan lists what Terraform would add, change, or remove, without doing any of it. Habitable calls it Preview Changes.",
            learnMoreURL: docs("cli/commands/plan")),
        "apply": QuickHelpEntry(
            title: "Apply",
            text: "Apply carries out a plan and changes real infrastructure. Review the preview first, because some changes can't be undone.",
            learnMoreURL: docs("cli/commands/apply")),
        "replace": QuickHelpEntry(
            title: "Replace",
            text: "Terraform can't change this in place, so it deletes the resource and creates a new one. Anything only the old one held is gone once the new one is up.",
            learnMoreURL: docs("language/resources/behavior#replacing")),
        "remove": QuickHelpEntry(
            title: "Remove",
            text: "Terraform will destroy this resource and stop tracking it in state. Its data is deleted along with it.",
            learnMoreURL: docs("cli/commands/destroy")),
        "data-source": QuickHelpEntry(
            title: "Data source",
            text: "A data source reads something that already exists, like an image ID or a DNS zone. It never creates or changes anything.",
            learnMoreURL: docs("language/data-sources")),
        "module": QuickHelpEntry(
            title: "Module",
            text: "A module is a folder of Terraform files used as one reusable unit. Habitable groups its resources under the module's name.",
            learnMoreURL: docs("language/modules")),
        "provider": QuickHelpEntry(
            title: "Provider",
            text: "A provider is the plugin that talks to a service such as AWS, Cloudflare, or GitHub. It decides which resource types exist.",
            learnMoreURL: docs("language/providers")),
        "workspace": QuickHelpEntry(
            title: "Workspace",
            text: "A workspace holds one set of state and variables for a configuration. In HCP Terraform it also holds the run history and settings.",
            learnMoreURL: docs("cloud-docs/workspaces")),
        "tile": QuickHelpEntry(
            title: "Tile",
            text: "A tile is one thing on the Map, such as a database or a DNS record. Select it to see its attributes."),
        "band": QuickHelpEntry(
            title: "Band",
            text: "A band is a row of tiles of one kind, like databases or networking. Empty bands are left out."),
        "drift": QuickHelpEntry(
            title: "Drift",
            text: "Drift is a difference between state and the real resource, usually from a change made outside Terraform. Habitable only reports drift that Terraform found during a refresh.",
            learnMoreURL: docs("tutorials/state/resource-drift")),
        "run": QuickHelpEntry(
            title: "Run",
            text: "A run is one plan, and usually one apply, recorded in HCP Terraform. Each run keeps its log and the changes it made.",
            learnMoreURL: docs("cloud-docs/run/remote-operations")),
        "speculative-plan": QuickHelpEntry(
            title: "Speculative plan",
            text: "A speculative plan shows what would change without ever being applied. HCP Terraform runs one on each pull request.",
            learnMoreURL: docs("cloud-docs/run/modes-and-options#plan-only-runs")),
        "auto-apply": QuickHelpEntry(
            title: "Auto-apply",
            text: "With auto-apply on, HCP Terraform applies a successful plan without waiting for anyone to approve it.",
            learnMoreURL: docs("cloud-docs/workspaces/settings#auto-apply-and-manual-apply")),
        "lock": QuickHelpEntry(
            title: "Lock",
            text: "A lock stops other runs from changing this state while one is in progress. If a run was interrupted, the lock may need to be released by hand.",
            learnMoreURL: docs("language/state/locking")),
        "configuration-version": QuickHelpEntry(
            title: "Configuration version",
            text: "A configuration version is the snapshot of your Terraform files that a run used. Each commit or upload creates a new one.",
            learnMoreURL: docs("cloud-docs/run/api")),
        "pull-request": QuickHelpEntry(
            title: "Pull request",
            text: "Changes to HCP Terraform workspaces go through a GitHub pull request, so someone can review them before they apply."),
        "sensitive": QuickHelpEntry(
            title: "Sensitive value",
            text: "Terraform marked this value sensitive, so Habitable hides it. It is still stored in state.",
            learnMoreURL: docs("language/values/outputs#sensitive-suppressing-values-in-cli-output")),
        "backend": QuickHelpEntry(
            title: "Backend",
            text: "The backend is where Terraform keeps state: on this Mac, or in HCP Terraform or another remote service.",
            learnMoreURL: docs("language/backend")),
        "checkout": QuickHelpEntry(
            title: "Checkout",
            text: "A checkout is the copy of the repository on this Mac. Habitable reads the Terraform files in it and never edits them unless you ask."),
    ]
}

/// Holds whether Quick Help is on and which entry the pointer is over.
@MainActor
final class QuickHelpModel: ObservableObject {
    static let enabledKey = "quickHelp.enabled"

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var current: QuickHelpEntry?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func show(_ entry: QuickHelpEntry) {
        current = entry
    }

    /// Clears only if `entry` is still current, so leaving a stale item can't blank a newer one.
    func clear(_ entry: QuickHelpEntry) {
        if current == entry { current = nil }
    }
}
