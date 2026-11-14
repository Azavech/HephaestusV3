# Chat

Chat is where the user asks Claude about a project. Claude is one more client of the tools, never their center: it reads items only through each tool's read function, every read shows in the conversation with an **Open** button, and it asks before it changes anything (the user's principle). Chat appears in two places (the user's choice). The **Chat window** is a tool window like the others: it lists every conversation of a project and shows one with an inspector. The **chat panel** sits beside every other tool window and asks about the item that tool has selected. Both show the same conversations, from one shared store. Claude replies through the Claude CLI on this Mac: each conversation is a chat of the project, kept in its `.hephaestus/chats/` as HephaestusV2 kept them, V2's chats included ([Data › Chats](../data.md#chats)). Claude has none of the CLI's own tools (no shell, no file edits, no web): it reads and changes only through the app's tools, over the MCP server, and the user's permissions decide what it may change without asking.

![The Chat window for Orders: the conversation list, the checkout conversation with four reads and an approval card, and the inspector](images/chat-light.png)
*The Chat window for Orders, light appearance. Claude's reply lists what it read through Service Map, Tickets and Builds, each with Open, then asks to comment on ORD-142.*

![The same window in the dark appearance](images/chat-dark.png)
*The same window in the dark appearance.*

## Opening it

| From | How | Result |
|---|---|---|
| Projects window | **Open** on the **Chat** tile of the project's Tools section. The tile reads "Ask Claude, which reads through these tools". | The project's Chat window. Every project kind offers Chat, last in tool order. |
| Window menu | **Chat**, ⌘6 | The Chat window for the key window's project. Disabled when the key window has no project. |
| Menu bar panel | ⌘6 for the highlighted project, or the Chat button of the row under the pointer | The Chat window for that project. |
| Project switcher | Pick another project in the Chat window's toolbar | The same window switches project and drops its focus. |
| Chat panel | **Open in Chat Window** (`macwindow`) in the panel's header | The project's Chat window, with the panel's conversation selected. |

The route is `.tool(.chat, project:, focus:)`. The focus is a conversation id, such as `chat-checkout`. Without a focus, or with one that isn't a conversation of the project or its sub projects, the window selects the latest conversation of the project and its sub projects. If a Chat window already shows the project, it comes forward, un-minimized, and selects the focus without starting afresh: the draft, the list's grouping and the inspector stay as they are. A second route to the same conversation selects it again, even after the user picked another. A focus the list doesn't have leaves the selection as it is. See [navigation.md](navigation.md) for window reuse.

The window opens at 1180 × 780 pt and gets no smaller than 390 × 420 pt. Its title is **Chat**; its subtitle is the project's path, such as `Shop › Orders`.

## Anatomy

| Region | Contents |
|---|---|
| Conversation list | The conversations of the project and its sub projects, latest first, grouped by project for a parent. |
| Transcript | The selected conversation's turns: messages, tool-call rows, approval cards, and the reading indicator while a reply is coming. |
| New-chat prompt | In place of the transcript when no conversation is selected: what to ask, and suggestions. |
| Composer | Under the transcript or prompt: the chips the message carries, the field, and **Send**. |
| Inspector | What the conversation read or attached, what Claude may do, and which model replies. |

On a Mac the list is the split view's sidebar column, the transcript (or prompt) over the composer fills the center, and the inspector is a trailing column. The center column has the `canvas` background.

## Toolbar

| Item | Control | Symbol | Shortcut | Behavior | Layouts |
|---|---|---|---|---|---|
| Project switcher | `ProjectSwitcher`, leading (see [components.md](components.md)) | Project icon | — | Switches this window's project and clears its focus. | Mac, iPad, iPhone |
| Title and subtitle | Window title | — | — | **Chat** and the project's path. Dropped below 760 pt wide. | Mac, iPad |
| Sidebar | The split view's own button | System | System | Shows or hides the conversation list. | Mac, iPad |
| **New Chat** | Button | `square.and.pencil` | ⇧⌘N (File ▸ New Chat) | Clears the selection and the draft, and shows the new-chat prompt in place. In the iPhone layout it opens the prompt as a page. Help: "New Chat (⇧⌘N)". | Mac, iPad, iPhone |
| **Inspector** | Button | `sidebar.right` | — | Shows or hides the inspector. In the iPhone layout it opens the inspector as a sheet. Help: "Show Inspector" or "Hide Inspector". | Mac, iPad, iPhone |

The Chat window has no chat panel and no chat panel button. Its `sidebar.right` button belongs to the inspector.

## Conversation list

- **Rows.** Each row shows the conversation's title on one line, then a caption in `textSecondary`: the date of its last turn (day, abbreviated month, hour and minute) and, for a conversation started in a tool's panel, "· from *Tool*" (for example "· from Builds"). The date and the origin are one sentence for translators. A row reads as one element.
- **Order.** Latest first, by the date of the last turn. A new message moves its conversation to the top.
- **Grouping.** For a project with sub projects, the list has one section per project that has conversations, in tree order, the project itself first. Each header shows the project's icon and name, and is a heading for VoiceOver. For a project without sub projects, the rows are not grouped.
- **Selection.** Single selection. The selected conversation shows in the transcript. The list column is 220 to 340 pt wide, 260 pt ideally.
- **Empty.** When neither the project nor its sub projects have a conversation, the list shows "No Chats" with the Chat symbol (`bubble.left.and.text.bubble.right`) and "Ask a question to start one."
- There is no context menu, no drag, no rename and no delete.

## Transcript

The transcript scrolls. A short conversation starts at the top. A long one opens on its end and follows new turns as they arrive. It has 24 pt of padding, or 16 pt in the iPhone layout.

### Turns

Turns have no bubbles. Each turn starts with an author row: a circular badge, 24 pt and scaled with Dynamic Type, then the author's name in headline weight. The name is a heading for VoiceOver, so the rotor steps from turn to turn.

| Author | Badge symbol | Badge color | Name |
|---|---|---|---|
| The user | `person.fill` | `info` | **You** |
| Claude | `sparkle` | `accentSecondary` | **Claude** |

Under the name, in order:

1. **Attachments.** The items the user's message carried, as chips (tool symbol and title; tooltip "*Tool*: *title*").
2. **Blocks.** Text, tool-call rows and approval cards, in the order Claude produced them. Text is selectable.

Claude's text is Markdown, shown inline: emphasis, code and links, line breaks kept. The user's text shows as written. In previews, a reply of the sample engine adds a **Sample reply** caption after **Claude**, with the tooltip "No model is connected yet: the reply comes from the example's sample engine."

A turn of the user's is one message. Everything after it until the next message is one turn of Claude's: its text, its calls, its cards and the app's notices, in order. Claude's thinking, the work of its sub-agents (in V2's chats) and the end of a turn that went well don't show.

### Tool-call rows

Each call Claude makes to one of the app's tools shows as one row on a `surfaceSunken` card: the tool's symbol in `accent`, the action as the tool words it, and, on the same line, the detail in `textSecondary`, truncated at the end, with the full text as tooltip. The tool words the action in the user's language; Claude never reads it ([MCP › Tools](../mcp.md#tools)).

| Call | Action | Detail | Open |
| --- | --- | --- | --- |
| `get_ticket` | Read ticket ORD-142 | The ticket's one-line answer from Tickets, as it is now: title · status · priority | The ticket |
| `list_tickets`, `list_bundles` | Listed the tickets of ORD; Listed the bundles of ORD | — | The project's Tickets window |
| `get_bundle` | Read bundle ORD-B2 | — | Tickets, on the bundle |
| A ticket or bundle change | Commented on ORD-142; Moved ORD-142 to In Progress; Created a ticket in ORD; Changed ORD-142; Deleted ORD-142… | — | The ticket |
| `list_projects`, `get_project`, a project change | Listed the projects; Read project ORD; Added the project Web; Changed the settings of ORD; Removed ORD from Hephaestus | — | None |
| `list_chats`, `get_chat`, `rename_chat` | Listed the chats of ORD; Read a chat; Renamed a chat “…” | — | The project's Chat window, for the list |
| The Builds tools | Listed the runs of ORD; Read a run of ORD; Read the log of a run of ORD; Re-ran the failed jobs of a run of ORD; Cancelled a run of ORD; Listed the releases of ORD; Read release v1.4.0 | The run's one-line answer from Builds | The run or the release in Builds |
| `open_in_app` | Opened a window of Hephaestus | — | None |
| A tool of the CLI (in V2's chats) | Used Bash | Its result's first line when it failed | None |

- A call that failed (its result is an error, a refusal included) shows `exclamationmark.triangle` and its error's first line in `danger`.
- **Open** opens the item in its tool's window, with the item selected: the route `.tool(tool, project:, focus:)`; a window already showing it comes forward. Help: "Open ORD-142 in Tickets". A call without an item has no **Open**.
- For VoiceOver the row is one element: its label is the action, its value the detail; with an item, it is a button whose hint is the help text and whose action opens the item.

### Approval cards

A change Claude wants to make shows as a card, when the user's permissions say Ask First ([Inspector](#inspector), [MCP › Permissions](../mcp.md#permissions)). Nothing changes until the user answers: Claude's call waits.

- **Title.** `hand.raised.fill` in `warning`, then the request as one sentence, worded by the tool, so that a translation orders the words as its language needs. The title is a heading for VoiceOver.

  | Change | Sentence |
  | --- | --- |
  | `add_comment` | Claude wants to comment on ORD-142 |
  | `create_ticket` | Claude wants to create a ticket in ORD |
  | `update_ticket` | Claude wants to change ORD-142 |
  | `set_ticket_status` | Claude wants to move ORD-142 to In Progress |
  | `update_comment`, `delete_comment` | Claude wants to change a comment on ORD-142; Claude wants to delete a comment on ORD-142 |
  | `remove_attachment` | Claude wants to remove an attachment from ORD-142 |
  | `delete_ticket` | Claude wants to delete ORD-142 |
  | The bundle tools | Claude wants to create a bundle in ORD; … to change bundle ORD-B2; … to move bundle ORD-B2 to Done; … to delete bundle ORD-B2 |
  | `create_project`, `update_project`, `remove_project` | Claude wants to add the project Web; Claude wants to change the settings of ORD; Claude wants to remove ORD from Hephaestus |
  | `rerun_run`, `cancel_run` | Claude wants to re-run a run of ORD; Claude wants to re-run the failed jobs of a run of ORD; Claude wants to cancel a run of ORD |
  | A tool of the CLI (its own request) | Claude wants to use Write |

- **Preview.** What it would write, selectable, at most 20 lines, on a `surfaceSunken` box: a comment's text; a new ticket's title and description; a ticket change's new title, priority, labels and description; a bundle's title and tickets; a project's identifier and folder, or the settings it changes; for a removal, "The project's folder and files stay on this Mac."; for a request of the CLI, its input as JSON. None for a deletion or a status change.
- **Note.** The tool's symbol and "Through *Tickets*, as if you did it" (Projects, with `folder`, for a project's change); "Through the Claude CLI" for a request of the CLI.
- **Answer.** **Don't Allow** and **Allow** (prominent). After the answer, the buttons give way to **Allowed** (`checkmark.circle.fill`, `success`) or **Not Allowed** (`xmark.circle`, `textSecondary`). Allow lets the call run; Don't Allow refuses it, and Claude reads "The user didn't allow this call." Stop, the CLI's end and quitting refuse the cards still waiting.
- **Outline.** `warning` at 50 % opacity while the card waits; `divider` once answered.
- The note and the answer share one line when they fit and stack when they don't.
- The answer is written in the chat's transcript, with this Mac's name ([Data › Chat items](../data.md#chat-items)): a card answered stays answered.

### Notices

The app's lines in a conversation, from the chat's transcript ([Data › Chat items](../data.md#chat-items)), each a `Label` in callout size: `info.circle` in `textSecondary` (Stopped by the user., Conversation compacted…), `exclamationmark.triangle` in `warning` (the app's tools unavailable, a session not found, a setting the CLI refused), `xmark.octagon` in `danger` (Claude couldn't start, exited, or its turn ended in an error, with the CLI's reason). Their text is selectable, in English as stored (V2 stored its lines so).

### Activity

While Claude works, the transcript ends with a **Claude** row showing a small progress indicator and what it does (`chat.responding`):

| Chat | Text |
| --- | --- |
| The CLI starts | Starting Claude… |
| A turn runs | Claude is working… 0:12 (minutes and seconds since the turn began, counting) |
| The CLI compacts the conversation | Compacting the conversation… 0:12 |
| A card waits | Waiting for your answer |
| A sample reply on its way (previews) | Reading… |

**Stop** (`stop.circle`, borderless, ⌘.) follows the text, except for the samples: it refuses the cards waiting, writes "Stopped by the user.", and interrupts the CLI, which ends the turn ([Data › Stop, end and quit](../data.md#stop-end-and-quit)). Help: "Stop (⌘.)".

## Composer

The composer is a card at the bottom of the center column, with 16 pt of padding around it, or 12 pt in the iPhone layout. Its outline is `focus` while the field has focus, `divider` otherwise.

- **Chips.** In the Chat window, the project's chip: its icon and name. It can't be removed. Messages from the Chat window carry no attachments; items they name are read instead (see [Mentions](#mentions)).
- **Field.** Plain, one to eight lines, then it scrolls. Prompt: "Ask about *Orders*…". It takes focus when the composer appears.
- **Send.** A round, prominent button with `arrow.up`. Disabled while the field is empty or only whitespace, and while Claude works in the conversation. Help: "Send (Return)".
- **Not sent.** When a message can't be sent, the reason shows over the composer in `danger`, with `exclamationmark.triangle.fill` (`chat.failure`), and the draft stays: "Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat.", "<path> is not an executable file.", "The Claude CLI isn't checked yet. Try again in a moment." The next message sent clears it.
- **Keyboard.** **Return** sends. **⌥Return** starts a new line.

Sending adds the message to the selected conversation. With no conversation selected, it starts one: a chat of the window's project, titled with the message's first line that isn't empty, at most 80 characters, with no origin. The new conversation is selected and the draft clears once the message is sent. A message from the Chat window carries the project: Claude reads "Attached: project ORD" after it ([Data › Messages](../data.md#messages)). The draft is kept when the user picks another conversation, and when a suggestion is sent.

## New chat

The new-chat prompt replaces the transcript when no conversation is selected: after **New Chat**, or when the project has no conversations.

![A project with no chats: the list's empty state, the new-chat prompt and an empty inspector](images/chat-new.png)
*AZDesign has no chats yet. The list shows its empty state and the prompt offers two questions.*

Centered, it shows:

1. The Chat symbol in large title size, in `accent`.
2. "Ask about *AZDesign*", title 2, semibold, a heading for VoiceOver.
3. "Claude reads through the tools, and asks before it changes anything. Name a ticket, a run or a request to point at it."
4. Two suggestions, as outlined capsule buttons in `accent`: **What changed this week?** and **What needs my attention?**

A suggestion sends at once and starts the conversation; the draft stays as it is. When the largest text sizes need more room than the window has, the prompt scrolls.

## Inspector

A grouped form in a trailing column, 260 to 400 pt wide, 300 pt ideally.

| Section | Contents |
|---|---|
| **In This Chat** | Every item the conversation attached or read, in the order it first came up. Each row: the tool's symbol, the item's title, the tool's name as a caption, and **Open**, which opens the item in its tool's window (help "Open *item* in *Tool*"). An item seen in two Service Map environments has a row for each. With none: "Items Claude reads or you attach show here." |
| **Claude Can** | **Read tickets, services, contracts and builds**: Always (fixed text). **Change tickets**: Never, Ask First or Always; Ask First by default. **Change projects**: Never, Ask First or Always; Ask First by default. **Start builds**: Never or Ask First; Never by default. Footer: "Claude acts through each tool, as you would. Nothing it reads or changes goes around them." The same settings as [Settings ▸ Chat](#settings--chat). |
| **Replies** | **Model**: a pop-up of the CLI's models (Default, Opus, Fable, Sonnet, Haiku until the CLI answers). **Effort**: Low, Medium, High, Extra High, Max, the levels the model has; hidden for a model without one. For the selected conversation, its own; with no conversation selected, those of new chats. A change applies to the running CLI at once. In previews: **Model**: None connected, and "Replies are samples until a model is connected." |

The permissions are stored in the user defaults (`chat.ticketChanges`, `chat.projectChanges`, `chat.buildStarts`) and the MCP server applies them to every chat's calls ([MCP › Permissions](../mcp.md#permissions)): Always runs the change, Ask First shows a card and waits, Never refuses it. A deletion (a ticket, a bundle, a comment, an attachment) or a project's removal asks first even under Always. **Start builds** covers re-running and cancelling runs: Never refuses them, Ask First shows a card.

## How Claude reaches the tools

Claude reaches a tool only through that tool's operations, the same functions the tool's window calls, served by the app's MCP server (the user's principle). ChatKit imports no tool. ToolsScenes, the only target that knows every tool, gives the chat the tools' wording of each call, and every window a `toolReader` for the rows' details.

1. **A tool says what is selected.** A tool window reports its selected item as a reference (tool, project, focus, title, and for the Service Map the environment on screen) through `reportChatSubject`. The window keeps it for its chat panel. The chat never looks into the tool's window.
2. **The message carries it.** Sent from the panel, the item travels with the message as a chip; from the Chat window, the project. Claude reads one line after the message's text, such as "Attached: ticket ORD-142 of project ORD" ([Data › Messages](../data.md#messages)).
3. **Claude calls the tools.** It reads and changes through the app's MCP tools (`get_ticket`, `add_comment`…), as any client of them would; it has no other tools.
4. **The call shows.** Each call becomes a tool-call row with **Open**, and its item is listed under **In This Chat**.
5. **Changes ask first.** A change the user's permissions set to Ask First shows as an approval card; Claude's call waits for the answer.

The panel also reads its attached item before the first message, through `toolReader`, only for the tool's questions, which it offers as suggestions (see [What it asks about](#what-it-asks-about)).

| Tool | Read function | Focus | Detail of a row |
| --- | --- | --- | --- |
| Tickets | `TicketsReader.read(_:)` | Ticket id: `ORD-142` | Title · status · priority |
| Service Map | `ServiceMapReader.read(_:environment:project:)` | `service:<name>` or `request:<id>` | Service: environment · health · p95 · error rate · ready pods. Request: environment · method and path · status and duration · number of services. |
| Builds | `BuildsReader.read(_:project:)` | Run number, or `release:<tag>` | Title · status · workflow on branch; title · Latest or Pre-release · published date |
| Contracts | `ContractsReader.read(_:project:)` | operationId: `createOrder` | Method and path · summary · contract title and version |
| Dashboard, Chat | None | — | — |

Today the app's MCP tools are those of Projects, Tickets, Chat and Builds; the Service Map and Contracts bring theirs in their phases, and their panels show only once those tools are available. Tickets and Builds read the app's data; the Service Map and Contracts readers answer from their samples until then.

### Samples

Previews and the documentation's captures run on sample conversations and a sample engine instead of the CLI. The sample engine reads what a message attaches or names through the tools, then says it can't answer: a ticket id whose letters are a project's id (ORD-142), `req-` and four hexadecimal digits (req-8f3a), "run" and a number (run 1288), in that order after the attachments, each item once.

- With reads: "No model is connected to this example yet, so I can't answer. Above is what I read through the tools; a connected model would answer from it."
- Without: "No model is connected to this example yet, so I can't answer. Attach an item, or name one such as ORD-142, run 1288 or req-8f3a, and I'll show what I would read through its tool."

## States

| State | When | What shows |
| --- | --- | --- |
| Conversation | A conversation is selected. | Its transcript over the composer. |
| New chat | **New Chat**, or no conversation selected. | The new-chat prompt over the composer. |
| No chats | The project and its sub projects have no conversation. | "No Chats" in the list; the new-chat prompt. |
| Starting | The CLI was started for the message. | "Starting Claude…" and **Stop**; **Send** disabled. |
| Working | Claude works on the messages. | "Claude is working… m:ss" and **Stop**; the text Claude writes grows as it streams. |
| Compacting | The CLI compacts the conversation. | "Compacting the conversation… m:ss" and **Stop**. |
| Waiting for your answer | A card waits. | The card's **Don't Allow** and **Allow**, `warning` outline; "Waiting for your answer" and **Stop**. |
| Approval answered | The user answered, or Stop refused it. | **Allowed** or **Not Allowed**; `divider` outline. |
| Error | The CLI couldn't start, didn't start within 60 s, or exited during the turn. | The error notice; the next message starts the CLI again. |
| Not sent | The CLI isn't available. | The reason over the composer; the draft kept. |
| Sample reply | A reply from the sample engine (previews). | **Sample reply** after **Claude**. |
| Nothing in this chat | The conversation read and attached nothing, or none is selected. | "Items Claude reads or you attach show here." in the inspector. |
| No project | The window was restored without a known project. | "No Project", `folder`, "Open this window from the Projects window." |

## Layouts

The window measures its width and picks a layout; see [foundations.md](foundations.md) › Layout system. The Chat window needs 960 pt for its Mac layout: below that, beside the list and the inspector, the conversation would get too narrow. Each time the layout changes, the list and the inspector take that layout's default visibility.

| Layout | When | What changes |
|---|---|---|
| Mac | 960 pt and wider | List, conversation and inspector side by side; the list and the inspector show. |
| iPad | 640 to 959 pt | The list folds away behind the sidebar button and the inspector hides behind **Inspector**. The conversation fills the window. One side column shows at a time, so the conversation keeps its room: opening the inspector folds the list, and showing the list closes the inspector. |
| iPhone | Narrower than 640 pt | One pane at a time. The list fills the window, with nothing selected, when the window opens at this width; a conversation opens as a page with Back. **New Chat** opens the prompt as a page, which becomes the conversation once sent. The inspector opens as a sheet, at least 360 × 480 pt, with **Done** (Return). Transcript padding is 16 pt, composer padding 12 pt. A window opened on a conversation starts on its page. A window that narrows to this width keeps its selection and shows that item's page, as a collapsing split view does ([Foundations › Layout system](foundations.md#layout-system)). |

Below 760 pt the toolbar also drops the window's title; the project switcher names the project.

![The Chat window in the iPad layout](images/chat-pad.png)
*At 820 pt the list folds away and the inspector hides; the conversation fills the window.*

![The Chat window in the iPhone layout, on its list](images/chat-phone-list.png)
*In the iPhone layout the list of chats fills the window, with "from Builds" and "from Tickets" origins.*

![A conversation as a page in the iPhone layout](images/chat-phone-page.png)
*A conversation opens as a page over the list, with Back.*

## Chat panel

The Chat window has no panel of its own. This section specifies the panel that every other tool window (Dashboard, Tickets, Service Map, Contracts, Builds) can show beside its tool. The panel asks about the item the tool has selected. Its conversations are the Chat window's too: they appear in its list, "from *Tool*".

![Tickets with the chat panel beside it, asking about ORD-142](images/panel-mac.png)
*Tickets in the Mac layout, with the panel beside the ticket. The panel's button is the toolbar's last item.*

### What it asks about

The panel's subject is the item the tool window reports as selected. It shows as a chip in the composer, and the next message carries it.

**Suggestions** come from the item's tool: its read function proposes the questions worth asking about the item in its current state, so they change with it. A failed run offers "Why did run 641 fail?", a passed one doesn't. Each tool's page lists its own. When the tool proposes none, the panel offers general questions that suit any item of the kind, whatever its state.

| Window | Subject | Chip | Suggestions from the tool, for example | General suggestions |
|---|---|---|---|---|
| Tickets | The selected ticket | ORD-142 | See [Tickets](tickets.md) | What's left before ORD-142 can be closed? · Summarize ORD-142 |
| Service Map, a service in view | The service, in the environment on screen | payments-api | See [Service Map](service-map.md) | What calls payments-api? · What does payments-api depend on? |
| Service Map, a request in view | The request, in the environment on screen | req-8f3a | See [Service Map](service-map.md) | Which services did req-8f3a go through? · Where did req-8f3a spend its time? |
| Contracts | The selected operation | createOrder | Last call failed: Why did createOrder answer 504? · Show an example request for createOrder. Otherwise: Show an example request for createOrder · What does createOrder return? | Show an example request for createOrder |
| Builds, Runs | The selected run | Run 1288 | Failed: Why did run 641 fail? · What changed in run 641? Passed: What changed in run 640? · Was run 640 slower than usual? See [Builds](builds.md). | What changed in run 1288? · Summarize run 1288 |
| Builds, Releases | The selected release | Release v1.4.0 | See [Builds](builds.md) | What changed in release v1.4.0? · Summarize release v1.4.0 |
| Dashboard; or no selection; or the Service Map's whole namespace | None | The project's chip | — | What changed this week? · What needs my attention? |

With the subject taken off, the panel offers the project's suggestions, as with no subject.

![The chat panel beside Orders' Dashboard](images/panel-dashboard.png)
*Beside the Dashboard, which has no selection: the panel asks about Orders and offers the project's suggestions.*

The chip has three states:

- **Attached.** The item's tool symbol and title, with an `xmark` button, "Remove *ORD-142*", that takes it off the next message. Its tooltip, and its VoiceOver label, name the tool too: "Tickets: ORD-142".
- **Taken off.** A borderless **Attach *ORD-142*** button with `plus` puts it back. A new selection in the tool attaches the new item again.
- **No subject.** The project's chip, which can't be removed.

### Header

| Item | Control | Symbol | Behavior |
|---|---|---|---|
| **Chat** | Label, headline, a heading for VoiceOver | `bubble.left.and.text.bubble.right` | — |
| Conversation title | Text, one line, truncated | — | Shows when a conversation is open. |
| **New Chat** | Icon button | `square.and.pencil` | Leaves the conversation and clears the draft; the empty state returns. Disabled when no conversation is open. |
| **Open in Chat Window** | Icon button | `macwindow` | Opens the project's Chat window with this conversation selected. With no conversation open, it opens the project's Chat window without a focus. Help: "Open in the Chat Window". |
| **Hide Chat** | Icon button | `xmark` | Hides the panel, sliding it out. Help: "Hide the Chat Panel (⌃⌘C)". |

A divider separates the header from the conversation.

### Conversation and composer

- **Empty state.** Before the first message: "Ask about *ORD-142*" (or the project's name when nothing is attached), title 3, semibold, a heading for VoiceOver. Then, with an item attached, "Claude reads it through *Tickets*, and asks before it changes anything." (the item's tool); with nothing attached, the Chat window's sentence: "Claude reads through the tools, and asks before it changes anything. Name a ticket, a run or a request to point at it." Then the suggestions for the subject. A suggestion sends at once, with the chip; the draft stays as it is. When the largest text sizes need more room than the panel has, the empty state scrolls.
- **Transcript.** The same turns, rows and cards as the Chat window, tighter: 14 pt of padding and less space between turns. A tool-call row shows the action only, on one line; its detail is in the tooltip.
- **Composer.** The same composer, with 12 pt of padding. Prompt: "Ask about *ORD-142*…", or the project's name when nothing is attached. **Return** sends, **⌥Return** starts a new line.
- **Sending.** The first message starts a conversation with the window's project and the window's tool as its origin. Later messages go to the same conversation, each with whatever the chip shows at that moment.

![The panel after a question sent with Return](images/panel-sent.png)
*"Is run 1288 enough to close it?" sent with Return from Tickets: the sample reply reads ORD-142, the attached ticket, and run 1288, which the message names.*

### Showing and hiding

The panel shows or hides per window (the user's choice). Each window remembers its own choice across launches; a new window starts with the panel hidden.

| Item | Control | Symbol | Shortcut | Behavior | Layouts |
|---|---|---|---|---|---|
| **Chat** | Toolbar button, `ChatPanelToolbarItem` (see [components.md](components.md)) | `sidebar.right` | ⌃⌘C (View menu) | Shows or hides the panel. Always the toolbar's last item, at its right end (the user's choice). Help: "Show the Chat Panel (⌃⌘C)" or "Hide the Chat Panel (⌃⌘C)". | Mac, iPad, iPhone |
| **Show Chat Panel** / **Hide Chat Panel** | View menu item, after the sidebar items | — | ⌃⌘C | Shows or hides the panel of the key window. Disabled when the key window has no panel: the Chat window, the Projects window, Virtual Machines, or when Settings turns the panel off. See [navigation.md](navigation.md). | Mac, iPad, iPhone |
| **Hide Chat** | Header button | `xmark` | — | Hides the panel. | Mac, iPad, iPhone |

In Tickets, on the Mac and iPad layouts, the button sits at the right end of the ticket's column; the list's column doesn't repeat it. In the iPhone layout it ends both the list's toolbar and the ticket page's.

### Placement in each layout

The window keeps one panel in every layout, so its conversation survives a resize. With the panel open, the window takes the Mac layout only when it is as wide as the tool's columns plus the panel.

| Layout | When | What changes |
|---|---|---|
| Mac | At least the tool's Mac width + 341 pt | The panel sits beside the tool, 341 pt wide with its leading divider. The tool narrows by 341 pt to make room. |
| iPad | 640 pt up to the tool's Mac width + 341 pt | The panel slides over the tool's trailing edge, 341 pt wide, with its divider and a shadow (radius 14 pt). The tool keeps its full width and takes its own iPad layout. |
| iPhone | Narrower than 640 pt | The panel fills the window as a full page, without a divider, over the tool. The toolbar stays, with the panel's button last. |

| Tool | Mac layout without the panel | With the panel | Default window width | With the panel open at that width |
|---|---|---|---|---|
| Dashboard | 900 pt | 1241 pt | 1240 pt | Over the tool |
| Tickets | 900 pt | 1241 pt | 1180 pt | Over the tool |
| Service Map | 880 pt | 1221 pt | 1320 pt | Beside the tool |
| Contracts | 760 pt | 1101 pt | 1120 pt | Beside the tool |
| Builds | 900 pt | 1241 pt | 1180 pt | Over the tool |

![The Service Map in the iPad layout, dark, with the panel over it](images/panel-pad.png)
*The Service Map at 1000 pt, dark: the panel slides over the map and asks about payments-api.*

![The panel as a full page in the iPhone layout](images/panel-phone.png)
*In the iPhone layout the panel covers the window. Here it asks about ORD-142.*

### Animation

The panel slides in from the window's right edge and back out (the user's choice), with AZDesign's `panel` motion: a smooth curve of 0.3 s. The toolbar button, the View menu item and **Hide Chat** all animate it. In the Mac layout the tool narrows or widens in the same animation. With Reduce Motion on, the panel fades in and out in 0.15 s instead of sliding. The window's edge hides the panel while it slides; nothing is clipped, so the toolbar keeps its room. See [Motion](foundations.md#motion).

### Panel states

| State | When | What shows |
|---|---|---|
| Hidden | The window's panel is off. | The tool alone; the toolbar button's help reads "Show the Chat Panel (⌃⌘C)". |
| New chat | No conversation yet, or after **New Chat**. | The empty state with suggestions. |
| Conversation | After the first message. | The compact transcript; the title in the header. |
| Waiting for a reply | After sending, while Claude works. | The activity row with **Stop**; **Send** disabled. |
| Subject taken off | The user removed the chip. | **Attach *item*** in place of the chip; the project's suggestions. |
| No subject | The tool has nothing selected, or is the Dashboard. | The project's chip; "Claude reads through the tools…"; the project's suggestions. |
| Turned off | Settings ▸ Chat switch off. | No panel, no toolbar button; the View menu item is disabled. |

Hiding the panel keeps its open conversation, its draft and a subject the user took off: shown again, the panel is as the user left it (the user's choice). The window keeps them, not the panel. **New Chat** leaves them. Switching the window to another project starts a new conversation, with an empty draft and no subject until the tool reports one; the old conversation stays in the Chat window's list.

## Settings ▸ Chat

The Settings window's **Chat** tab (`bubble.left.and.text.bubble.right`), at 520 × 440 pt; its form scrolls. It opens from the app menu's Settings item (⌘,); see [navigation.md](navigation.md).

![Settings, Chat tab](images/settings-chat.png)
*Settings ▸ Chat: the panel switch, the Claude CLI found with its version, and what Claude can do; the form scrolls to the model of new chats.*

| Section | Control | Default | Behavior |
|---|---|---|---|
| (first) | **Show the chat panel in tool windows**, switch | On | Off, no tool window offers the panel: the panel and its toolbar button disappear, and View ▸ Show Chat Panel is disabled (the user's choice). Each window still remembers whether its panel was open, and shows it again when the switch is turned back on. Footer: "Off, tool windows have no Chat button and no panel. The Chat window stays in the Window menu." |
| **Claude CLI** | **Status** | — | While the app looks: a small progress indicator and "Looking…". Found: `checkmark.circle.fill` in `success` and "Claude Code 2.1.322". Otherwise `exclamationmark.triangle.fill` in `danger` and why ([Data › The CLI](../data.md#the-cli)). |
| | **Path**, text field in monospace | Empty | The CLI to run, absolute or from `~/`; its prompt is the path found, or "Found automatically". Return applies it. Stored as `claudePath` in `settings.yml`. |
| | **Look Again**, button | — | Applies the path and looks for the CLI again, then reads its models. Disabled while looking. A path that can't be stored shows its reason beside it, in `danger`. |
| | Footer | — | "Chats run Claude Code from this Mac. Empty, the app finds it in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, or your shell's PATH." |
| **Claude Can** | **Read tickets, services, contracts and builds** | Always | Fixed text. |
| | **Change tickets**, pop-up: Never, Ask First, Always | Ask First | Shared with the Chat window's inspector; applied to every chat's calls. |
| | **Change projects**, pop-up: Never, Ask First, Always | Ask First | The same, for adding projects and changing or removing them. |
| | **Start builds**, pop-up: Never, Ask First | Never | Shared with the inspector; applied to Claude's re-runs and cancels of runs. |
| | Footer | — | "Claude acts through each tool, as you would. Nothing it reads or changes goes around them." |
| **Replies** | **Model**, **Effort**, pop-ups | Default, High | The model and effort of new chats, stored as `chatModel` and `chatEffort` in `settings.yml`. Footer: "New chats start with these. Each chat keeps its own, in the Chat window's inspector." |

The switch is stored as `chat.showsPanel` in the user defaults.

## Accessibility

Identifiers are qualified by an id, never by a position in a list. An *item id* is the reference's id: `tool/project/focus`, plus `@environment` for an item the Service Map reported, such as `tickets/ORD/ORD-142` or `serviceMap/ORD/service:payments-api@Staging`. A *turn id* is stable for the conversation's life; the samples' read `chat-checkout.2`.

**Chat window**

| Element | Identifier | Label or notes |
|---|---|---|
| New Chat | `chat.new` | "New Chat" |
| Inspector button | `chat.inspectorToggle` | "Inspector"; help "Show Inspector" or "Hide Inspector" |
| Conversation list | `chat.list` | — |
| Conversation row | `chat.list.row.<conversation id>` | One element: title, date and origin |
| No Chats | `chat.list.empty` | "No Chats" and "Ask a question to start one." |
| New-chat prompt | `chat.newChat` | A container; its title is a heading |
| Inspector sheet's Done | `chat.inspector.done` | "Done", Return |
| In This Chat row | `chat.inspector.reference.<item id>` | A container: title and tool name as one element, then **Open** |
| In This Chat row's Open | `chat.inspector.reference.<item id>.open` | "Open"; help "Open *item* in *Tool*" |
| Nothing in this chat | `chat.inspector.empty` | "Items Claude reads or you attach show here." |
| Read (inspector) | `chat.inspector.permissions.reads` | "Read tickets, services, contracts and builds", "Always" |
| Change tickets (inspector) | `chat.inspector.permissions.tickets` | Pop-up button |
| Start builds (inspector) | `chat.inspector.permissions.builds` | Pop-up button |
| Change projects (inspector) | `chat.inspector.permissions.projects` | Pop-up button |
| Model (inspector) | `chat.inspector.model` | Pop-up button; in previews "Model", "None connected" |
| Effort (inspector) | `chat.inspector.effort` | Pop-up button |

**Conversations, in the window and the panel**

| Element | Identifier | Label or notes |
|---|---|---|
| Turn | `chat.turn.<turn id>` | A container; the author's name is a heading |
| Attachment of a turn | `chat.attachment.<turn id>.<item id>` | "*Tool*: *item*" |
| Tool-call row | `chat.toolCall.<turn id>.<item id>`, or `.<block id>` for a call without an item | One element: label the action, value the detail; with an item, a button whose hint is "Open *item* in *Tool*" and whose action opens the item |
| Approval card | `chat.approval.<approval id>` | A container; its title is a heading. The id is the request's (a UUID, or the CLI's request id); the sample's is `chat-checkout.comment` |
| Allow | `chat.approval.<approval id>.allow` | "Allow" |
| Don't Allow | `chat.approval.<approval id>.deny` | "Don't Allow" |
| Answer | `chat.approval.<approval id>.decision` | "Allowed" or "Not Allowed", with its symbol |
| Activity | `chat.responding` | A container: "Claude", what it does, and **Stop** |
| Stop | `chat.stop` | "Stop", ⌘. |
| Notice | `chat.notice` | Its text |
| Not sent | `chat.failure` | The reason |
| Suggestion | `chat.suggestion.<words>` | The question's text. Qualified by its words, lowercased and joined by hyphens: `chat.suggestion.whats-left-before-ord-142-can-be-closed` |
| Composer field | `chat.composer.field` | "Message"; prompt "Ask about *item*…" |
| Send | `chat.composer.send` | "Send", icon only; help "Send (Return)" |
| Project chip | `chat.composer.project` | One element: the project's name |
| Attached item's chip | `chat.composer.attachment` | A container: "*Tool*: *item*", then its remove button (panel only) |
| Chip's remove button | `chat.composer.attachment.remove` | "Remove *item*", icon only |
| Attach *item* | `chat.composer.attach` | "Attach *item*" (panel only) |

**Chat panel**

| Element | Identifier | Label or notes |
|---|---|---|
| Chat panel | `chat.panel` | A container; its **Chat** label is a heading |
| Conversation title | `chat.panel.title` | The open conversation's title |
| Panel's New Chat | `chat.panel.new` | "New Chat", icon only |
| Open in Chat Window | `chat.panel.openWindow` | "Open in Chat Window", icon only |
| Hide Chat | `chat.panel.hide` | "Hide Chat", icon only |
| Empty state | `chat.panel.empty` | A container; its title is a heading |
| Chat panel toolbar button | `toolbar.chatPanel` | "Chat" |
| Chat tile (Projects window) | `projects.tool.chat.open` | "Open" in the tile labeled "Chat" |

**Settings ▸ Chat**

| Element | Identifier | Label or notes |
|---|---|---|
| Panel switch | `settings.chat.showsPanel` | "Show the chat panel in tool windows" |
| Read | `settings.chat.permissions.reads` | "Read tickets, services, contracts and builds", "Always" |
| Change tickets | `settings.chat.permissions.tickets` | Pop-up button |
| Start builds | `settings.chat.permissions.builds` | Pop-up button |
| Change projects | `settings.chat.permissions.projects` | Pop-up button |
| CLI status | `settings.chat.cli.status` | One element: "Status" and the CLI's version or why it can't run |
| CLI path | `settings.chat.cli.path` | "Path" |
| Look Again | `settings.chat.cli.lookAgain` | "Look Again" |
| Model | `settings.chat.model` | Pop-up button |
| Effort | `settings.chat.effort` | Pop-up button |

- Author badges and tool symbols are hidden from VoiceOver; the author's name and the item's title carry the meaning.
- Each turn is a container, so VoiceOver steps through its blocks. Authors' names, section headers, the new-chat prompt's and the panel's titles, and approval titles are headings.
- The chip's remove button reads "Remove *item*"; the put-back button reads "Attach *item*".
- An approval's answer shows a symbol and a word, never a color alone.
- The author badge scales with Dynamic Type. At the largest sizes the new-chat prompt and the panel's empty state scroll rather than clip.

## Sample data and limits

- **Chats.** The app's chats are the projects' `.hephaestus/chats/`, V2's included. V2's chats of every kind are listed and shown; their items V3 doesn't bring over (question pickers, images Claude showed) don't show. There is no delete, no rename in the window (Claude can rename with `rename_chat`), and no file attachments in the composer.
- **Claude.** The CLI runs with no system prompt from the app, no hooks, no skills and none of its own tools ([Decisions › V2's prompts](../decisions.md#v2s-prompts)); the user's own Claude Code settings and CLAUDE.md files apply as they do in a terminal.
- **Samples.** Previews and captures use five sample conversations, about Orders (three), Payments and Shop, and the sample engine. Their replies are written as if a model had answered, so they carry no **Sample reply** caption, and their reads are fixed text, not read live. Their Service Map reads were seen in Staging.

## Previews

Previews use the windows' models with the sample conversations, and with the sample engine, slowed down where a reply must stay on its way.

- `ChatRootView.swift`: "Chat" (Orders, 1240 × 800 pt), "Chat, Dark", "New Chat" (Tools, which has no chats, 1000 × 680 pt), "Grouped" (Shop and its sub projects), "Reading" (a reply on its way), "Approval Answered" (Not Allowed), "iPad" (820 pt), "iPhone" (the list, 420 pt), "iPhone, Conversation" (opened on `chat-checkout`), "iPhone, Dark", "Largest Text", "New Chat, Largest Text".
- `ChatPanel.swift`: "Panel, Ticket" (ORD-142 attached, 341 × 640 pt), "Panel, No Subject" (the Dashboard), "Panel, Subject Taken Off", "Panel, Conversation", "Panel, Conversation, Dark", "Panel, Approval Answered" (Allowed), "Panel, Reading", "Panel, iPhone" (420 pt), "Panel, Largest Text", "Panel, Conversation, Largest Text".
- `ChatTranscript.swift`: "Approval, Waiting", "Approval, Allowed", "Approval, Not Allowed, Dark", "Approval, Narrow, Largest Text" (the note and the answer stacked).
- `ChatSettingsView.swift`: "Settings" (the CLI found, 520 × 440 pt), "Settings, CLI Not Found", "Settings, Looking", "Settings, Dark", "Settings, Largest Text".

## Open issues

None.
