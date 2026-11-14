# Navigation

How Hephaestus V3 is put together: its windows, how one window opens another, how an open window is reused,
and the menus and shortcuts that reach them.

## Windows

| Window | Kind | Opens | Default size | Page |
| --- | --- | --- | --- | --- |
| **Projects** | One window | At launch; ⌘0 | 1040 × 680 pt | [Projects](projects.md) |
| **Dashboard** | One per project | ⌘1, a tile, the menu bar panel, a link | 1240 × 820 pt | [Dashboard](dashboard.md) |
| **Tickets** | One per project | ⌘2, a tile, the menu bar panel, a link | 1180 × 760 pt | [Tickets](tickets.md) |
| **Service Map** | One per project | ⌘3, a tile, the menu bar panel, a link | 1320 × 840 pt | [Service Map](service-map.md) |
| **Contracts** | One per project | ⌘4, a tile, the menu bar panel, a link | 1120 × 740 pt | [Contracts](contracts.md) |
| **Builds** | One per project | ⌘5, a tile, the menu bar panel, a link | 1180 × 720 pt | [Builds](builds.md) |
| **Chat** | One per project | ⌘6, a tile, the menu bar panel, the chat panel | 1180 × 780 pt | [Chat](chat.md) |
| **Virtual Machines** | One window | ⌘7 (Window menu) | 1100 × 760 pt | [Virtual Machines](virtual-machines.md) |
| **Project Settings** | One per project | ⇧⌘, (File menu), the Projects window's More menu | 600 × 720 pt | [Project Settings](project-settings.md) |
| **Settings** | One window | ⌘, | 520 × 440 pt | Tabs: [Projects](projects.md#settings--projects), [MCP](../mcp.md#settings--mcp), [Chat](chat.md) (once Chat comes over) |
| **Menu bar panel** | Menu bar item | The `wrench.and.screwdriver` icon | 360 × 460 pt | [Menu bar](menu-bar.md) |

- Tool windows don't open at launch. macOS restores those that were open when the app quit.
- Every window but Settings gets no narrower than 390 pt and no lower than 420 pt, and adapts its layout to
  its size ([Layout system](foundations.md#layout-system)).

## Available tools

V3 brings HephaestusV2's features over one at a time. A tool whose feature hasn't come over yet is hidden in
the running app, so that no window shows sample data next to the real projects: its window doesn't open, and
its tile, its Window menu item, its New *Tool* Window item, its menu bar buttons and ⌘ shortcuts, and its
Settings tab don't show. `AppData.availableTools` lists the tools that have come over; ToolsScenes gives it to
every window as the `availableTools` environment value, and the menus read it directly.
`AppData.machinesAvailable` does the same for the Virtual Machines window.

| Feature | Tools and windows | Available |
| --- | --- | --- |
| Projects | The Projects window, Project Settings, Settings ▸ Projects, the menu bar panel | Yes |
| Dashboard, Tickets, Service Map, Contracts, Builds, Chat | Their tool windows, Settings ▸ Chat | Not yet |
| Virtual Machines | Its window | Not yet |

Previews and the screenshots of the spec show every tool: the environment value's default is all of them.

## Tools per project

What a project is decides which tools apply to it (`Project.tools`). The Projects window shows a tile for
each, the Window menu enables only those, and the project switcher greys out the projects without the
window's tool.

| Project kind | Tools, in menu order |
| --- | --- |
| Service with a contract | Dashboard, Tickets, Service Map, Contracts, Builds, Chat |
| Service without a contract | Dashboard, Tickets, Service Map, Builds, Chat |
| App, Library, Other | Dashboard, Tickets, Builds, Chat |

## Anatomy of a tool window

![Tickets, a tool window](images/tickets-light.png)
*A tool window: the project switcher, the tool's own toolbar items, and the chat panel's button at the far right.*

| Part | Contents |
| --- | --- |
| **Project switcher** | The toolbar's first item: the project's icon and name. A click opens a popover listing every project as a tree; picking one moves this window to that project, where the tool starts afresh on its default selection; picking the project it already shows changes nothing. See [Components › Project switcher](components.md#project-switcher). |
| **Title and subtitle** | The tool's name, and the project's path from its top-level project, such as "Shop › Orders". Hidden below 760 pt. |
| **The tool's toolbar items** | Defined by the tool, as each tool's page lists them. |
| **Chat panel button** | The last toolbar item, `sidebar.right`: shows or hides the chat panel. Absent in the Chat window, and everywhere when Settings ▸ Chat turns the panel off. See [Chat](chat.md). |
| **Content** | The tool, laid out as a Mac, an iPad or an iPhone would, depending on the window's width. |
| **Chat panel** | Beside the tool, over it, or as a full page. See [Chat](chat.md). |

## Routes

A view never opens a window itself. It asks for a **route** (`Route` in `ToolsFoundation/Routing.swift`),
and one place in the app (`RouteHost` in `ToolsScenes`) opens it. Links between tools, the Projects window's
tiles, the menu bar panel and the chat's **Open** buttons all use routes.

| Route | Opens |
| --- | --- |
| `.project(id)` | The Projects window, with the project selected. |
| `.projectWindow(id)` | The frontmost window already showing the project, or the Projects window with it selected when none does. Used by the menu bar panel. |
| `.tool(tool, project:, focus:)` | The tool's window for the project. The focus is selected in it. |
| `.machine(id)` | The Virtual Machines window, with the machine selected. |
| `.projectSettings(id)` | The project's Project Settings window: the open one, brought forward and un-minimized, or a new one. |

**Focus formats**, the item a tool selects when a route opens it:

| Tool | Focus | Example |
| --- | --- | --- |
| Tickets | Ticket id | `ORD-142` |
| Service Map | `service:<name>` or `request:<id>` | `service:payments-api`, `request:req-8f3a` |
| Contracts | Operation id | `checkoutOrder` |
| Builds | Run number, or `release:` and a tag | `1288`, `release:v1.4.0` |
| Chat | Conversation id | `chat-checkout` |

## Window reuse

A route never opens a second window for what a window already shows (the user's choice).
`WindowDirectory` keeps every window with what it shows: its role (Projects, Virtual Machines, Project Settings or a tool)
and its project. Each window reports itself when it appears and whenever its project changes.

- **A tool route** finds the frontmost window of that tool and project. It un-minimizes the window, brings it
  to the front and activates the app, and the tool selects the route's focus there without starting afresh:
  its filters, modes and scroll positions stay. A second route to the same item selects it again, even after
  the user picked another. Only when no window is open does the route open a new one, which starts on the
  focus.
- **`.projectWindow`** brings forward the frontmost window of the project, whatever its tool, the Projects
  window included when it shows the project.
- **The Projects and Virtual Machines windows** are single. A route to them brings the open one forward, and
  selects its project or machine there.
- **The Window menu's items** follow the same rules.
- **File ▸ New *Tool* Window (⌘N)** is the one way to get a second window of a tool and project: it asks for
  a new window, as on any Mac. Routes keep bringing forward the frontmost one.

**Switching project.** The project switcher moves a window to another project: the tool starts afresh on it,
without the old selection, and the chat panel starts a new conversation. Picking the project the window
already shows changes nothing.

## Menus and shortcuts

**File menu**, as in any Mac app (the user's choice): ⌘N opens a window, ⇧⌘N creates an item. These
replace the items SwiftUI adds for each kind of window, which would open a tool window without a project.

| Item | Shortcut | In | Does |
| --- | --- | --- | --- |
| New *Tool* Window, such as **New Tickets Window** | ⌘N | A tool window | Opens another window of the key window's tool, on its project and on no particular item: the tool starts on its default selection, such as the first ticket or the newest run. Disabled, as **New Window**, in the Projects and Virtual Machines windows. |
| **New Ticket…** | ⇧⌘N | Tickets | Opens the New Ticket sheet. |
| **New Chat** | ⇧⌘N | The Chat window | Starts a new chat. |
| **New Project…** | ⇧⌘N | The Projects window | Opens the [New Project](projects.md#new-project) sheet. |
| **New Machine…** | ⇧⌘N | Virtual Machines | Not wired yet. |
| **New Item** | ⇧⌘N | Any other window | Disabled: the window creates nothing. |
| **Add Existing Folder…** | ⌘O | The Projects window | Opens a folder panel ([Add Existing Folder](projects.md#add-existing-folder)). Disabled in other windows. |
| **Project Settings…** | ⇧⌘, | A window with a project | Opens the key window's project's [Project Settings](project-settings.md), or brings it forward. Disabled without a project. |

**Window menu**, above the list of open windows:

| Item | Shortcut | Enabled |
| --- | --- | --- |
| Projects | ⌘0 | Always |
| Dashboard | ⌘1 | When the key window's project has the tool |
| Tickets | ⌘2 | Same |
| Service Map | ⌘3 | Same |
| Contracts | ⌘4 | Same |
| Builds | ⌘5 | Same |
| Chat | ⌘6 | Same |
| Virtual Machines | ⌘7 | Always |

Only the available tools and windows are listed ([Available tools](#available-tools)): today, Projects alone.
The tool items act on the **key window's project**: the selection in the Projects window, or a tool
window's project.

**View menu:**

| Item | Shortcut | Enabled |
| --- | --- | --- |
| Show Chat Panel / Hide Chat Panel | ⌃⌘C | In a tool window that offers the panel |

**App menu:** Settings… (⌘,) opens Settings, whose Chat pane is described in [Chat](chat.md).

**Menu bar panel:** ↑ ↓ move, Return opens the highlighted project's window, ⌘1–⌘6 open its tools. See
[Menu bar](menu-bar.md).

**Within the tools:**

| Window | Shortcut | Action |
| --- | --- | --- |
| Contracts | ⌘Return | Send the request (not wired yet) |
| Service Map | ⌘[ | Back to the graph's view before |
| Tickets | ⌘Return | Add the comment (not wired yet) |
| Tickets | ⇧⌘Return | Move the ticket to its next step (not wired yet) |
| Tickets | ⌃⌘1 – ⌃⌘5 | Set the selected ticket's status: Draft, Created, In Progress, In Review, Done (not wired yet) |
| Chat window, chat panel | Return | Send the message |
| Chat window, chat panel | ⌥Return | New line in the message |
| New Ticket sheet | Esc, Return | Cancel, Create |
