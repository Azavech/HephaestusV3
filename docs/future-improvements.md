# Future improvements

What V3 doesn't do yet, kept for later by the owner's decision when V3 began to bring HephaestusV2 over
(13 November 2026). Each entry says what V2 had and where V2 describes it, so that the work can start from
there. V2's repository is `Azavech/HephaestusV2`; its paths below are relative to it.

V2's features that V3 brings over now, one at a time, are not listed here: Projects, the MCP server, Tickets
and bundles, the Dashboard, Chat, Builds, Contracts, the Service Map with Kubernetes and Argo CD, Virtual
Machines, and the release. Neither are the features the owner left out of V3 for good: skills, memories,
costs and plan usage, chat titles written by Haiku, Claude's answers to comments, Implement All and its
worktrees, CI and Auto Setup chats, feedback, V2's own project, Markdown markers, and the question pickers of
Claude's tools.

## New tools

Each would be a tool of its own, with its window and target, in the redesign.

| Tool | What V2 had | V2 docs | V2 sources |
| --- | --- | --- | --- |
| Code editor | The project's folder as a lazy file tree beside editor tabs and a source editor: line numbers, current line, indentation, comments, find and replace, go to line, syntax highlighting for Go and Swift (basic for Markdown, JSON, YAML and shell), format on save with `gofmt` and `swift-format`, git-ignored files dimmed. | `docs/code-editor.md` | `Sources/HephaestusUI/Code/`, `Sources/HephaestusCore/Files/`, `Sources/HephaestusText/` |
| Docs viewer | The Markdown files of the project's docs folder (`docsPath`) as a tree, each shown as Preview, Edit or Split, with the shared Markdown renderer. | `docs/documentation-viewer.md` | `Sources/HephaestusUI/Docs/`, `Sources/HephaestusCore/Files/DocsFolder.swift`, `Sources/HephaestusText/` |
| Search | One panel (⇧⌘F) over projects, tickets, bundles, docs, code, chats and web tabs, with scopes and ranked matches; Claude's `search` tool. | `docs/search.md` | `Sources/HephaestusUI/Search/`, `Sources/HephaestusCore/Search/` |
| Web tabs | An integrated browser per project: tabs stored in `project.yml` (`webTabs`, which V3 keeps as read), locked tabs with an original URL, the GitHub page and CI tabs kept by the app. | `docs/web-tabs.md` | `Sources/HephaestusUI/Web/`, `Sources/HephaestusCore/Models/GitHubTabs.swift` |
| Views | The views a Swift project declares, in a folder tree, with their `#Preview`s live on the Mac and on iPhone and iPad simulators at each device's size class, a visual inspector, and the design of views with Claude. | `docs/views.md` | `Sources/HephaestusUI/Views/`, `Sources/HephaestusCore/SwiftViews/` |

## Virtual machines

V3's Virtual Machines window was designed with two things V2 never had. They stay sample data until a
later improvement builds them:

- **Linux machines**, with a console instead of a screen. V2's machines run macOS only, through
  Virtualization.framework with its guest agent (`docs/virtual-machines.md`,
  `Sources/HephaestusCore/VirtualMachines/`, `Sources/HephaestusAgent/`).
- **Machine snapshots**: Take Snapshot and the inspector's snapshot list. V2 clones an image's disk to create
  a machine (APFS clones) but keeps no snapshot of a running machine.

See the window's page, [Virtual Machines](ui/virtual-machines.md).
