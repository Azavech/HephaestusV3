# Decisions

The design decisions of Hephaestus V3, feature by feature: each open question met while building the app,
answered with the recommended default so that the work goes on. The owner reviews them whenever they like;
the page that applies each one says "default chosen at design time" beside it. The owner's own rules come
first, then the features, in the order they were built: Foundation and Projects on 13 November 2026, the
others on 14 November 2026.

## What Claude reads

On 14 November 2026 the owner set the rule: the app writes everything Claude reads itself. It takes no system
prompts, skills, hook texts or tool descriptions from elsewhere. What it tells Claude says what a tool does and
which rules the app enforces, and never tells Claude how to work.

| Question | Default chosen | Where |
| --- | --- | --- |
| What do the tool descriptions say? | What each tool does and the rules the app enforces, in the app's own words, with no advice to Claude ("ask the user for the name", "set in_progress when you start", "use add_comment to report work"). | [MCP › What Claude reads](mcp.md#what-claude-reads) |
| Does the server send instructions? | No: `initialize` has no `instructions` member. | [MCP › Methods](mcp.md#methods) |
| Is there a ticket template? | No: Claude's descriptions are taken as written, like the user's. | [Data › Ticket rules](data.md#ticket-rules) |
| What does the Chat send the Claude CLI? | No system prompt, skill or hook text: no `--append-system-prompt`, no `--settings` hooks, no plugin. The app's only addition is one line after a message, naming the item its chip carried ("Attached: ticket ORD-142 of project ORD"). No hook is needed for approvals either: the app's MCP server asks the user before a change ([MCP › Permissions](mcp.md#permissions)). | [Data › Launch](data.md#launch), [Data › Messages](data.md#messages) |

## Foundation

| Question | Default chosen | Where |
| --- | --- | --- |
| Where in the App Group container does the data go? | At the container's root, `~/Library/Group Containers/group.fr.azavech.hephaestusv3/`. Since 14 November 2026 the data folder is in Application Support ([Release](#release)). | [Data › Data folder](data.md#data-folder) |
| What happens to the keys the app doesn't use when it writes a file? | They are kept at their place, in the order they were read in, so a file edited by hand keeps its order; the app never adds one. | [Data › Unknown keys](data.md#unknown-keys) |
| How does the app store a project's color? | The name of a tint (`accent`, `accentSecondary`, `info`, `success`, `warning`); a `#RRGGBB` color still reads. | [Data › Project color](data.md#project-color) |
| How does the app store a library? | A fourth `type` value, `library`. | [Data › Project kind](data.md#project-kind) |
| How long may a kubectl command run? | 15 seconds: the commands the app runs are short reads. | [Architecture › ExternalTools](architecture.md#externaltools) |
| Are the data targets' messages localized? | No: they are technical details in English, shown under a window's localized sentence. Rule errors are cases the windows word themselves. | [Data › Validation](data.md#validation) |

## Projects

| Question | Default chosen | Where |
| --- | --- | --- |
| What identifier does a name suggest? | The owner's rule: a name that starts with a capital gives its capitals (`AntiBeeCycle` → `ABC`, `YeenCloud` → `YC`), at most eight; a name with fewer than two capitals, or that starts with another character, its first four letters. | [Data › Ids](data.md#ids) |
| Where does New Project show where the project goes? | One Project Folder row, the full path with Choose…, in both folder modes: the owner found the location row redundant with it. | [UI › Projects › New Project](ui/projects.md#new-project) |
| What does clearing the identifier or the folder name do? | The owner's rule: the field follows the name again from the name's next change. The identifier's message ("Enter an identifier.") still shows while it is empty. | [UI › Projects › New Project](ui/projects.md#new-project) |
| How are outside changes applied? | A batch that matters loads the whole tree again and compares it with memory, rather than handling each path on its own: the projects are few and their files small, and one rule covers renames, moves and dropped events. | [Data › Outside changes](data.md#outside-changes) |
| What does a project whose file became invalid show? | The version loaded before, with a file issue giving the reason. | same |
| Where does the windows' code meet the project data? | ProjectsKit depends on ProjectData, the data target of its own feature, and maps it onto ToolsFoundation's `Project`; the data targets stay free of UI, and ToolsFoundation of data. The plan had ProjectData depend on ToolsFoundation instead. | [Architecture › The package](architecture.md#the-package) |
| How does a `#RRGGBB` color become a tint? | The tint of the nearest hue; a gray, or no color, gives Accent. The app writes the tint's name when the color changes. | [Architecture › ProjectsKit](architecture.md#projectskit) |
| What is the `none` type? | A fourth kind, Other, listed after Libraries as "Other Projects". | [Projects](ui/projects.md) |
| Where does a new project's folder go by default? | Beside the selected project's top-level folder; without a selection, `~/Developer` when it exists, else the home folder. | [Projects › New Project](ui/projects.md#new-project) |
| What shows for entries that don't load? | An Unavailable section at the end of the sidebar, with each reason; the entries can't be selected or removed yet. | [Projects › States](ui/projects.md#states) |
| What does the empty window offer? | New Project… and Add Existing Folder…, since a first launch starts empty. | same |
| What does a tool that isn't available show? | Nothing: its window, tile, menu items, shortcuts and Settings tab are hidden; the previews keep every tool. | [Navigation › Available tools](ui/navigation.md#available-tools) |
| Which shortcut adds an existing folder? | ⌘O, File ▸ Add Existing Folder…, the Mac's Open shortcut; nothing else used it. | [Navigation › Menus and shortcuts](ui/navigation.md#menus-and-shortcuts) |
| Where does a selection go after a removal? | The nearest ancestor still listed, else the first project. | [Projects › Remove Project](ui/projects.md#remove-project) |
| Is Project Settings a section or a window? | A window per project (⇧⌘,), as each tool has its windows. | [Project Settings](ui/project-settings.md) |
| How is the icon chosen? | A text field for the SF Symbol's name, checked against this Mac's symbols, with suggestions as it's typed, and a button showing the icon that opens a searchable symbol picker (the owner asked for both). Both come from AZDesign 0.5.0, which reads the system's own list of symbols, keywords and categories. | same |
| Does a picked suggestion apply at once? | No: it fills the field, which applies on Return or when it loses the focus, as any typed text; a symbol picked in the picker applies at once. | same |
| What does a field show when the window opens before the projects load? | The stored values, once the project loads; until then a text field applies nothing, so an empty field never removes a value. | same |
| What does a namespace or deployment field offer? | A text field with a menu of the cluster's names, as macOS SwiftUI has no combo box; any name can be typed. | same |
| How is the connection to a cluster checked? | By listing its namespaces with the kubeconfig file, which also gives the suggestions. | same |
| What may an inherited environment's Name field do? | Nothing: it shows the parent's name, disabled. | same |
| May a copy of a stored environment skip the write rules? | No: each stored environment keeps at most one equal environment as it is; a copy is checked, so two environments can't share a name. | [Data › Changes](data.md#changes) |
| How does a sub project take its parent's settings? | Field by field, always (the owner's choice, replacing V2's Use parent settings switch, whose key is kept without effect): an empty field takes the parent's value, shown greyed; the parent's environments show in the child, which changes them or adds its own. | [Data › Resolution](data.md#resolution) |
| Which page does an empty GitHub page field give? | The nearest ancestor's typed page, else the origin's page of the project, else of its nearest ancestor: a typed page is a choice, an origin only a guess. | same |
| May an own environment take an inherited environment's name? | No, as in V2; one already in a file stays there, unused. | same |
| Which fields of an inherited environment can change? | All but its name: V3 adds the namespace and the kubeconfig file to V2's changes. | [Data › Environment override](data.md#environment-override) |
| Which settings may a project of any type have? | All of them (the owner's choice); its type still decides its tools (the owner's choice: tools stay by type). | [Project Settings](ui/project-settings.md) |
| Where are the sections a project doesn't show added? | A `+` menu in the window's toolbar, listing them in the form's order; an added section stays while the window is open, then shows only with a value. | [Project Settings › Adding and removing a section](ui/project-settings.md#adding-and-removing-a-section) |
| When does an optional section show? | When the type uses it, the project sets a value of its own in it, or it was added: a value that only comes from the parent or the origin remote doesn't show it, so that every section the type doesn't use can be removed (the owner asked for removal). Once shown, the section shows those values greyed. | same |
| How is a section removed? | Remove in its header, for every section the type doesn't use; it deletes the project's own values in it, in one change, after a confirmation when there are any. Inherited and origin values keep applying. | same |
| What does Enable graph do in V3? | The project overview shows the Service Map's graph of the current environment over the last hour, drawn by the Dashboard's Service Graph widget, and the Dashboard shows its four graph widgets only while it is on, as in V2 (the owner asked for both). Instances doesn't depend on it. | [Projects › Graph](ui/projects.md#graph), [Dashboard](ui/dashboard.md) |
| What does the Service Map tile say without a count of services? | "Services and calls in <n> environments", or "No environment yet": the app's projects have no count until a tool reports one. | [Projects › Tools](ui/projects.md#tools) |
| How does a sub project choose its graph? | A pop-up: "Same as “<parent>”: On/Off", On, Off; a top-level project keeps a toggle, whose off removes the key. | [Project Settings › Fields](ui/project-settings.md#fields) |

## MCP server

| Question | Default chosen | Where |
| --- | --- | --- |
| Which port? | 47830. | [MCP › Overview](mcp.md#overview) |
| Which server name? | `hephaestus`: Claude's tool names are `mcp__hephaestus__<tool>`. | same |
| Which tokens? | The external token, and one token per chat's Claude process, made when it starts. | [MCP › Authentication](mcp.md#authentication) |
| Where do the operations live? | In each kit, beside the window whose functions they call; MCPKit knows no kit and no UI, and ToolsScenes gathers the registry. | [Architecture › MCPKit](architecture.md#mcpkit) |
| What do the results look like? | JSON with the app's names (`folder` for a project's folder, `library` among the types, a tint accepted as `color`); absent values are left out rather than `null`. | [MCP › Tools](mcp.md#tools) |
| What does `open_in_app` open? | What the app has: a project in the Projects window, or its settings; each feature adds its kinds. | [MCP › open_in_app](mcp.md#open_in_app) |
| Where is the port kept? | `settings.yml`, the app's settings file, created with this first setting. | [Data › Settings file](data.md#settings-file) |
| Does Settings show the whole token? | No: its first 8 characters; Copy copies it whole. | [MCP › Settings ▸ MCP](mcp.md#settings--mcp) |

## Tickets and bundles

| Question | Default chosen | Where |
| --- | --- | --- |
| How is a new ticket named? | With a provisional title, kept as the title: the description's first plain line, cut to 60 characters, else `Untitled Ticket`; a bundle with its tickets' titles. Either can be renamed. | [Data › Ticket rules](data.md#ticket-rules) |
| May Claude give a title? | Yes: otherwise the provisional title would be all Claude could give. | same |
| Must a description be written? | Only without a title, to make the provisional title; a ticket with a title may have an empty description. | same |
| Is there a description template? | No (decided on 14 November 2026): it would only steer what Claude writes ([What Claude reads](#what-claude-reads)). Descriptions are free Markdown for the user and Claude alike; the New Ticket sheet has an empty Description field. | same |
| What may Claude do with a draft? | Nothing to its status: Claude neither makes a draft nor changes one, so that "not ready yet" stays the user's call. Claude's new tickets start To Do. | same |
| Do priority and labels add history entries? | No: the history's six kinds of entries cover the creation, the title, the description, the links and the status. | [Data › Ticket changes](data.md#ticket-changes) |
| Which device name goes into the history? | The Mac's computer name (`SCDynamicStoreCopyComputerName`). | [Data › Ticket file](data.md#ticket-file) |
| What happens to copied files when a change fails? | They are removed for every change that copies files, so no unreferenced file stays. | [Data › Ticket changes](data.md#ticket-changes) |
| What about `inverseLinks` and a comment's `answer`? | Runtime values, never stored: they are ignored when read and never written. | [Data › Ticket file](data.md#ticket-file) |
| How does the ticket data follow outside changes? | Through the projects' own stream: `ProjectSession.observeFileEvents` hands each batch to the ticket library, which reads again only the files the batch names. | [Architecture › TicketData](architecture.md#ticketdata) |
| How is a ticket's detail laid out? | In the parts of the design: ticket links join **Linked** (Depends On, Blocks, Related) beside the other tools' items; history and comments share **Activity**; attachments get a section; editing is an **Edit** mode in place of the header. | [UI › Tickets](ui/tickets.md#ticket-detail) |
| What does the Created status write? | `todo`: the windows say Created, the files keep the value `todo`. | [Data › Ticket file](data.md#ticket-file) |
| Which bundles does a ticket show? | All of its project's bundles that hold it, one per line: a ticket can be in several. | [UI › Tickets](ui/tickets.md#properties) |
| Where is New Bundle? | In the sidebar's Bundles header, which always shows, and in a ticket's **Add to Bundle ▸** menu. | [UI › Tickets](ui/tickets.md#sidebar) |
| Who appears in the activity? | "You" and "Claude": the app runs on one Mac, so the device name stays in the file only. | [UI › Tickets](ui/tickets.md#activity) |
| How is Markdown drawn? | Natively, block by block (`MarkdownBlockRenderer`), with each line break kept, since people type plain lines; there are no Markdown markers and no HTML output. | [Text](text.md) |
| Which colors highlight code? | AZDesign's semantic colors, after Dracula's code colors: the workspace allows no hex values in views. | [UI › Tickets](ui/tickets.md#markdown) |
| Where do relative links in a ticket go? | To the project's file, opened in its default app: the app has no documentation viewer. | same |
| Which ticket tools does Claude get? | Sixteen, for tickets, comments, attachments and bundles; `create_ticket` and `update_ticket` take `title`, `priority` and `labels`, and `list_tickets` filters drafts too. | [MCP › Tools](mcp.md#tools) |
| Which attachment paths do results give? | Absolute ones in every result: one ticket JSON everywhere. | same |
| How does a change by Claude reach the windows? | The tool calls the shared `TicketLibrary`, then `TicketSession.refresh()`, so open Tickets windows show it at once rather than at the next file event. | [Architecture › TicketData](architecture.md#ticketdata) |

## Dashboard

| Question | Default chosen | Where |
| --- | --- | --- |
| Where is a Dashboard kept? | In the project file: `dashboardWidgets` and `dashboardGraphWindow`. The proof of concept's user defaults entries are no longer read. | [Data › Dashboard widget](data.md#dashboard-widget), [UI › Dashboard › Saving](ui/dashboard.md#saving) |
| Which environment do the widgets read? | The project's current environment; choosing one on the Dashboard makes it the project's current environment for every window. The proof of concept kept its own per Dashboard. | [UI › Dashboard › Environment and time window](ui/dashboard.md#environment-and-time-window) |
| Which widgets show while their tool isn't available? | None: Project always, the others with their tools. Hidden widgets take no place and keep their stored positions, so the layout comes back whole when their tool does. | [UI › Dashboard › Which widgets show](ui/dashboard.md#which-widgets-show) |
| What about Recent Chats and Cost widgets in a project file? | Kept in the file with their settings and never shown: Recent Builds takes their place, and the app shows no costs. | same |
| Which list does a project without a stored list show? | The default list: Project, Tickets, Recent Builds, and Service Graph for a service. | [UI › Dashboard › Default list and sample layouts](ui/dashboard.md#default-list-and-sample-layouts) |
| What about the sample layouts of Orders and Shop? | Previews and screenshots only: a real project named ORD or SHOP shows the default list. | same |
| What about a stored **Last 7 days** window (`week`)? | Kept when stored, and shown as the last hour. | [Data › Project file](data.md#project-file) |
| What do the Tickets widget's statuses include? | Draft too, for the widgets the app adds; a widget stored without statuses shows To Do, In Progress, In Review and Done, the key's default. | [Data › Dashboard widget](data.md#dashboard-widget) |
| How does a failed change show? | Its message under the toolbar until the next change; the stored list shows again, and the changes queued after it are dropped. | [UI › Dashboard › Applying changes](ui/dashboard.md#applying-changes) |

## Chat on the Claude CLI

| Question | Default chosen | Where |
| --- | --- | --- |
| Which of the CLI's own tools does Claude get in a chat? | None (`--tools ""`), and no MCP server but the app's (`--strict-mcp-config`): Claude reads and changes only through the app's tools, as the Chat's design says ("Nothing it reads or changes goes around them"). To run commands and edit files, Claude Code in a terminal with the app's MCP server does it. | [Data › Launch](data.md#launch) |
| Where do the user's permissions hold? | In the app's MCP server, before each call of a chat's Claude (`ChatGate`), not in the CLI's permission modes: the CLI runs the app's tools without asking (`--allowedTools`), so an allow rule in the user's own Claude Code settings can't skip a card. A chat file's permission mode, Ultracode and context window are kept as read and not used. | [MCP › Permissions](mcp.md#permissions) |
| What does Always mean for deletions? | They ask first anyway; Never refuses them. | same |
| Which permission covers projects? | **Change projects** (Never, Ask First, Always; Ask First by default) beside Change tickets, in Settings ▸ Chat and the inspector: Claude can add, change and remove projects through the MCP tools, which no permission covered. | [UI › Chat › Settings ▸ Chat](ui/chat.md#settings--chat) |
| How does Claude know what a message is about? | One line the app writes after the message: the item of its chip, or the project from the Chat window. It describes the item only. | [Data › Messages](data.md#messages) |
| Which chats does the app list? | Every chat in the projects' `.hephaestus/chats/`, of every kind; the app makes `project` chats, with an `origin` for the panel's. Items the app doesn't show (question pickers, images Claude showed) are skipped. | [Data › Chats](data.md#chats) |
| How is a new chat titled? | The first line of its first message that isn't empty, at most 80 characters, as the Chat's design titled new conversations; `rename_chat` lets Claude rename one when asked. | [Data › Chat file](data.md#chat-file) |
| Where do the model and effort of new chats live? | `settings.yml` (`chatModel`, `chatEffort`), set in Settings ▸ Chat › Replies; each chat keeps its own, set in the inspector. | [Data › Settings file](data.md#settings-file) |
| Does the app read the CLI's models before a chat starts? | Yes: a probe that only answers `initialize` (no session, no tools, no message), after the CLI is found. | [Data › The CLI](data.md#the-cli) |
| How does Stop show? | A **Stop** button (⌘.) on the activity line at the transcript's end, rather than turning Send into Stop, so the composer's Send keeps its one role. | [UI › Chat › Activity](ui/chat.md#activity) |
| Can the user send while Claude works? | No: Send stays disabled during a turn, as the design had it while a reply was coming; Stop ends the turn. | [UI › Chat › Composer](ui/chat.md#composer) |
| What shows of the transcript? | The user's messages, Claude's text (inline Markdown), the calls of the app's tools, the cards, and the app's lines; not thinking, not sub-agents' work, not the end of a turn that went well, no cost. | [UI › Chat › Turns](ui/chat.md#turns) |
| In which language are the app's lines? | English, as stored in the transcript; the rows' and cards' wording is the tools', in the user's language. | [Data › Chat items](data.md#chat-items) |
| How many transcripts stay in memory? | Those of chats open in a window and of running chats, plus at most 12 others, the oldest read dropped first (keep RAM low). | [Data › Chat transcript file](data.md#chat-transcript-file) |
| What happens to the sample engine? | It stays for previews and the documentation's captures only. | [UI › Chat › Samples](ui/chat.md#samples) |

## Builds

| Question | Default chosen | Where |
| --- | --- | --- |
| What names a run? | GitHub's id (`databaseId`), which is unique; routes, `get_run` and the window use it, and the window shows the run's `number` (`#641`), as GitHub does. A run's number repeats across workflows. | [Data › Builds](data.md#builds) |
| How are releases read? | `gh api …/releases?per_page=50`, which gives notes and files in one call, so the Assets column needs no call per release; `gh release list` tells the latest. | [Data › gh calls](data.md#gh-calls) |
| Where do step logs come from? | `gh run view --log --job=<id>`, read when a step is picked, kept until the window's next read of that run; a job's log exists once it has completed. | [UI › Builds › Step log](ui/builds.md#step-log) |
| How are re-runs offered? | One **Re-run** button: it runs all jobs; with failed jobs it is a menu button whose click re-runs the failed ones and whose menu offers both; Cancel Run takes its place while the run is queued or running. | [UI › Builds › Run details](ui/builds.md#run-details) |
| What may Claude do in Builds? | Read runs, jobs, logs and releases (seven tools); re-run and cancel under **Start builds** (Never by default, or Ask First); no downloads. | [MCP › Permissions](mcp.md#permissions) |
| When does the Dashboard's Recent Builds read? | When it shows, then every 30 s, as the window. | [UI › Dashboard](ui/dashboard.md) |
| What does the chat's reader read? | Each tool's own data, as the tool's window reads it. | [UI › Chat › How Claude reaches the tools](ui/chat.md#how-claude-reaches-the-tools) |
| What about the Projects window's Builds tile and activity? | They keep the samples' text for sample projects, and "Workflow runs and releases on GitHub" otherwise: reading every project's runs for a tile would call gh for each project. | [UI › Projects](ui/projects.md) |

## Contracts

| Question | Default chosen | Where |
| --- | --- | --- |
| Which file is a project's contract? | `openapi/contract.yaml` of its folder, for a service; other OpenAPI files of a project wait for the Code editor ([Future improvements](future-improvements.md#new-tools)). | [Data › Contracts](data.md#contracts) |
| How are operations named? | By `operationId` in the window and routes, by `<METHOD> <path>` in the stored values and `api_call`, so that the gate reads the method from it. | [MCP › api_call](mcp.md#api_call) |
| Which environment do requests go to? | The project's current environment, which picking one in the window changes. | [UI › Contracts › Environment and Send](ui/contracts.md#environment-and-send) |
| What is stored? | The credentials and added headers, in `openapi-requests.json`; the parameters and bodies typed stay while the operation is selected, as the design had it. | [Data › Stored values](data.md#stored-values) |
| Where are credentials typed? | A **Credentials and Headers** sheet from the toolbar (`key`), since the design's request box has no room for them. | [UI › Contracts › Credentials and headers](ui/contracts.md#credentials-and-headers) |
| Which media type does the body use? | The operation's first; the window shows one body editor. Claude's `api_call` may name another. | same |
| What may Claude call? | `GET` and `HEAD` always; other methods under **Call APIs that change data** (Never, Ask First, Always; Ask First by default). | [MCP › Permissions](mcp.md#permissions) |
| Are responses kept? | While the app runs, per operation; never written. | [UI › Contracts](ui/contracts.md) |
| Does the window show schema trees, the contract's Info or a Quick Look of binary bodies? | No: the window shows operations, the request and the documented responses; a binary body reads "Binary body (<size>)". | same |

## Service Map, Kubernetes and Argo CD

| Question | Default chosen | Where |
| --- | --- | --- |
| Which node kinds does a live map have? | Services, their postgres databases, and their buckets as external services; gateways, workers and queues stay for the samples, since the services' sources don't tell them. | [Data › Service map](data.md#service-map) |
| How often does the map read? | 5 s after each read, while **Live** is on; once per change of environment or window when it is off. | [UI › Service Map › Toolbar](ui/service-map.md#toolbar) |
| Which time windows? | 5 min, 1 hour and 24 hours. | same |
| Where do the logs come from? | The span events with `log.level` of the window's requests; pod logs are Claude's `k8s_logs`. | [Data › Calls and requests](data.md#calls-and-requests) |
| Which actions does the user get? | Restart, Scale and Argo CD Sync in the own service's details, each confirmed first; port forwards stay Claude's (and Jaeger's), with no window of their own yet. | [UI › Service Map › Service](ui/service-map.md#service) |
| What may Claude do? | Read deployments, logs, events, Argo CD, the map and a request; restart, scale, sync and forward ports under **Operate deployments** (Never, Ask First, Always; Ask First by default). The external token may call these tools too, as every tool. | [MCP › Permissions](mcp.md#permissions) |
| Which project's environments? | The tools take a `projectID` and an `environment`, since the app's tools aren't tied to a chat's project. | [MCP › Tools](mcp.md#tools) |
| What about the status line? | A bar over the graph shows reading, a failure, or the sources' and Jaeger's problems. | [UI › Service Map › States](ui/service-map.md#states) |

## Virtual machines

| Question | Default chosen | Where |
| --- | --- | --- |
| What about Claude's own machines? | None: Claude uses the user's machines through the `vm_` tools, under **Operate virtual machines** (Never, Ask First, Always; Ask First by default). A machine Claude creates is the user's, kept. | [MCP › Virtual machines](mcp.md#tools) |
| Which `vm_` tools? | None for the setup, which is the user's: `vm_create` creates a machine, `vm_start` starts one, and the others read and operate it. No result carries the guest's password. | [MCP › Tools](mcp.md#tools) |
| Where is the setup done? | In the window: an image waiting for setup offers **Set Up…**, and its setup view replaces the image's page, with its three steps, Type Password and Finish Setup. | [UI › Virtual Machines › Setup](ui/virtual-machines.md#setup) |
| Where do Pause and Resume come from? | The design; they are the framework's pause and resume, never stored. | [Data › Machine lifecycle](data.md#machine-lifecycle) |
| How is the guest's address found? | A fixed MAC address per machine (`vm.yml`'s `macAddress`) looked up in macOS's DHCP leases. | [Data › Machine file](data.md#machine-file) |
| What about snapshots, Linux and the CPU figure? | Not on the data folder's machines: the window hides Take Snapshot and the snapshot list for them, and shows three figures; the sample store keeps the design's. | [Future improvements](future-improvements.md#virtual-machines) |
| Where do New Machine's defaults live? | Settings ▸ Virtual Machines: `defaultVMCores`, `defaultVMMemoryGB`, `defaultVMDiskGB` in `settings.yml`. There is no default image: no tool picks an image by itself. | [UI › Virtual Machines › Settings](ui/virtual-machines.md#settings--virtual-machines) |
| How is the agent built and bundled? | Its own package for macOS 12 (`GuestAgent/`), an Xcode tool target signed with the team, copied into `Contents/Helpers` by a script phase; version `3.0`. | [Guest agent](guest-agent.md) |
| How is image.yml written? | With mode 0600, since it holds the guest password. | [Data › Image file](data.md#image-file) |
| What does deleting do? | A machine's or an image's folder is deleted, not moved to the Trash; an image takes its machines with it. Each asks first. | [UI › Virtual Machines › Alerts](ui/virtual-machines.md#alerts) |

## Window tabs

The owner asked, on 17 November 2026, that windows can share one window's tabs, with Merge All Windows in the
Window menu as in Safari, and leave them again. Seeing macOS's tabs, the owner then asked that a tab hold its
sidebar, under the tab bar, and that one chat panel sit on the right of the window, outside the tabs, for every
tab. They chose the app's own tabs over macOS's, a chat panel that shows the selected tab's project's
conversation, and a panel shown by default that ⌃⌘C still hides.

| Question | Default chosen | Where |
| --- | --- | --- |
| What can a tab show? | Projects, a tool for a project, a project's settings, Virtual Machines: everything the windows showed. Projects, Virtual Machines and each Project Settings are one tab in the app. | [UI › Navigation › Windows](ui/navigation.md#windows) |
| What does a tab read? | The tool, then the project's name ("Tickets – Orders"), and "Project Settings – Orders"; Projects and Virtual Machines their name. | [UI › Navigation › Tabs](ui/navigation.md#tabs) |
| How does a tab keep its state while another is in front? | Only the selected tab is drawn; a tool's tab keeps its tool's model, so its selection, filters and drafts stay, while scroll positions start afresh. Keeping every tab drawn would put every tab's toolbar items in the window's toolbar, and SwiftUI's `TabView` shows its own tab picker in the toolbar. | same |
| When does the tab bar show? | With two tabs or more (the user's choice); a single tab's content goes under the toolbar. | [UI › Navigation › Tabs](ui/navigation.md#tabs) |
| What do + and New Tab (⌘T) make? | Another tab of the selected tab's tool and project. None in Projects, Project Settings and Virtual Machines. | same |
| How do tabs leave a window? | Move Tab to New Window, from the Window menu or a tab's context menu, or a tab dragged 48 points out of the bar. Tabs don't move between windows by dragging: Merge All Windows gathers them. | same |
| What do ⌘W and ⇧⌘W do? | Close Tab and Close Window, as in Safari; SwiftUI's Close is taken out. | [UI › Navigation › Menus and shortcuts](ui/navigation.md#menus-and-shortcuts) |
| Where are the tab items? | The app's own, under macOS's names and shortcuts: Show Previous Tab (⌃⇧⇥), Show Next Tab (⌃⇥), Move Tab to New Window and Merge All Windows, after Bring All to Front. | same |
| What does the chat panel show in a tab without a project? | The last project the window showed; with none, "No Project". The Dashboard is the origin of messages sent from Projects, Project Settings and Virtual Machines. | [UI › Chat › Chat panel](ui/chat.md#chat-panel) |
| Do new tabs go into the front window? | Yes by default (the user's choice): Settings ▸ General ▸ **Open new windows**, stored in `settings.yml`'s `newWindows`, for what routes open. | [UI › Navigation › Settings ▸ General](ui/navigation.md#settings--general) |
| Where is that setting? | A General tab, first in Settings, since it concerns every window. | same |

## App icon

The owner asked for an icon on 17 November 2026.

| Question | Default chosen | Where |
| --- | --- | --- |
| What does it show? | A hammer striking an anvil, with sparks: Hephaestus's forge. Light metal and an Orange handle on a gradient from Alucard Purple to Dracula Background, with Orange, Yellow and Pink sparks. | [UI › Foundations › App icon](ui/foundations.md#app-icon) |
| In which format? | An Icon Composer document of three SVG layers, so that macOS draws it in Liquid Glass and makes its dark, clear and tinted versions. | same |

## Feedback

The owner asked on 17 November 2026 for V2's ladybug, sending a feedback ticket that is a regular ticket, not
an item of its own. They chose V2's status bar at the bottom of every window, holding only the ladybug, and a
feedback project set in Settings, without which the ladybug doesn't show.

| Question | Default chosen | Where |
| --- | --- | --- |
| What does Send make? | A ticket as New Ticket makes it without a title, in the feedback project: its title is the description's first line, and Save as Draft starts off (the user's choice). The screenshot and the added files become its attachments. No chat, no Claude. | [UI › Tickets › Feedback](ui/tickets.md#feedback) |
| Where does it say what the feedback is about? | A context line after the description: the app's version, macOS, the window, its project and its selected item. V2's device has no counterpart. | [UI › Tickets › Context line](ui/tickets.md#context-line) |
| What follows Send? | The ticket opens in the feedback project's Tickets window, as V2 showed its feedback chat. | [UI › Tickets › Feedback](ui/tickets.md#feedback) |
| What if the files can't be attached? | The ticket stays, without them; the sheet says so and offers Show Ticket, so no second ticket is made. | same |
| Which windows have the status bar? | Every window but Settings and the menu bar panel, and none while no feedback project is loaded: the bar only holds the ladybug. | [UI › Navigation › Status bar](ui/navigation.md#status-bar) |
| How is the window captured? | V2's in-process capture, without its web-view step; a PNG over 5,000,000 bytes is made again at 1 pixel per point. | [UI › Tickets › Screenshot](ui/tickets.md#screenshot) |
| Where is the setting stored? | `settings.yml`'s `feedbackProjectID`, the name of V2's earlier setting. | [Data › Settings file](data.md#settings-file) |

## Release

The owner chose a GitHub release built by GitHub Actions, without an install page, an updater, Developer ID signing
or notarization.

| Question | Default chosen | Where |
| --- | --- | --- |
| When does a release build? | Only when asked (Actions ▸ Release, with the version): a push to `main` releases nothing. | [Release › Running a release](release.md#running-a-release) |
| How are versions numbered? | The version is the workflow's input; the build is the commit count. | [Release › Build script](release.md#build-script) |
| How is the app signed? | Ad-hoc, with its entitlements, agent first. | same |
| How does the runner fetch AZDesign? | A read-only deploy key of AZDesign, stored as the secret `AZDESIGN_DEPLOY_KEY`. | [Release › Setup](release.md#setup) |
| Is there CI on pushes? | No: only a release runs the tests on the runner. | [Release](release.md) |
| Where is the data folder? | `~/Library/Application Support/HephaestusV3/`, by the owner's choice: an ad-hoc signed copy can't use the App Group container. Its data is copied once from there by a development build. | [Data › Data folder](data.md#data-folder) |
