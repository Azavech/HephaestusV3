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
| What does the Chat (Phase 5) send the Claude CLI? | No V2 system prompt, skill or hook text: no `--append-system-prompt`, no `--settings` hooks, no plugin. V3's only addition is one line after a message, naming the item its chip carried ("Attached: ticket ORD-142 of project ORD"). No hook is needed for approvals either: the app's MCP server asks the user before a change ([MCP › Permissions](mcp.md#permissions)). | [Data › Launch](data.md#launch), [Data › Messages](data.md#messages) |

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

## Phase 4: Dashboard (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Where is a Dashboard kept? | In the project file, as V2 kept it: `dashboardWidgets` and `dashboardGraphWindow`, written in V2's layout. The proof of concept's user defaults entries are no longer read. | [Data › Dashboard widget](data.md#dashboard-widget), [UI › Dashboard › Saving](ui/dashboard.md#saving) |
| Which environment do the widgets read? | The project's current environment, as V2's widgets did; choosing one on the Dashboard makes it the project's current environment for every window. The proof of concept kept its own per Dashboard. | [UI › Dashboard › Environment and time window](ui/dashboard.md#environment-and-time-window) |
| Which widgets show while their tool hasn't come over? | None: Project always, Tickets now, the others with their tools. Hidden widgets take no place and keep their stored positions, as V2's hidden graph widgets did, so a layout made in V2 comes back whole. | [UI › Dashboard › Which widgets show](ui/dashboard.md#which-widgets-show) |
| What happens to V2's Recent Chats and Cost widgets? | Kept in the file with their settings and never shown: Recent Builds replaced them in V3's design, and costs aren't brought over. | same |
| Which list does a project without a stored list show? | V3's default list (Project, Tickets, Recent Builds, Service Graph for a service), not V2's (Project, Tickets, Recent Chats, Cost). | [UI › Dashboard › Default list and sample layouts](ui/dashboard.md#default-list-and-sample-layouts) |
| What about the sample layouts of Orders and Shop? | Previews and screenshots only: a real project named ORD or SHOP shows the default list. | same |
| What about V2's **Last 7 days** window? | Kept when stored, and shown as the last hour until the Service Map brings the window over (Phase 8). | [Data › Project file](data.md#project-file) |
| What do the Tickets widget's statuses include? | V3's Draft too, for widgets V3 adds; a V2 widget keeps its four. | [Data › Dashboard widget](data.md#dashboard-widget) |
| How does a failed change show? | Its message under the toolbar until the next change; the stored list shows again, and the changes queued after it are dropped (V2 showed the engine's message in red under the bar). | [UI › Dashboard › Applying changes](ui/dashboard.md#applying-changes) |

## Phase 5: Chat on the Claude CLI (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Which of the CLI's own tools does Claude get in a chat? | None (`--tools ""`), and no MCP server but the app's (`--strict-mcp-config`): Claude reads and changes only through the app's tools, as the Chat's design says ("Nothing it reads or changes goes around them"). V2's chats could run commands and edit files; for that, Claude Code in a terminal with the app's MCP server does it. | [Data › Launch](data.md#launch) |
| Where do the user's permissions hold? | In the app's MCP server, before each call of a chat's Claude (`ChatGate`), not in the CLI's permission modes: the CLI runs the app's tools without asking (`--allowedTools`), so an allow rule in the user's own Claude Code settings can't skip a card. V2's permission modes, Ultracode and context window are kept in the chat files as read and not used. | [MCP › Permissions](mcp.md#permissions) |
| What does Always mean for deletions? | They ask first anyway, as in V2, where the deleting tools were never pre-approved; Never refuses them. | same |
| Which permission covers projects? | A new **Change projects** (Never, Ask First, Always; Ask First by default) beside Change tickets, in Settings ▸ Chat and the inspector: Claude can add, change and remove projects through the MCP tools, which no permission covered. | [UI › Chat › Settings ▸ Chat](ui/chat.md#settings--chat) |
| How does Claude know what a message is about? | One line V3 writes after the message: the item of its chip, or the project from the Chat window. It describes the item only. | [Data › Messages](data.md#messages) |
| Which chats does V3 list? | Every chat in the projects' `.hephaestus/chats/`, V2's of every kind; V3 makes `project` chats, with V3's `origin` for the panel's. Their items V3 doesn't bring over (V2's pickers, shown images) are skipped. | [Data › Chats](data.md#chats) |
| How is a new chat titled without Haiku? | The first line of its first message that isn't empty, at most 80 characters, as the Chat's design titled new conversations; `rename_chat` lets Claude rename one when asked. | [Data › Chat file](data.md#chat-file) |
| Where do the model and effort of new chats live? | `settings.yml` (`chatModel`, `chatEffort`), set in Settings ▸ Chat › Replies; each chat keeps its own, set in the inspector. | [Data › Settings file](data.md#settings-file) |
| Does V3 read the CLI's models before a chat starts? | Yes, as V2: a probe that only answers `initialize` (no session, no tools, no message), after the CLI is found. | [Data › The CLI](data.md#the-cli) |
| How does Stop show? | A **Stop** button (⌘.) on the activity line at the transcript's end, rather than turning Send into Stop, so the composer's Send keeps its one role. | [UI › Chat › Activity](ui/chat.md#activity) |
| Can the user send while Claude works? | No: Send stays disabled during a turn, as the design had it while a reply was coming; Stop ends the turn. | [UI › Chat › Composer](ui/chat.md#composer) |
| What shows of the transcript? | The user's messages, Claude's text (inline Markdown), the calls of the app's tools, the cards, and the app's lines; not thinking, not sub-agents' work, not the end of a turn that went well, no cost. | [UI › Chat › Turns](ui/chat.md#turns) |
| In which language are the app's lines? | English, as stored in the transcript, as V2 stored them; the rows' and cards' wording is the tools', in the user's language. | [Data › Chat items](data.md#chat-items) |
| How many transcripts stay in memory? | Those of chats open in a window and of running chats, plus at most 12 others, the oldest read dropped first (keep RAM low). | [Data › Chat transcript file](data.md#chat-transcript-file) |
| What happens to the sample engine? | It stays for previews and the documentation's captures only. | [UI › Chat › Samples](ui/chat.md#samples) |

## Phase 6: Builds (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| What names a run? | GitHub's id (`databaseId`), which is unique; routes, `get_run` and the window use it, and the window shows the run's `number` (`#641`), as GitHub does. A run's number repeats across workflows. | [Data › Builds](data.md#builds) |
| How are releases read? | `gh api …/releases?per_page=50`, which gives notes and files in one call, so the Assets column needs no call per release; `gh release list` tells the latest. V2 read each release with `gh release view`. | [Data › gh calls](data.md#gh-calls) |
| Where do step logs come from? | `gh run view --log --job=<id>`, read when a step is picked, kept until the window's next read of that run; a job's log exists once it has completed. V2 showed no logs. | [UI › Builds › Step log](ui/builds.md#step-log) |
| How does V3's single Re-run button carry V2's three? | Re-run runs all jobs; with failed jobs it is a menu button whose click re-runs the failed ones and whose menu offers both; Cancel Run takes its place while the run is queued or running. | [UI › Builds › Run details](ui/builds.md#run-details) |
| What may Claude do in Builds? | Read runs, jobs, logs and releases (seven tools); re-run and cancel under **Start builds** (Never by default, or Ask First); no downloads. | [MCP › Permissions](mcp.md#permissions) |
| When does the Dashboard's Recent Builds read? | When it shows, then every 30 s, as the window. | [UI › Dashboard](ui/dashboard.md) |
| What does the chat's reader read now? | Tickets and Builds read the app's data (Tickets did read its samples until now); the Service Map and Contracts keep their samples until their phases. | [UI › Chat › How Claude reaches the tools](ui/chat.md#how-claude-reaches-the-tools) |
| What about the Projects window's Builds tile and activity? | They keep the samples' text for sample projects, and "Workflow runs and releases on GitHub" otherwise: reading every project's runs for a tile would call gh for each project. | [UI › Projects](ui/projects.md) |

## Phase 7: Contracts (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Which file is a project's contract? | `openapi/contract.yaml` of its folder, V2's API Explorer file, for a service; V2's Code section contracts (any OpenAPI file opened in the editor) wait for the Code editor. | [Data › Contracts](data.md#contracts) |
| How are operations named? | By `operationId` in the window and routes, by `<METHOD> <path>` (V2's key) in the stored values and `api_call`, so that the gate reads the method from it. | [MCP › api_call](mcp.md#api_call) |
| Which environment do requests go to? | The project's current environment, which picking one in the window changes, as V2's form did. | [UI › Contracts › Environment and Send](ui/contracts.md#environment-and-send) |
| What is stored? | The credentials and added headers, in V2's `openapi-requests.json` (imported once from V2); the parameters and bodies typed stay while the operation is selected, as the design had it. | [Data › Stored values](data.md#stored-values) |
| Where are credentials typed? | A **Credentials and Headers** sheet from the toolbar (`key`), since the design's request box has no room for them. | [UI › Contracts › Credentials and headers](ui/contracts.md#credentials-and-headers) |
| Which media type does the body use? | The operation's first; the window shows one body editor. Claude's `api_call` may name another. | same |
| What may Claude call? | `GET` and `HEAD` always (V2's rule); other methods under a new **Call APIs that change data** (Never, Ask First, Always; Ask First by default). | [MCP › Permissions](mcp.md#permissions) |
| Are responses kept? | While the app runs, per operation; never written. | [UI › Contracts](ui/contracts.md) |
| What about V2's schema trees, Info detail, and Quick Look of binary bodies? | Not in V3's design: the window shows operations, the request and the documented responses; a binary body reads "Binary body (<size>)". | same |

## Phase 8: Service Map, Kubernetes and Argo CD (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Which of V2's node kinds map to V3's? | Services to services, V2's postgres Clusters to databases, buckets to external services; V3's gateways, workers and queues stay for the samples, since V2's sources don't tell them. | [Data › Service map](data.md#service-map) |
| How often does the map read? | V2's 5 s after each read, while **Live** is on; once per change of environment or window when it is off. | [UI › Service Map › Toolbar](ui/service-map.md#toolbar) |
| Which time windows? | V3's 5 min, 1 hour and 24 hours; V2's 7 days isn't offered. | same |
| Where do the logs come from? | The span events with `log.level` of the window's requests, V2's Log tab; pod logs are Claude's `k8s_logs`. | [Data › Calls and requests](data.md#calls-and-requests) |
| Which actions does the user get? | Restart, Scale and Argo CD Sync in the own service's details, each confirmed first; port forwards stay Claude's (and Jaeger's), with no window of their own yet. | [UI › Service Map › Service](ui/service-map.md#service) |
| What may Claude do? | Read deployments, logs, events, Argo CD, the map and a request; restart, scale, sync and forward ports under a new **Operate deployments** (Never, Ask First, Always; Ask First by default). V2 gave these tools to chats only; V3's external token may call them too, as for every tool. | [MCP › Permissions](mcp.md#permissions) |
| Which project's environments? | The tools take a `projectID` and an `environment`, since V3's tools aren't tied to a chat's project. | [MCP › Tools](mcp.md#tools) |
| What about the status line? | A bar over the graph shows reading, a failure, or the sources' and Jaeger's problems; V2's request and trace counts aren't shown. | [UI › Service Map › States](ui/service-map.md#states) |

## Phase 9: Virtual machines (14 November 2026)

| Question | Default chosen | Where |
| --- | --- | --- |
| Which machines come over? | V2's images and the user's machines, cloned in once (APFS clones, almost no space); V2's machines that Claude started are left. | [Data › Virtual machines › Import](data.md#import) |
| What about Claude's own machines? | None: V3's Claude uses the user's machines through the `vm_` tools, under a new **Operate virtual machines** (Never, Ask First, Always; Ask First by default). A machine Claude creates is the user's, kept. V2's idle stop, join and Claude token aren't brought over. | [MCP › Virtual machines](mcp.md#tools) |
| Which `vm_` tools? | V2's, without the setup tools (`vm_setup_recovery`, `vm_setup_finish`): the setup is the user's. `vm_create` is new (V2's `vm_start` created machines). No result carries the guest's password. | [MCP › Tools](mcp.md#tools) |
| Where is the setup done? | In the window: an image waiting for setup offers **Set Up…**, and its setup view replaces the image's page, with V2's three steps, Type Password and Finish Setup. V2's Auto Setup chat isn't brought over. | [UI › Virtual Machines › Setup](ui/virtual-machines.md#setup) |
| Where do Pause and Resume come from? | V3's design; the framework's pause and resume, never stored (V2 had none). | [Data › Machine lifecycle](data.md#machine-lifecycle) |
| How is the guest's address found? | A fixed MAC address per machine (`vm.yml`'s `macAddress`, a V3 addition) looked up in macOS's DHCP leases. | [Data › Machine file](data.md#machine-file) |
| What about snapshots, Linux and the CPU figure? | Not on the data folder's machines: the window hides Take Snapshot and the snapshot list for them, and shows three figures; the sample store keeps the design's. | [Future improvements](future-improvements.md#virtual-machines) |
| Where do New Machine's defaults live? | Settings ▸ Virtual Machines, V2's `defaultVMCores`, `defaultVMMemoryGB`, `defaultVMDiskGB` in `settings.yml`. V2's default image isn't brought over (no tool picks an image by itself). | [UI › Virtual Machines › Settings](ui/virtual-machines.md#settings--virtual-machines) |
| How is the agent built and bundled? | Its own package for macOS 12 (`GuestAgent/`), an Xcode tool target signed with the team, copied into `Contents/Helpers` by a script phase; version `3.0`; V2's `setEnv` and the install script's Claude CLI step dropped. | [Guest agent](guest-agent.md) |
| How is image.yml written? | V2's format with mode 0600, since it holds the guest password. | [Data › Image file](data.md#image-file) |
| What does deleting do? | V2's: a machine's or an image's folder is deleted, not moved to the Trash; an image takes its machines with it. Each asks first. | [UI › Virtual Machines › Alerts](ui/virtual-machines.md#alerts) |
