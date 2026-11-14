# Hephaestus V3

A suite of developer tools for the Mac: projects, a Dashboard, Tickets, a Service Map, Contracts, Builds,
Chat and Virtual Machines, each tool in its own window for one project. It replaces HephaestusV2 and reads
V2's files; the tools serve the user, and Claude is one more client of them. V2's features come over one at a
time, in the redesign: until a feature's turn, its windows run on sample data. This file adds only what
applies here to `~/Developer/Apple/CLAUDE.md`.

- `HephaestusV3.xcodeproj`: the thin app target in `HephaestusV3/`, bundle ID `fr.azavech.hephaestusv3`, App
  Group `group.fr.azavech.hephaestusv3` (the data folder), sandbox off, Hardened Runtime on.
- `HephaestusV3Kit/`: all the code. One target per tool (`ProjectsKit`, `DashboardsKit`, `TicketsKit`,
  `ServiceMapKit`, `ContractsKit`, `BuildsKit`, `ChatKit`, `MachinesKit`), the shared vocabulary in
  `ToolsFoundation`, scenes and routes in `ToolsScenes`. Tools never depend on each other: they open one
  another through a `Route`. The data targets (`FileStorage`, `ExternalTools`, `ProjectData`) have no UI.
- `docs/architecture.md`: how the code is put together; `docs/data.md`: the files, V2's format and V3's
  additions; `docs/ui/`: the UI specification, window by window; `docs/decisions.md`: the defaults chosen at
  design time; `docs/future-improvements.md`: what comes later. All must be precise enough to rebuild the app
  from them: every change updates its pages, and its screenshots, in the same commit.
- V2's files stay compatible: read them as V2 wrote them, keep every key V3 doesn't use, and mark each
  addition to the format as a V3 addition in `docs/data.md`.
- Generic UI (styles, components, the adaptive window layout, `PhoneStack`, preview traits) comes from
  AZDesign, documented in its own `docs/`. A component that knows this app's types stays here; a generic one
  goes into AZDesign, with its reference page and Catalog page.
- Strings: one String Catalog per UI target, looked up with `#bundle`. After changing user-facing text, build,
  then run `scripts/sync-strings.sh <derived data>` to fill the catalogs and check the bundles.
- Tests: `cd HephaestusV3Kit && xcodebuild -scheme HephaestusV3Kit -destination 'platform=macOS' test`. Tests
  use temporary folders only: never the user's projects, data folder, Trash or shell, and no live Claude calls.
- Signed builds use `xcodebuild` (the `xcode` MCP server can't sign this app); after a capability change,
  add `-allowProvisioningUpdates`.
