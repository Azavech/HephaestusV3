# Decisions

The open questions met while bringing HephaestusV2 over, each answered with the recommended default so that
the work goes on. The owner reviews them whenever they like; the page that applies each one says "default
chosen at design time" beside it. The owner's own rules come first, then the phases, newest last.

## V2's prompts

On 14 November 2026 the owner set the rule: V3 gets none of V2's prompts. Everything V2 wrote for Claude to
read stays in V2: the system prompts and the skills behind them (common, project, ticket, bundle, implement,
finish, naming, notification summary, comment answers, CI, setup, feedback), the texts its hooks added to the
user's messages, and its tool descriptions. What V3 tells Claude it writes itself, says what a tool does and
which rules the app enforces, and never tells Claude how to work.

| Question | Default chosen | Where |
| --- | --- | --- |
| What about the tool descriptions written in Phases 1 to 3? | Rewritten in V3's words: no sentence of V2's descriptions is left, and no advice to Claude ("ask the user for the name", "set in_progress when you start", "use add_comment to report work"). What remains in common with V2 is the API itself: field, status and argument names. | [MCP › What Claude reads](mcp.md#what-claude-reads) |
| Does the server send instructions? | No: `initialize` has no `instructions` member. | [MCP › Methods](mcp.md#methods) |
| What happens to the ticket template? | Dropped: it existed so Claude's tickets followed V2's six headings. Claude's descriptions are taken as written, like the user's. | [Data › Ticket rules](data.md#ticket-rules) |
| What does the Chat (Phase 5) send the Claude CLI? | No V2 system prompt, skill or hook text: no `--append-system-prompt` built from V2's skills, and no hook that adds the linked items to a message. The permission hook stays, since it carries approvals, not text for Claude. Anything V3 adds is written for V3 and documented with the Chat. | The Chat's pages, written in Phase 5 |

## Phase 0: Foundation (13 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Where in the App Group container does the data go? | At the container's root, `~/Library/Group Containers/group.fr.azavech.hephaestusv3/`, as V2 kept its files at the root of its data folder. | [Data › Data folder](data.md#data-folder) |
| What does the import from V2 bring? | The project list and the chosen environments, nothing else: V2's other files on this Mac (settings, secrets, plan usage) are V2's own. | [Data › Import from HephaestusV2](data.md#import-from-hephaestusv2) |
| When does the import run? | When the data folder has no `registry.yml`; it always writes one, so it runs once. | same |
| Which project is V2's own? | The folder whose project file has the identifier `HEPH`, V2's reserved identifier. A folder whose file can't be read is kept. | same |
| Where do V2's keys that V3 doesn't use go when V3 writes a file? | At their place in V2's order, as read; V3 never adds one. | [Data › Unknown keys](data.md#unknown-keys) |
| In what order are unknown keys written? | The order they were read in, rather than V2's sorted order, so a file edited by hand keeps its order. | same |
| How does V3 store a project's color? | The name of a tint (`accent`, `accentSecondary`, `info`, `success`, `warning`); V2's `#RRGGBB` still reads. | [Data › Project color](data.md#project-color) |
| How does V3 store a library? | A fourth `type` value, `library`. | [Data › Project kind](data.md#project-kind) |
| How long may a kubectl command run? | 15 seconds: the commands V3 runs now are short reads (V2 allowed 60 s for its tools). | [Architecture › ExternalTools](architecture.md#externaltools) |
| Are the data targets' messages localized? | No: they are technical details in English, shown under a window's localized sentence. Rule errors are cases the windows word themselves. | [Data › Validation](data.md#validation) |

## Phase 1: Projects (13 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Does V3 keep V2's reserved identifier `HEPH`? | No: V3 doesn't carry V2's own project, so `HEPH` is an identifier like any other once the import is done. | [Data › Changes](data.md#changes) |
| How are outside changes applied? | A batch that matters loads the whole tree again and compares it with memory, rather than V2's path-by-path processing: the projects are few and their files small, and one rule covers renames, moves and dropped events. | [Data › Outside changes](data.md#outside-changes) |
| What does a project whose file became invalid show? | The version loaded before, with a file issue giving the reason, as V2 kept it in memory; V2 only logged it. | same |
| Where does the windows' code meet the project data? | ProjectsKit depends on ProjectData, the data target of its own feature, and maps it onto ToolsFoundation's `Project`; the data targets stay free of UI, and ToolsFoundation of data. The plan had ProjectData depend on ToolsFoundation instead. | [Architecture › The package](architecture.md#the-package) |
| How does a V2 color become a tint? | The tint of the nearest hue; a gray, or no color, gives Accent. V3 writes the tint's name when the color changes. | [Architecture › ProjectsKit](architecture.md#projectskit) |
| What is V2's `none` type in V3? | A fourth kind, Other, listed after Libraries as "Other Projects". | [Projects](ui/projects.md) |
| Where does a new project's folder go by default? | Beside the selected project's top-level folder; without a selection, `~/Developer` when it exists, else the home folder (V2 used the active project's, else the home folder). | [Projects › New Project](ui/projects.md#new-project) |
| What shows for entries that don't load? | An Unavailable section at the end of the sidebar, with each reason; the entries can't be selected or removed yet. | [Projects › States](ui/projects.md#states) |
| What does the empty window offer? | New Project… and Add Existing Folder…, since a first launch without V2's list starts empty. | same |
| What do tools that haven't come over show? | Nothing: their windows, tiles, menu items, shortcuts and Settings tab are hidden; the previews keep every tool. | [Navigation › Available tools](ui/navigation.md#available-tools) |
| Which shortcut adds an existing folder? | ⌘O, File ▸ Add Existing Folder…, as V2's Open Project…; nothing else used it. | [Navigation › Menus and shortcuts](ui/navigation.md#menus-and-shortcuts) |
| Where does a selection go after a removal? | The nearest ancestor still listed, else the first project, as V2's windows did. | [Projects › Remove Project](ui/projects.md#remove-project) |
| Is Project Settings a section or a window? | A window per project (⇧⌘,), as each tool has its windows; V2 showed it as a section of its main window. | [Project Settings](ui/project-settings.md) |
| How is the icon chosen? | A text field for the SF Symbol's name, checked against this Mac's symbols, with the symbol beside it; V2's searchable symbol popover can come later. | same |
| What does a namespace or deployment field offer? | A text field with a menu of the cluster's names, as macOS SwiftUI has no combo box; any name can be typed. | same |
| How is the connection to a cluster checked? | By listing its namespaces with the kubeconfig file, which also gives the suggestions. | same |
| What may an inherited environment's Name field do? | Nothing: it shows the parent's name, disabled, as V2. | same |
| May a copy of a stored environment skip the write rules? | No: each stored environment keeps at most one equal environment as it is; a copy is checked, so two environments can't share a name. V2 let an exact copy through. | [Data › Changes](data.md#changes) |

## Phase 2: MCP server (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Which port? | 47830, V3's own, so that V3 doesn't collide with a V2 still installed (47820). | [MCP › Overview](mcp.md#overview) |
| Which server name? | `hephaestus`, as V2: Claude's tool names stay `mcp__hephaestus__<tool>`. | same |
| Which tokens? | The external token only; the chats' tokens come with Chat. | [MCP › Authentication](mcp.md#authentication) |
| Where do the operations live? | In each kit, beside the window whose functions they call; MCPKit knows no kit and no UI, and ToolsScenes gathers the registry. | [Architecture › MCPKit](architecture.md#mcpkit) |
| What do the results look like? | V2's shapes with V3's names (`folder` for V2's `rootPath`, `library` added to the types, a tint accepted as `color`); absent values are left out rather than `null`. | [MCP › Tools](mcp.md#tools) |
| What does `open_in_app` open? | Only what V3 has: a project in the Projects window, or its settings; each feature adds its kinds. | [MCP › open_in_app](mcp.md#open_in_app) |
| Where is the port kept? | `settings.yml`, V3's own settings file, created with this first setting. | [Data › Settings file](data.md#settings-file) |
| Does Settings show the whole token? | No: its first 8 characters; Copy copies it whole. | [MCP › Settings ▸ MCP](mcp.md#settings--mcp) |

## Phase 3: Tickets and bundles (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| How is a ticket named without Haiku? | With V2's provisional title, kept as the title: the description's first plain line, cut to 60 characters, else `Untitled Ticket`; a bundle with its tickets' titles. Either can be renamed. | [Data › Ticket rules](data.md#ticket-rules) |
| May Claude give a title? | Yes: V2 had no title input because Haiku named Claude's tickets; without Haiku the provisional title would be all Claude could give. | same |
| Must a description be written? | Only without a title, to make the provisional title; a ticket with a title may have an empty description. V2 always required one. | same |
| Is the description template kept? | No (changed on 14 November 2026): it only steered what Claude wrote, one of V2's prompts ([V2's prompts](#v2s-prompts)). Descriptions are free Markdown for the user and Claude alike; the New Ticket sheet keeps its empty Description field. | same |
| What may Claude do with a draft (V3)? | Nothing to its status: Claude neither makes a draft nor changes one, so that "not ready yet" stays the user's call. Claude's new tickets start To Do. | same |
| Do priority and labels (V3) add history entries? | No: the history keeps V2's six kinds. | [Data › Ticket changes](data.md#ticket-changes) |
| Which device name goes into the history? | The Mac's computer name (`SCDynamicStoreCopyComputerName`), as V2's local windows. | [Data › Ticket file](data.md#ticket-file) |
| What happens to copied files when a change fails? | They are removed for every change that copies files (V2 removed them only for a creation), so no unreferenced file stays. | [Data › Ticket changes](data.md#ticket-changes) |
| Are V2's runtime keys kept? | No: `inverseLinks` and a comment's `answer` were never meant to be stored; they are ignored when read and never written. | [Data › Ticket file](data.md#ticket-file) |
| How does the ticket data follow outside changes? | Through the projects' own stream: `ProjectSession.observeFileEvents` hands each batch to the ticket library, which reads again only the files the batch names. | [Architecture › TicketData](architecture.md#ticketdata) |
| How does V2's ticket view fit V3's Tickets window? | Into the parts the redesign has: V2's ticket links join **Linked** (Depends On, Blocks, Related) beside the other tools' items; history and comments share **Activity**; attachments get a section; editing is an **Edit** mode in place of the header (V2 edited in place). | [UI › Tickets](ui/tickets.md#ticket-detail) |
| What does V3's Created status write? | `todo`, V2's To Do: V3's names stay, the files keep V2's values. | [Data › Ticket file](data.md#ticket-file) |
| Which bundles does a ticket show? | All of its project's bundles that hold it, one per line: V2 lets a ticket be in several. | [UI › Tickets](ui/tickets.md#properties) |
| Where is New Bundle? | In the sidebar's Bundles header, which now always shows, and in a ticket's **Add to Bundle ▸** menu. | [UI › Tickets](ui/tickets.md#sidebar) |
| Who appears in the activity? | "You" and "Claude": V3 runs on one Mac, so the device name stays in the file only; chat titles come with Chat. | [UI › Tickets](ui/tickets.md#activity) |
| How is Markdown drawn without V2's web view? | Natively, from V2's block model (`MarkdownBlockRenderer`), with each line break kept, since people type plain lines; V2's markers and HTML output aren't brought over. | [Text](text.md) |
| Which colors highlight code? | AZDesign's semantic colors, after Dracula's code colors: the workspace allows no hex values in views. | [UI › Tickets](ui/tickets.md#markdown) |
| Where do relative links in a ticket go? | To the project's file, opened in its default app: V2's documentation viewer isn't brought over. | same |
| Which ticket tools does Claude get? | V2's sixteen, without `implement_ticket` and `implement_bundle`; `create_ticket` and `update_ticket` also take V3's `title`, `priority` and `labels`, and `list_tickets` filters drafts too. The descriptions drop V2's Haiku naming and implementation workflow. | [MCP › Tools](mcp.md#tools) |
| Which attachment paths do results give? | Absolute ones in every result, not only `get_ticket`'s as in V2: one ticket JSON everywhere. | same |
| How does a change by Claude reach the windows? | The tool calls the shared `TicketLibrary`, then `TicketSession.refresh()`, so open Tickets windows show it at once rather than at the next file event. | [Architecture › TicketData](architecture.md#ticketdata) |
