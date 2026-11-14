import Foundation
import ToolsFoundation

/// The Builds tool's read function for other clients, the chat among them: what a run or a release
/// is, in a line, and the questions worth asking about it. In the real suite it answers from the
/// tool's API; here, from the sample runs and releases.
public enum BuildsReader {
    /// `focus` names a run of `project`'s repository by its number, `1288`, or a release by its tag,
    /// `release:v1.4.0`. Nil when it names neither.
    public static func read(_ focus: String, project: Project) -> ToolReading? {
        read(focus, project: project, store: SampleBuildStore())
    }

    /// As the Builds window reads them: the runs and releases of the repository's owner, which a sub
    /// project may share.
    static func read(_ focus: String, project: Project, store: any BuildStore) -> ToolReading? {
        switch BuildsFocus(focus) {
        case .run(let number)?:
            guard let run = store.runs(of: project).first(where: { $0.id == number }) else { return nil }
            return ToolReading(
                action: String(localized: "Read run \(String(run.id))", bundle: #bundle, comment: "A read of a run, by its number"),
                detail: detail(of: run),
                suggestions: suggestions(for: run)
            )
        case .release(let tag)?:
            guard let release = store.releases(of: project).first(where: { $0.id == tag }) else { return nil }
            return ToolReading(
                action: String(localized: "Read release \(release.tag)", bundle: #bundle, comment: "A read of a release, by its tag"),
                detail: detail(of: release),
                suggestions: suggestions(for: release)
            )
        case nil:
            return nil
        }
    }

    /// The run as a chat names it: `Run 1288`, with its number as the focus.
    static func reference(_ run: WorkflowRun, in project: Project) -> ChatReference {
        ChatReference(
            tool: .builds, projectID: project.id, focus: BuildsFocus.run(run.id).focus,
            title: String(localized: "Run \(String(run.id))", bundle: #bundle, comment: "A run, by its number, as a chat names it")
        )
    }

    /// The release as a chat names it: `Release v1.4.0`, with `release:v1.4.0` as the focus.
    static func reference(_ release: Release, in project: Project) -> ChatReference {
        ChatReference(
            tool: .builds, projectID: project.id, focus: BuildsFocus.release(release.tag).focus,
            title: String(localized: "Release \(release.tag)", bundle: #bundle, comment: "A release, by its tag, as a chat names it")
        )
    }

    /// The run's title, status, workflow and branch: `Verify webhook signatures · Failed · CI on main`.
    static func detail(of run: WorkflowRun) -> String {
        switch run.status {
        case .success:
            String(localized: "\(run.title) · Passed · \(run.workflow) on \(run.branch)", bundle: #bundle, comment: "A read run: its title, status, workflow and branch")
        case .failure:
            String(localized: "\(run.title) · Failed · \(run.workflow) on \(run.branch)", bundle: #bundle, comment: "A read run: its title, status, workflow and branch")
        case .running:
            String(localized: "\(run.title) · Running · \(run.workflow) on \(run.branch)", bundle: #bundle, comment: "A read run: its title, status, workflow and branch")
        case .queued:
            String(localized: "\(run.title) · Queued · \(run.workflow) on \(run.branch)", bundle: #bundle, comment: "A read run: its title, status, workflow and branch")
        case .cancelled:
            String(localized: "\(run.title) · Cancelled · \(run.workflow) on \(run.branch)", bundle: #bundle, comment: "A read run: its title, status, workflow and branch")
        }
    }

    /// The release's title, kind and date: `Order cancellation · Latest · Published Nov 10, 2026`.
    static func detail(of release: Release) -> String {
        let date = release.publishedAt
        if release.isLatest {
            return String(localized: "\(release.title) · Latest · Published \(date, format: .dateTime.day().month(.abbreviated).year())", bundle: #bundle, comment: "A read release: its title, that it is the latest, and its date")
        } else if release.isPrerelease {
            return String(localized: "\(release.title) · Pre-release · Published \(date, format: .dateTime.day().month(.abbreviated).year())", bundle: #bundle, comment: "A read release: its title, that it is a pre-release, and its date")
        } else {
            return String(localized: "\(release.title) · Published \(date, format: .dateTime.day().month(.abbreviated).year())", bundle: #bundle, comment: "A read release: its title and its date")
        }
    }

    /// What to ask about a run in its state: why it failed only when it did.
    static func suggestions(for run: WorkflowRun) -> [String] {
        let number = String(run.id)
        let changes = String(localized: "What changed in run \(number)?", bundle: #bundle, comment: "A question to ask the chat about a run")
        return switch run.status {
        case .failure: [String(localized: "Why did run \(number) fail?", bundle: #bundle, comment: "A question to ask the chat about a failed run"), changes]
        case .running: [String(localized: "Which step is run \(number) on?", bundle: #bundle, comment: "A question to ask the chat about a running run"), changes]
        case .queued: [String(localized: "Why is run \(number) still queued?", bundle: #bundle, comment: "A question to ask the chat about a queued run"), changes]
        case .cancelled: [String(localized: "Why was run \(number) cancelled?", bundle: #bundle, comment: "A question to ask the chat about a cancelled run"), changes]
        case .success: [changes, String(localized: "Was run \(number) slower than usual?", bundle: #bundle, comment: "A question to ask the chat about a run that passed")]
        }
    }

    /// What to ask about a release: what it brings, and what a pre-release still lacks.
    static func suggestions(for release: Release) -> [String] {
        let tag = release.tag
        let news = String(localized: "What's new in release \(tag)?", bundle: #bundle, comment: "A question to ask the chat about a release")
        return release.isPrerelease
            ? [news, String(localized: "What's left before release \(tag) is final?", bundle: #bundle, comment: "A question to ask the chat about a pre-release")]
            : [news, String(localized: "Which runs went into release \(tag)?", bundle: #bundle, comment: "A question to ask the chat about a release")]
    }
}
