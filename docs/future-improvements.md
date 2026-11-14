# Future improvements

What Hephaestus V3 doesn't do yet, kept for later by the owner's decision (13 November 2026). Each entry says
what the feature would do, so that the work can start from there.

## New tools

Each would be a tool of its own, with its window and target.

| Tool | What it would do |
| --- | --- |
| Code editor | The project's folder as a lazy file tree beside editor tabs and a source editor: line numbers, current line, indentation, comments, find and replace, go to line, syntax highlighting for Go and Swift (basic for Markdown, JSON, YAML and shell), format on save with `gofmt` and `swift-format`, git-ignored files dimmed. Contracts would then open any OpenAPI file of the project. |
| Docs viewer | The Markdown files of the project's docs folder (`docsPath`) as a tree, each shown as Preview, Edit or Split, with the app's Markdown renderer ([Text](text.md)). |
| Search | One panel (⇧⌘F) over projects, tickets, bundles, docs, code, chats and web tabs, with scopes and ranked matches, and a `search` tool for Claude. |
| Web tabs | An integrated browser per project: tabs stored in `project.yml` (`webTabs`, which the app keeps as read), locked tabs with an original URL, the GitHub page and CI tabs kept by the app. |
| Views | The views a Swift project declares, in a folder tree, with their `#Preview`s live on the Mac and on iPhone and iPad simulators at each device's size class, a visual inspector, and the design of views with Claude. |

## Virtual machines

The Virtual Machines window runs macOS machines. It was designed with more, which stays sample data (the
window hides it for the data folder's machines) until a later improvement builds it:

- **Linux machines**, with a console instead of a screen. The machines run macOS only, through
  Virtualization.framework with the guest agent ([Guest agent](guest-agent.md)).
- **Machine snapshots**: Take Snapshot and the inspector's snapshot list. A machine starts as an APFS clone of
  its image's disk, but no snapshot of a running machine is kept. A snapshot could be an APFS clone of the
  disk with the framework's saved machine state (`saveMachineStateTo`).
- **CPU use**: the inspector's CPU figure, which the framework doesn't give; the guest agent could report it.
- **Opening a machine from a chat**: a `vm_` tool-call row has no item to open, machines not being a tool.

See the window's page, [Virtual Machines](ui/virtual-machines.md).
