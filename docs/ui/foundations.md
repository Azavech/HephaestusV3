# Foundations

The rules every Hephaestus V3 window follows: what the suite is for, how it looks, how it adapts to the room it
gets, and how it is made accessible. The window pages build on these rules and don't repeat them.

## Principles

- **The tools serve the user.** Each tool works fully by hand. Claude is one more client of the tools, next to
  the user's own views. It reads and changes items only through the tools, and it is never the center of the
  app (the user's principle). See [Chat](chat.md).
- **One tool, one window, one project.** Each tool opens in its own window for one project. Two windows can
  show two projects side by side, and a project switcher in the toolbar moves a window to another project.
  See [Navigation](navigation.md).
- **No duplicates.** Asking for something a window already shows brings that window forward, un-minimized,
  instead of opening a second one (the user's choice).
- **Content fills the window.** Nothing has a capped width. A window that grows gives the room to its
  content, and its grids gain columns (the user's choice).
- **Nothing squeezes or clips.** As a window narrows it changes layout, from the Mac's to an iPad's to an
  iPhone's ([Layout system](#layout-system), the user's choice).
- **Mac behavior.** Menus and shortcuts behave as in any Mac app (the user's choice). ⌘N opens a new
  window, ⇧⌘N creates a new item, ⌘, opens Settings. See [Navigation](navigation.md#menus-and-shortcuts).
- **Native first.** System windows, toolbars, split views, inspectors, sheets, popovers and controls, with
  Liquid Glass. The personal touches live in the content: colors, empty states and the graph.

## Colors

Views use AZDesign's semantic colors only. Each is defined in AZDesign's asset catalog: Alucard in light
mode, Dracula in dark mode, and High Contrast values where needed. No view uses a hex value or a palette
name.

| Color | Role in Hephaestus V3 |
| --- | --- |
| `textPrimary` | Main text: names, titles, values. |
| `textSecondary` | Captions, metadata, identifiers in lists, placeholders, inactive marks. |
| `canvas` | The background of every window and pane. |
| `surface` | Cards on the canvas: Dashboard widgets, approval cards, the chat composer, tickets' comments. |
| `surfaceSunken` | Wells inside cards: tool-call rows, previews of a change, chips, response bodies. At 60% opacity, the veil over a paused machine's screen. |
| `divider` | Thin lines and the chat composer's outline. |
| `highlight` | The highlighted row of the menu bar panel and of the project switcher's popover. |
| `accent` | Primary actions, selection, tint, links, the focused node of the graph, chart lines. |
| `accentSecondary` | Claude's avatar in a conversation; one of the project tints. |
| `success` | Healthy, passed, done; the low end of the graph's traffic scale. |
| `warning` | Degraded, in review, approval cards; the middle of the traffic scale. |
| `danger` | Down, failed, errors, Remove Widget; the busy end of the traffic scale. |
| `info` | The user's avatar in a conversation; created tickets; running builds. |
| `focus` | The chat composer's outline while it has the keyboard focus. |

**Project tints.** Each project has one tint for its icon: `accent`, `accentSecondary`, `info`, `success` or
`warning`.

**Health and outcome colors.** Health is shown as Healthy → `success`, Degraded → `warning`, Down → `danger`,
and a build's outcome as Passed → `success`, Failed → `danger`, Running → `info`. Each always comes with a
symbol or a word, never as color alone.

**The graph's traffic scale.** Arrows go from `success` through `warning` to `danger` in proportion to the
busiest arrow shown. Arrows without calls are a grey made from `textSecondary` mixed with `canvas`. This maps
the previous app's hue scale onto AZDesign (a porting adaptation).

## Typography

System fonts with Dynamic Type, in text styles:

| Style | Used for |
| --- | --- |
| `largeTitle` | Empty-state symbols, the new-chat prompt's symbol, a machine's screen placeholder. |
| `title`, `title2` (semibold) | Figures: counts, totals, requests per minute; project and ticket names in headers. |
| `title3` | The menu bar panel's search field, the panel's "Ask about…" heading. |
| `headline` | Section and card titles, widget titles, names in transcript turns. |
| `body`, `callout` | Running text, rows, tool-call rows, table cells. |
| `caption`, `caption2` | Metadata, dates, chips, legends, badges. |

- **Code font.** Code views use Fira Code, with its ligatures, from AZDesign's `AZDesignCode` target: build
  logs, request URLs, JSON and other request or response bodies, consoles. Views set it with
  `.codeFont(.callout)` or `Font.code(.body)`. It takes the size of the text style it is given, so it follows
  Dynamic Type.
- **Monospaced** (the system's): identifiers, paths, URLs, cluster and namespace names and commit hashes in
  lists and metadata. They are data, not code views.
- **The graph** sets its own sizes, multiplied by the zoom level, as the previous app's graph does. Its names
  hide below 30% and its arrow labels show from 50%.

## Shapes

- **Corners** are never hard-coded. Cards use concentric rectangles with a minimum radius (6 pt for wells,
  8–10 pt for cards, 12 pt for the composer), so they follow the window's corners.
- **Capsules** are used for badges, chips and the Liquid Glass overlays.
- **Circles** are used for status dots, avatars and the graph's nodes.

## Liquid Glass

- The system draws the toolbars, sidebars and inspectors in Liquid Glass.
- Hephaestus V3 adds glass only where content floats over content:
  - the Service Map's summary, zoom controls and legend;
  - the overlays on a machine's screen.
- Three primary buttons use `glassProminent`:
  - the Dashboard's **Done**;
  - a ticket's **Comment**;
  - a stopped machine's **Start**.

## Icons

SF Symbols only. Each tool has one symbol, also used for its Projects tile, its Window menu item, its
widgets and its chips.

| Tool | Symbol | Shortcut |
| --- | --- | --- |
| Dashboard | `square.grid.2x2` | ⌘1 |
| Tickets | `checklist` | ⌘2 |
| Service Map | `point.3.connected.trianglepath.dotted` | ⌘3 |
| Contracts | `curlybraces.square` | ⌘4 |
| Builds | `hammer` | ⌘5 |
| Chat | `bubble.left.and.text.bubble.right` | ⌘6 |
| Virtual Machines (not a tool) | — | ⌘7 |
| Projects window | — | ⌘0 |

- The chat panel's toolbar button uses `sidebar.right`, the Mac's symbol for a panel on the right (the user's
  choice).
- The menu bar item uses `wrench.and.screwdriver`.

## Motion

Motion marks a change; it is never decoration. Every animation uses one of AZDesign's named presets
(`Motion`, AZDesign 0.3.0), through `withMotion(_:)`, `.motionAnimation(_:value:)` and
`.motionTransition(_:edge:)`. With Reduce Motion on, each preset becomes a 0.15-second ease in and out, and
anything that would move fades instead.

| Preset | Animation | Transition | Used for |
| --- | --- | --- | --- |
| `panel` | `smooth`, 0.3 s | Moves in from an edge | A panel sliding in or out: the chat panel. |
| `layout` | `snappy`, 0.25 s | Moves in from an edge | A layout or a selection that moves. |
| `fade` | Ease in and out, 0.2 s | Opacity | Content that appears or changes in place. |

- **The chat panel** slides in from the window's right edge and back out (`panel`). On a Mac layout, the tool
  beside it narrows over the same animation.
- **The Dashboard's edit mode** moves widgets live while one is dragged or resized, and scrolls the Dashboard
  when the pointer nears its top or bottom edge.

## Layout system

Every window adapts to its size as an app does on iPad and iPhone, by the system's size classes (the user's
choice: windows conform to the system's compact and regular sizes). A window measures itself and works out
its size classes (`WindowSizeClasses` in `ToolsFoundation/ToolLayout.swift`). It writes them into the
system's own environment values, `horizontalSizeClass` and `verticalSizeClass`, so views read them as they
would on iPad or iPhone.

| Size class | Compact | Regular | As on |
| --- | --- | --- | --- |
| **Width** | Narrower than 640 pt | 640 pt and wider | Compact: an iPhone held upright, a narrow iPad window. Regular: an iPad, an iPhone held sideways. |
| **Height** | Lower than 500 pt | 500 pt and higher | Compact: an iPhone held sideways. Regular: an iPad, an iPhone held upright. |

From the width, a window then picks one of three layouts, after the three platforms (the user's choice), and
sets it in the `toolLayout` environment value. Each tool adapts its own panes.

| Layout | When | What changes |
| --- | --- | --- |
| **Mac** | Regular width, at least the window's Mac width, plus 341 pt when the chat panel is open. | Every column and panel side by side. The chat panel sits beside the tool, which makes room for it. |
| **iPad** | Regular width, below the Mac width. | Side columns fold behind their button, as an iPad's split view does when it lacks the room: Tickets' sidebar, Contracts' operations, the Chat window's list and inspector, the Projects window's projects, the Virtual Machines inspector. The chat panel slides **over** the content, with a shadow, instead of taking room from it. Wide controls turn into menus (the Service Map's and the Dashboard's time window). |
| **iPhone** | Compact width. | One pane at a time: a list, then the picked item as a page with a Back button (`PhoneStack`). The chat panel becomes a full page. Rarer toolbar controls move into a ••• menu, and wide buttons become icons. |

**Mac widths** (`ToolKind.macLayoutWidth`, and each window of its own):

| Window | Mac width |
| --- | --- |
| Dashboard | 900 pt |
| Tickets | 900 pt |
| Service Map | 880 pt |
| Builds | 900 pt |
| Chat | 960 pt |
| Contracts | 760 pt |
| Projects (not a tool) | 900 pt |
| Virtual Machines (not a tool) | 900 pt |

**Rules for every window:**

- **Minimum size.** No window gets narrower than an iPhone, 390 pt, or lower than 420 pt.
- **Each layout fits below the next one's width.** A layout's columns, at their minimum widths, need less
  than the width at which the window takes the next layout. A window narrowed by hand therefore always
  reaches the iPad layout, then the iPhone one, and nothing clips on the way.
- **Narrowing keeps the selection.** A window that narrows to compact width shows the selected item's page,
  as an iPad's split view keeps its selection when it collapses. A window that opens at compact width starts
  on its list, or on the item a route opened it on.
- **Compact height.** A short window keeps its layout and gives stacked panes less height: the Service Map's
  graph and requests share it (160 and 100 pt at least, instead of 320 and 140). Every other window scrolls
  what doesn't fit.
- **Title.** Below 760 pt the toolbar drops the window's title and subtitle. The project switcher still names
  the project.
- **Chat button.** The chat panel's button is always the last toolbar item, and appears once per window.
- **Overlays.** Overlays never wrap: the Service Map's summary, controls and legend use `ViewThatFits` to drop
  their least useful parts first.
- **Dashboard.** It lists its widgets one per row whenever it is narrower than 900 pt, not only at the iPhone
  width (the user's choice). See [Dashboard](dashboard.md).

The Projects and Virtual Machines windows aren't tool windows, but they follow the same rules from their own
measure of their size. See [Projects](projects.md) and [Virtual Machines](virtual-machines.md). Settings has
a fixed size and doesn't switch layouts.

## States

- **Empty and no selection.** `ContentUnavailableView`, with a symbol, a title such as "No Ticket Selected",
  and one sentence on what to do. Some add a button.
- **Sample data.** All data is sample data, fixed around 11 November 2026 at 14:00. The Dashboard's layouts
  are saved per project in the user defaults. Chats last as long as the app runs.
- **Models.** Each window keeps its state and logic in an `@Observable` model. The model gets its data from a
  store protocol: the app and the previews use sample stores, the unit tests use mocks. Views only show the
  model and forward the user's actions.
- **Not wired yet.** Some controls are drawn but their actions are empty, such as New Project, Re-run and
  Send. Each window page lists them.

## Accessibility

- **VoiceOver.** Elements have real labels. Rows combine their parts into one element, and symbols that only
  repeat a word are hidden. Status colors always come with a symbol or a word.
- **Identifiers.** Every meaningful element has an `accessibilityIdentifier` shaped `screen.element[.qualifier]`.
  Examples: `tickets.row.ORD-142`, `dashboard.widget.<widget id>`, `toolbar.chatPanel`, `launcher.filter`.
  The window pages list them.
- **Dynamic Type.** Text uses text styles, and a few sizes follow it with `@ScaledMetric` (status dots,
  avatars, tile icons). The graph's sizes follow its zoom level instead.
- **Keyboard.** Every window can be driven from the keyboard. The shortcuts are listed in
  [Navigation](navigation.md#menus-and-shortcuts).

## Previews

Every view has an Xcode preview per meaningful state, each with a stable name, such as "Loaded", "Empty",
"No Results" or "iPhone", so a state can be named in a review: "TicketListView, Empty". Previews use the
views' models with sample stores. Shared traits from `ToolsFoundation`:

| Trait | Gives |
| --- | --- |
| `.appChrome` | The app's tint. |
| `.padLayout` | A tool window's iPad layout. Paired with a width from 640 pt to the tool's Mac width. |
| `.phoneLayout` | A tool window's iPhone layout. Paired with a width below 640 pt. |
| `.largestText` | The largest Dynamic Type size, where a layout is likeliest to break. |

## Localization

English first, ready for translation (the user's choice: one String Catalog per target).

- **One catalog per target.** Each HephaestusV3Kit target keeps its own `Localizable.xcstrings`, next to its code,
  and looks its strings up in its own bundle with Foundation's `#bundle` macro:
  `Text("No Tickets", bundle: #bundle)`, or `String(localized: "New Ticket", bundle: #bundle)` for the
  controls that take a `String`. No view uses `LocalizedStringKey`, which would look in the app's catalog.
- **Whole sentences.** Each sentence or label is one string, with its values interpolated:
  "\(errors) errors in \(environment)", never pieces joined in code. Separators that belong to a phrase (`·`,
  `→`, "of", "in") are part of the string.
- **Counts** use automatic grammar agreement (`^[\(n) draft](inflect: true)`). **Units** use Foundation's
  formatters: durations, percentages, rates.
- **Data** is shown verbatim: names, ids, paths, messages and sample text.
- **Filling the catalogs.** `scripts/sync-strings.sh` reads what a build extracted and syncs every target's
  catalog, marking strings no longer used as stale. It then lists any line that hands a string to SwiftUI
  without its target's bundle, and fails if there is one.
