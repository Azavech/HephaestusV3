# Hephaestus V3

A suite of developer tools for the Mac: projects, a Dashboard, Tickets, a Service Map, Contracts, Builds,
Chat and Virtual Machines, each tool in its own window for one project. It replaces HephaestusV2, and the
tools serve the user: Claude is one more client of them. For now it is a UI design proof of concept on
sample data. This file adds only what applies here to `~/Developer/Apple/CLAUDE.md`.

- `HephaestusV3.xcodeproj`: the thin app target in `HephaestusV3/`, bundle ID `fr.azavech.hephaestusv3`.
- `HephaestusV3Kit/`: all the code. One target per tool (`ProjectsKit`, `DashboardsKit`, `TicketsKit`,
  `ServiceMapKit`, `ContractsKit`, `BuildsKit`, `ChatKit`, `MachinesKit`), the shared vocabulary in
  `ToolsFoundation`, scenes and routes in `ToolsScenes`. Tools never depend on each other: they open one
  another through a `Route`.
- `docs/ui/`: the UI specification. Every UI change updates its page and its screenshots in the same change.
- Strings: one String Catalog per target, looked up with `#bundle`. After changing user-facing text, build,
  then run `scripts/sync-strings.sh <derived data>` to fill the catalogs and check the bundles.
- Tests: `cd HephaestusV3Kit && xcodebuild -scheme HephaestusV3Kit -destination 'platform=macOS' test`.
