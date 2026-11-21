# Hephaestus V3 — Architecture

How the app's code is put together: the Xcode project, the package and its targets, the data targets, the
shared vocabulary, the scenes and routes, each tool's models and stores, and the patterns every target follows. The owner's
rule is that everything can be rebuilt straight from the documentation. This page and the
[UI specification](ui/README.md) together are that documentation: the UI pages say what each window shows and
how it behaves, and this page says how the code that draws it is built. [Data](data.md) is the contract of the
files. It links to those pages instead of repeating them. AZDesign documents its own APIs in its `docs/` folder; this page only names the ones the app
uses and links to their pages.

It describes the code as it is in `HephaestusV3Kit/Sources` on 14 November 2026. Where the code doesn't yet
meet the workspace's rules (`~/Developer/Apple/CLAUDE.md`), [Open issues](#open-issues) lists it.

## Contents

1. [Overview](#overview)
2. [Repository layout](#repository-layout)
3. [The Xcode project](#the-xcode-project)
4. [The package](#the-package)
5. [The data targets](#the-data-targets): [FileStorage](#filestorage), [ExternalTools](#externaltools),
   [ProjectData](#projectdata), [MCPKit](#mcpkit), [TicketData](#ticketdata), [BuildData](#builddata), [ContractData](#contractdata), [ClusterData](#clusterdata), [ChatData](#chatdata), [MachineData](#machinedata), [TextFormats](text.md); the [guest agent](guest-agent.md)
6. [ToolsFoundation](#toolsfoundation)
7. [ToolsScenes](#toolsscenes)
8. [The tool kits](#the-tool-kits): [ProjectsKit](#projectskit), [DashboardsKit](#dashboardskit),
   [TicketsKit](#ticketskit), [ServiceMapKit](#servicemapkit), [ContractsKit](#contractskit),
   [BuildsKit](#buildskit), [ChatKit](#chatkit), [MachinesKit](#machineskit)
9. [Cross-cutting patterns](#cross-cutting-patterns)
10. [Building, testing and running](#building-testing-and-running)
11. [Open issues](#open-issues)

## Overview

```
HephaestusV3 (app target)        @main HephaestusV3App: its body is ToolsScenes()
└─ ToolsScenes                   scenes, menus, routes, window reuse, the tool reader, the Dashboard's widgets
   ├─ ProjectsKit                the project selector: Projects window, project switcher, menu bar panel
   ├─ DashboardsKit              the Dashboard's grid and edit mode
   ├─ TicketsKit  ServiceMapKit  ContractsKit  BuildsKit
   ├─ ChatKit                    the Chat window, the chat panel, Settings ▸ Chat
   ├─ MachinesKit                the Virtual Machines window
   │    each kit: ToolsFoundation + AZDesign + AZDesignCode
   ├─ TextViews                  Markdown and highlighted code as tools show them (TicketsKit, ChatKit)
   └─ ToolsFoundation            shared vocabulary; depends on AZDesign only
ProjectData                      the data folder, the projects (used by ProjectsKit, ToolsScenes)
├─ FileStorage                   YAML in the files' layout, atomic writes, the lock, the Trash, file events
│  └─ Yams                       YAML parsing and emitting (third party, approved by the owner)
└─ ExternalTools                 child processes, the login shell's environment, git, ssh, kubectl
MCPKit                           the MCP server: JSON-RPC over HTTP on 127.0.0.1, the tool registry
AZDesign (package, by version)   colors, motion, components, styles, adaptive layout, preview traits
AZDesignCode (same package)      Fira Code for code views
```

The architecture rests on a few rules:

- **The app target is thin.** It holds only the entry point and the app icon. All code lives in the local
  package `HephaestusV3Kit`.
- **One target per tool.** Tool targets depend on ToolsFoundation and AZDesign, never on one another. A tool
  reaches another tool's window by asking for a `Route` through the `openRoute` environment action.
- **One place knows every tool.** ToolsScenes imports every kit. It declares the scenes, opens routes,
  reuses open windows, builds the menus, reads items for the chat, and hands each Dashboard widget to the
  tool whose data it shows.
- **Claude is one more client of the tools.** The chat reads an item only through the tool's own read
  function (`ToolReader`), never by looking into a window.
- **Models and stores.** Each window keeps its state and logic in an `@Observable` model. A model gets its
  data from a store protocol. The app uses live stores and the previews sample stores; the tests use mocks.
- **Data without UI.** The data targets import no SwiftUI and are not isolated to the main actor. They read
  and write the files of [Data](data.md) and run the command-line tools. Each feature has a live store built
  on them beside its sample store.

## Repository layout

```
HephaestusV3/                    the repository root (GitHub: Azavech, private)
├─ CLAUDE.md                     what applies to this repository only
├─ .gitignore                    .DS_Store, xcuserdata/, .build/, .swiftpm/, DerivedData/, build/
├─ .github/workflows/release.yml the release workflow ([Release](release.md))
├─ HephaestusV3.xcodeproj/       project.xcproj, in Xcode 27.2's JSON format; the app's Package.resolved
│                                in project.xcworkspace/xcshareddata/swiftpm/
├─ HephaestusV3/                 the app target's folder: HephaestusV3App.swift, HephaestusV3.entitlements,
│                                AppIcon.icon (Icon Composer)
├─ HephaestusAgent/              the guest agent's target: main.swift, which calls GuestAgent.main()
├─ GuestAgent/                   the guest agent's package, for macOS 12 guests: GuestAgentKit, its tests,
│                                and install-agent.sh ([Guest agent](guest-agent.md))
├─ HephaestusV3Kit/              the local package
│  ├─ Package.swift
│  ├─ Package.resolved           pins AZDesign's and Yams's versions for the package's own builds and tests
│  ├─ Sources/<Target>/          Swift files, and Localizable.xcstrings, for each target
│  └─ Tests/<Target>Tests/       Swift Testing suites, one folder per tested target; ProjectDataTests/Fixtures/
├─ docs/
│  ├─ architecture.md            this page
│  ├─ data.md                    the files: formats, rules, the data folder
│  ├─ decisions.md               the defaults chosen at design time
│  ├─ future-improvements.md     what comes later
│  └─ ui/                        the UI specification and its images/
└─ scripts/
   ├─ sync-strings.sh            fills the String Catalogs and checks the bundles
   └─ build-release.sh           builds a release: the app signed ad-hoc, in a .dmg
```

`HephaestusV3Kit/.build/` and `HephaestusV3Kit/.swiftpm/` are generated and ignored. `sync-strings.sh` builds
into `HephaestusV3Kit/.build/strings` when it isn't given a build.

## The Xcode project

`HephaestusV3.xcodeproj/project.xcproj` uses Xcode 27.2's JSON project format. After editing it by hand, run
`xcrun xcprojformatter --update HephaestusV3.xcodeproj` to check it and put it in canonical form. The project
has no shared scheme files: Xcode creates the `HephaestusV3` scheme for the target, and the package's
`HephaestusV3Kit` scheme for the package.

**Project**

| Key | Value |
| --- | --- |
| `configurations` | Debug, Release; `default-configuration` Release |
| `localizations` | development `en`; supported `Base` |
| `packages` | two local packages, paths `HephaestusV3Kit` and `GuestAgent` |
| `files` | the folders `HephaestusV3` and `HephaestusAgent` (synchronized), members of their targets; the group Products with `HephaestusV3.app` and `HephaestusAgent` |
| `last-upgrade`, `last-swift-update` | 27.2 |

**Target `HephaestusV3`**: product type application, product `Products/HephaestusV3.app`, build phases
compile sources, frameworks, resources and the script **Embed Guest Agent**, and a dependency on the target
`HephaestusAgent`. The frameworks phase links the package product `ToolsScenes` of `HephaestusV3Kit`. The
resources phase holds `HephaestusV3/AppIcon.icon`, through the synchronized folder: the asset compiler makes
`Assets.car` and `AppIcon.icns` from it ([Foundations › App icon](ui/foundations.md#app-icon)). The script (`/bin/sh`, its inputs and outputs declared
for the user script sandbox) copies `$(BUILT_PRODUCTS_DIR)/HephaestusAgent` to `Contents/Helpers/HephaestusAgent`
and `$(SRCROOT)/GuestAgent/install-agent.sh` to `Contents/Resources/install-agent.sh`; the app's signature seals
them. (The JSON project format's copy-files phase needs a reference syntax Xcode doesn't document, so a script does
the copy.)

**Target `HephaestusAgent`**: product type tool, product `Products/HephaestusAgent`, build phases compile sources
and frameworks; the frameworks phase links the package product `GuestAgentKit` of `GuestAgent`. Settings: `ARCHS`
arm64, `MACOSX_DEPLOYMENT_TARGET` 12.0, `CODE_SIGN_STYLE` Automatic, `DEVELOPMENT_TEAM` USWJAJULN9,
`ENABLE_HARDENED_RUNTIME` YES, `PRODUCT_BUNDLE_IDENTIFIER` `fr.azavech.hephaestusv3.agent`, `SKIP_INSTALL` YES,
`SWIFT_VERSION` 6.0, `SDKROOT` macosx.

| Build setting | Value | Why it matters |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | `fr.azavech.hephaestusv3` | Workspace rule `fr.azavech.<app>`. |
| `INFOPLIST_KEY_CFBundleDisplayName` | `Hephaestus V3` | The name in Finder, the Dock and the menu bar. |
| `ASSETCATALOG_COMPILER_APPICON_NAME` | `AppIcon` | The app icon, `HephaestusV3/AppIcon.icon`; Xcode writes `CFBundleIconName`. |
| `PRODUCT_NAME` | `$(TARGET_NAME)` | `HephaestusV3.app`. |
| `GENERATE_INFOPLIST_FILE` | `YES` | No Info.plist file. |
| `DEVELOPMENT_TEAM` | `USWJAJULN9` | The only team allowed (also set at project level). Never another. |
| `CODE_SIGN_STYLE` | `Automatic` | Xcode makes the development profile, which carries the App Group. |
| `CODE_SIGN_ENTITLEMENTS` | `HephaestusV3/HephaestusV3.entitlements` | The App Group (kept so a development build can copy the old data folder) and virtualization. |
| `REGISTER_APP_GROUPS` | `YES` | Xcode registers the App Group with the team when it makes the profile. |
| `ENABLE_APP_SANDBOX` | `NO` | The tools read project folders anywhere and run `git`, `ssh`, `kubectl` and, later, `gh` and `claude` with the login shell's environment: the owner turned the sandbox off. |
| `ENABLE_HARDENED_RUNTIME` | `YES` | Needed for Developer ID and notarization. |
| `SDKROOT` | `macosx` | Mac only. |
| `MACOSX_DEPLOYMENT_TARGET` | `27.0` | Minimum OS 27: no availability checks. |
| `SWIFT_VERSION` | `6.0` | Swift 6 language mode, strict concurrency. |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` | As in the package targets. |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` | |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | `YES` | A file sees members only from modules it imports. |
| `STRING_CATALOG_GENERATE_SYMBOLS`, `SWIFT_EMIT_LOC_STRINGS` | `YES` | String extraction. |
| `ENABLE_PREVIEWS` | `YES` | |
| `LD_RUNPATH_SEARCH_PATHS` | `@executable_path/../Frameworks` | |
| `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` | `1.0`, `1` | |

Project-level settings that matter: `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`,
`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`, `ENABLE_USER_SCRIPT_SANDBOXING = YES`,
and per configuration: Debug has `SWIFT_OPTIMIZATION_LEVEL = -Onone`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS =
DEBUG`, `ENABLE_TESTABILITY = YES`, `ONLY_ACTIVE_ARCH = YES`, `DEBUG_INFORMATION_FORMAT = dwarf`; Release has
`SWIFT_COMPILATION_MODE = wholemodule`, `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`,
`ENABLE_NS_ASSERTIONS = NO`. The remaining settings are Xcode's template set of Clang and GCC warnings.

### Entitlements

`HephaestusV3/HephaestusV3.entitlements`: `com.apple.security.application-groups` with the one group
`group.fr.azavech.hephaestusv3`, whose container was the app's data folder until 14 November 2026 and is now only
read once, to copy that data to Application Support ([Data › Data folder](data.md#data-folder)),
and `com.apple.security.virtualization`, which the Virtualization framework needs to run the virtual machines
([Data › Virtual machines](data.md#virtual-machines)); the team's profile carries both, the capability added when
the owner's Xcode refreshed it. The signed app also carries what Xcode adds: the application identifier
`USWJAJULN9.fr.azavech.hephaestusv3`, the team identifier, and `get-task-allow` in Debug. The synchronized
folder doesn't copy the entitlements file into the app.

**The entry point**, `HephaestusV3/HephaestusV3App.swift`, is the rest of the target:

```swift
import SwiftUI
import ToolsScenes

@main
struct HephaestusV3App: App {
    var body: some Scene {
        ToolsScenes()
    }
}
```

## The package

`HephaestusV3Kit/Package.swift`, `swift-tools-version: 6.2` (Swift 6 language mode):

| Part | Value |
| --- | --- |
| `name` | `HephaestusV3Kit` |
| `defaultLocalization` | `"en"` |
| `platforms` | `.macOS("27.0")` |
| `products` | one library, `ToolsScenes`, of the target `ToolsScenes` |
| `dependencies` | `.package(url: "git@github.com:Azavech/AZDesign.git", from: "0.7.0")`: AZDesign by version, from its GitHub repo over SSH. `.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")`: Yams, the YAML library the owner approved. `.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0")`: swift-markdown, approved for Markdown (it brings swift-cmark). `Package.resolved` pins the exact versions (AZDesign 0.7.0, revision `7f10be3`; Yams 6.2.2, revision `a27b21e`) |

Shared values in the manifest:

- `isolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]`, given to every UI target and its tests;
  the data targets and their tests have no default isolation.
- `design = .product(name: "AZDesign", package: "AZDesign")` and `code = .product(name: "AZDesignCode", package: "AZDesign")`.
- `strings: [Resource] = [.process("Localizable.xcstrings")]`, given to every non-test target.
- `toolTarget(_ name:, data: [Target.Dependency] = [])` makes `.target(name:, dependencies: ["ToolsFoundation", design, code] + data, resources: strings, swiftSettings: isolation)`.
- `testTarget(_ name:, resources: [Resource]? = nil, settings: [SwiftSetting] = isolation)` makes
  `.testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], resources: resources, swiftSettings: settings)`.
- `yams = .product(name: "Yams", package: "Yams")`.

**Targets**

| Target | Purpose | Dependencies | Made with |
| --- | --- | --- | --- |
| `FileStorage` | Files: YAML in the files' layout, atomic writes, own writes, the folder lock, the Trash, file events. | Yams | `.target(name:, dependencies: [yams])` |
| `ExternalTools` | Child processes: process groups and timeouts, the login shell's environment, the tools' lookup, git, ssh, kubectl. | — | `.target(name:)` |
| `ProjectData` | The data folder, the project files and their rules, the settings and secrets files. | FileStorage, ExternalTools | `.target(name:, dependencies:)` |
| `MCPKit` | The MCP server: JSON values, input schemas, tool operations and their registry, JSON-RPC, HTTP on 127.0.0.1, tokens. | — | `.target(name:)` |
| `TicketData` | The ticket, bundle and attachment files and their rules: the `TicketLibrary` actor and the `TicketSession`. | FileStorage, ProjectData | `.target(name:, dependencies:)` |
| `ChatData` | The chat files, the Claude CLI and its protocol, the chats' processes: the `ChatSession`. | FileStorage, ExternalTools, ProjectData, MCPKit | `.target(name:, dependencies:)` |
| `BuildData` | gh's runs, jobs, logs and releases, and release downloads. | ExternalTools | `.target(name:, dependencies:)` |
| `ContractData` | OpenAPI contracts, `$ref`, samples, requests, the HTTP client, stored values. | FileStorage, Yams | `.target(name:, dependencies:)` |
| `ClusterData` | kubectl, Argo CD, port forwards, the service graph, Jaeger's traces. | ExternalTools, MCPKit, BuildData | `.target(name:, dependencies:)` |
| `MachineData` | The virtual machines: the image and machine files, ipsw.me, the IPSW download and the install, disk clones and growth, the Virtualization framework's machines, the guest agent's protocol, the machine host. | FileStorage, MCPKit, ProjectData | `.target(name:, dependencies:)` |
| `TextFormats` | Markdown to a block model and syntax highlighting ([Text](text.md)). | swift-markdown | `.target(name:, dependencies:)` |
| `ToolsFoundation` | Shared vocabulary: projects, tools, routes, chat vocabulary, the Dashboard model, `ProjectIcon`. | AZDesign | `.target` |
| `TextViews` | `MarkdownView`: Markdown and highlighted code as the tools draw them, a ticket's description and comments, Claude's replies and the user's messages, with V2's markers; `MarkerText`, `ColorSwatches`, `FontFaces`, `SoundPlayer` ([Text](text.md)). Not a tool, so a tool depending on it still depends on no other tool. | ToolsFoundation, AZDesign, AZDesignCode, TextFormats | `.target`, with its strings |
| `ProjectsKit` | The project selector: the Projects window, the project switcher, the menu bar panel; New Project, Project Settings, Settings ▸ Projects; the mapping of the app's projects; the project tools of the MCP server. | ToolsFoundation, AZDesign, AZDesignCode, ProjectData, ExternalTools, MCPKit | `toolTarget(_:data:)` |
| `DashboardsKit` | The Dashboard's grid, edit mode, settings and saving in the project files; the Project widget. | same, plus ProjectData | `toolTarget(data: ["ProjectData"])` |
| `TicketsKit` | Tickets; the Tickets widget; the tickets reader. | same | `toolTarget` |
| `ServiceMapKit` | The Service Map and its graph; the service widgets; the Service Map reader. | same | `toolTarget` |
| `ContractsKit` | Contracts and the request builder; the contracts reader. | same | `toolTarget` |
| `BuildsKit` | Builds; the Recent Builds widget; the builds reader. | same | `toolTarget` |
| `MachinesKit` | The Virtual Machines window, Settings ▸ Virtual Machines, the `vm_` tools. | same, plus MachineData, MCPKit, ProjectData | `toolTarget(data:)` |
| `ChatKit` | The Chat window, the chat panel, Settings ▸ Chat, System Prompts, the shared chat store. | same, plus ChatData, MCPKit, ProjectData, FileStorage | `toolTarget(data:)` |
| `ToolsScenes` | Scenes, menu commands, route handling, the app's data (`AppData`), the MCP server's tools (`AppTools`) and Settings ▸ MCP. The only target that knows every tool. | ToolsFoundation, ProjectData, FileStorage, MCPKit, ProjectsKit, DashboardsKit, TicketsKit, ServiceMapKit, ContractsKit, BuildsKit, MachinesKit, ChatKit, the data targets, AZDesign | `.target` |

Every UI target has `Localizable.xcstrings` as its only resource; the data targets have none, since their
messages are technical details in English under a window's localized sentence. SwiftPM builds it into the bundle
`HephaestusV3Kit_<Target>.bundle`, which Foundation's `#bundle` macro resolves to in that target's code.

**Test targets**: `FileStorageTests`, `ExternalToolsTests`, `ProjectDataTests` (with the resource
`.copy("Fixtures")`), `MCPKitTests`, `ToolsFoundationTests`, `ProjectsKitTests`, `DashboardsKitTests`, `TicketsKitTests`,
`ServiceMapKitTests`, `ContractsKitTests`, `BuildsKitTests`, `MachinesKitTests`, `ChatKitTests`,
`ToolsScenesTests`, and `TicketDataTests`, `TextFormatsTests`, `ChatDataTests`, `BuildDataTests`, `ContractDataTests`,
`ClusterDataTests`, `MachineDataTests`. The guest agent's package has its own, `GuestAgentKitTests`. Each depends only on its target, uses Swift Testing and `@testable import`.

**Dependency rules**

- A tool target may depend on the data target of its own feature (ProjectsKit on ProjectData), never on
  another tool target.
- A tool target never depends on another tool target. When two tools need the same value, it moves to
  ToolsFoundation (for example `TicketStatus`, `TimeWindow`, the Dashboard model). Small helpers may exist
  twice instead, as `statusColor(_:)` does in ContractsKit and ServiceMapKit.
- ToolsFoundation depends on AZDesign only, not on AZDesignCode.
- System frameworks: SwiftUI, Foundation and Observation everywhere; Charts in ServiceMapKit
  (`MapInspector.swift`, `ServiceMapDashboardWidgets.swift`); AppKit in ToolsScenes (`WindowDirectory.swift`),
  DashboardsKit (`DashboardRootView.swift`) and ServiceMapKit (`GraphCanvasView.swift`). The data targets use
  Foundation, Darwin, Synchronization, CryptoKit (`AtomicFile`) and CoreServices (FSEvents).
- **Third-party code**: only what the owner approved. Yams, in FileStorage alone: no other target imports it,
  and FileStorage's API shows none of its types except `RawYAML`'s conversions.
- The data targets never import SwiftUI, AppKit or AZDesign; ProjectData depends on FileStorage and
  ExternalTools only.

**AZDesign APIs the app uses.** AZDesign comes by version from its GitHub repo; every API below is in its
release 0.7.0. Its reference pages (`docs/` in the AZDesign repo) document each API (the Docs column).

**Updating AZDesign** follows the workspace rule: raise the version in `Package.swift`, read AZDesign's
`CHANGELOG.md` (not its source) and apply its migration notes, resolve the packages (Xcode's File ▸ Packages
▸ Update to Latest Package Versions, or `xcodebuild -resolvePackageDependencies`), then build and test.
Commit both `Package.resolved` files with it.

| Area | APIs | Used in | Docs |
| --- | --- | --- | --- |
| Colors | The semantic shorthands on `ShapeStyle where Self == Color`: `.textPrimary`, `.textSecondary`, `.canvas`, `.surface`, `.surfaceSunken`, `.divider`, `.highlight`, `.accent`, `.accentSecondary`, `.success`, `.warning`, `.danger`, `.info`, `.focus` | Every target with views | `colors.md` |
| Motion | `Motion` (`.panel`, `.layout`), `withMotion(_:_:)`, `motionTransition(_:edge:)` | ToolsFoundation, ToolsScenes, DashboardsKit, MachinesKit | `motion.md` |
| Code font (AZDesignCode) | `codeFont(_:)` (`Font.code(_:)` is available too) | BuildsKit, ContractsKit, MachinesKit, ServiceMapKit | `code-font.md` |
| Adaptive window | `AdaptiveWindowState`, `adaptiveWindow(_:layout:)`, `WindowLayout` (`.mac`, `.pad`, `.phone`, `forWidth(_:macWidth:sidePanelWidth:)`), the `windowLayout` environment value; `WindowSizeClasses` and `collapsedFromRegularWidth` through them | ToolsScenes, ProjectsKit, MachinesKit set it; the tool kits read `windowLayout` | `layout.md` |
| Phone stack | `PhoneStack(selection:opensSelection:list:page:)` | ProjectsKit, TicketsKit, ContractsKit, BuildsKit, ChatKit, MachinesKit | `layout.md` |
| Components | `StatusDot`, `Figure`, `DetailSection`, `InspectorSection`, `CheckboxGroup`, `MessageComposer`, `CardShape` (`.card`, `CardShape(minimum:)`) | ProjectsKit, ServiceMapKit, MachinesKit, TicketsKit, DashboardsKit, ChatKit | `components.md` |
| Files | `FileTile` and `FlowStack`: a ticket's and a comment's attachments, a message's files | TicketsKit, ChatKit | `components.md` |
| SF Symbols | `SymbolPicker(selection:identifier:pick:)` and `symbolSuggestions(for:)`, on the system's `SymbolCatalog` | ProjectsKit (the Icon row of Project Settings) | `components.md` |
| Styles | `.badge(_:)`, `.tintedIcon(_:)` (label styles); `.detailRow`, `.detailRow(combinesChildren:)`, `.stacked` (labeled content styles); `.suggestion` (button style) | Most kits | `styles.md` |
| Modifiers | `foreground(_:onSelection:)`, `toolbarLabelPadding()` | Most kits | `styles.md` |
| Preview traits | `.appChrome`, `.padLayout`, `.phoneLayout`, `.largestText` | Every kit's previews | `layout.md` |

## The data targets

Targets without UI hold the data code: `FileStorage`, `ExternalTools`,
`ProjectData`, `MCPKit`, `TicketData`, `ChatData`, `BuildData`, `ContractData`, `ClusterData` and `TextFormats`. They import no SwiftUI, have no default isolation (a `@MainActor`
session type says so itself), and keep shared state in `Mutex`es and actors. Each feature wires them into its
windows through its live store ([Open issues](#open-issues) lists what isn't wired yet).

### FileStorage

Reading and writing files with the rules of [Data](data.md). Source files in `Sources/FileStorage/`:

| File | Contents |
| --- | --- |
| `YAMLCoding.swift` | `YAMLCoding`: `encode(_:)`, `encodeData(_:)`, `decode(_:from:)` for `Data`, `String` and a Yams `Node`, `parseMapping(_:)`, `nodeResolverKey` |
| `RawYAML.swift` | `RawYAML`, `YAMLMapping`, `AnyKey`, the internal `NodeResolver` |
| `MappingCoding.swift` | `MappingReader`, `MappingWriter` |
| `ISODate.swift` | `ISODate`: `string(from:)`, `date(from:)`, `now()`, `scalar(_:)`; `Date.truncatedToSeconds` |
| `StorageError.swift` | `StorageError`, `FileFormatError` |
| `YAMLFile.swift` | `YAMLFile`: `read(_:at:)`, `decode(_:from:path:)`, `isMissing(_:)`, `write(_:to:ownWrites:newFileMode:)` |
| `AtomicFile.swift` | `AtomicFile`: `write(_:to:newFileMode:)`, `sha256(_:)`, `isTemporaryFileName(_:)`, `removeLeftoverTemporaryFiles(in:)`, `resolvedDestination(_:)`, `defaultMode` 0644, `privateMode` 0600, `folderMode` 0755, `temporaryNameOverhead` 42 |
| `ClaudeImage.swift` | `ClaudeImage` (`data`, `mimeType`; `init?(_:)`, `init?(contentsOf:)`, `isImage(contentType:url:)`, `maxPixels` 1568, `maxBytes` 3,750,000): an image as Claude gets it ([Data › Claude images](data.md#claude-images)) |
| `OwnWrites.swift` | `OwnWrites`: `recordWrite(path:sha256:)`, `recordRemoval(path:)`, `isOwnWrite(path:data:)`, `isOwnRemoval(path:)` |
| `FolderLock.swift` | `FolderLock`: `acquire(_:)`, `release()`, `path` |
| `Trash.swift` | `Trash`: `move(_:)`, `.system`, `.folder(_:)` |
| `FileWatcher.swift` | `FileEvent` (`path`, `kind`, `changesMoreThanMetadata`), `FileEvent.Kind`; the internal `FileWatcher` |
| `FileEventHub.swift` | `FileEventHub`: `watch(_:)`, `unwatch(_:)`, `restart(_:)`, `stop()`, `receive(_:)`, `batches`, `watchedFolders`, `quietDelay`, `maximumDelay` |

- **YAML coding.** `YAMLCoding.encode` uses `YAMLEncoder` with `Options(indent: 2, width: -1, allowUnicode:
  true, lineBreak: .ln, sequenceStyle: .block, mappingStyle: .block, newLineScalarStyle: .literal)`.
  `decode` parses with `Yams.compose(yaml:)` (`parseMapping`: skips a byte order mark; a `YamlError` becomes
  `FileFormatError("not valid YAML: <first line>")`, `duplicatedKeysInMapping` becomes `the key "<key>"
  appears twice in one mapping`, a root that isn't a mapping `the root of the document is not a mapping`),
  then decodes the node with `YAMLDecoder().decode(_:from:userInfo:)`, passing a `NodeResolver` of the
  document under `nodeResolverKey`. Every error becomes a `FileFormatError` whose reason
  `FileFormatError.describe(_:)` writes from the coding path: `keyNotFound` → `<path>: the required key is
  missing or null`, `typeMismatch` → `<path>: expected a value of type <T>`, `dataCorrupted` → `<path>:
  <message>`; the path is the keys joined with `.`, an index as `[n]`, `the root` when empty.
- **`RawYAML`** is an `indirect enum`, `Sendable` and `Hashable`: `.scalar(Scalar)` (`text`, `tag`, the
  resolved tag's raw value such as `tag:yaml.org,2002:int`, and `style`: `ScalarStyle` `any`, `plain`,
  `singleQuoted`, `doubleQuoted`, `literal`, `folded`, Yams's raw values), `.sequence([RawYAML], style:)` and
  `.mapping(YAMLMapping, style:)` (`CollectionStyle` `any`, `block`, `flow`). `init(_ node: Node)` copies a
  Yams node (an alias becomes `.null`); `node` rebuilds one. It conforms to Yams's `YAMLEncodable`, whose
  `box()` returns `node`, so Yams writes it as read. Its `Decodable` init asks the `NodeResolver` in the
  decoder's `userInfo` for the node at the decoder's coding path (a mapping is entered by key, a sequence by
  index); without one (another decoder) it rebuilds the value from containers, scalars as strings. `isNull`
  is true for a scalar tagged `null`. `RawYAML.null` is the plain scalar `null`.
- **`YAMLMapping`** keeps entries (`Entry`: `key`, `value`) in order: a `RandomAccessCollection`, literal by
  dictionary, with `subscript(key:)` to read, replace, append (a new key goes last) or remove (nil), and
  `keys`.
- **`MappingReader`** wraps a keyed container (`AnyKey`) of a decoder: `contains`, `isAbsentOrNull`,
  `required` (throws `keyNotFound` for absent or null), `optional`, `value(_:default:)`, `requiredDate`,
  `optionalDate` (strings parsed by `ISODate.date(from:)`, else `invalid`), `schema()` (absent is 1; 2 or more:
  `schema <n> was written by a newer version`; otherwise `schema must be 1, not <n>`), `raw(_:)` (the
  `RawYAML` of a present key, `null` included), `unknownKeys(known:)` (the mapping's entries not in `known`,
  in the document's order, from the resolver; without one, sorted by key), `invalid(_:_:)` (a
  `dataCorrupted` error at the key) and `check(_:_:_:_:)` (`"<value>" is not a valid <what>`).
- **`MappingWriter`** wraps a keyed encoding container: `encode`, `encodeOptional` (`null` when absent),
  `encodeIfPresent` (left out when absent), `encodeDate` and `encodeOptionalDate` (`ISODate.scalar`: a plain
  scalar tagged `timestamp` with `ISODate.string(from:)`), and `encodeUnknownKeys(_:known:)`, which writes each
  entry not in `known`, in order.
- **`ISODate`** is proleptic Gregorian calendar arithmetic in UTC (days from and to the civil date, by
  Howard Hinnant's algorithm), no `DateFormatter`. `date(from:)` accepts `YYYY-MM-DDTHH:MM:SS`, an optional
  `.` and digits (dropped), then `Z` or `±HH:MM`, and checks the ranges, the day of the month included.
- **`AtomicFile.write`** follows [Data › Atomic writes](data.md#atomic-writes) with POSIX calls: `open` with
  `O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC` and the mode of the file it replaces (`stat`), `fchmod`, `write` in
  a loop (retrying `EINTR`), `fsync`, `close`, `rename`; any failure unlinks the temporary file and throws
  `StorageError.writeFailed(path:reason:)` with `strerror`. It returns the SHA-256 (CryptoKit) in lowercase
  hexadecimal. `resolvedDestination` follows symbolic links up to 32 levels, relative ones from the link's
  folder.
- **`OwnWrites`** is a `final class` with a `Mutex` around the digests by path and the removed paths;
  recording a write forgets a removal of the path, and a removal forgets its digest.
- **`FolderLock.acquire`** opens the folder with `O_RDONLY | O_DIRECTORY | O_CLOEXEC` and takes `flock(LOCK_EX
  | LOCK_NB)`: `EWOULDBLOCK` throws `folderInUse`, any other failure `folderUnavailable` with `strerror`.
  `release()` unlocks and closes once; `deinit` releases. Two `acquire` calls in one process conflict too: each
  opens its own descriptor.
- **`Trash`** holds a `@Sendable (URL) throws -> Void`. `move` rethrows a `StorageError` and wraps any other
  error as `trashFailed(path:reason:)`, the reason without its final period. `.system` calls
  `FileManager.trashItem`; `.folder(_:)` moves the item into a new UUID-named folder inside the given folder.
- **`FileWatcher`** (internal) is one FSEvents stream: `FSEventStreamCreate` with the flags `FileEvents |
  WatchRoot | UseCFTypes`, latency 0.05 s, from `kFSEventStreamEventIdSinceNow`, on its own serial dispatch
  queue; the C callback finds the watcher through an unretained `info` pointer, drops bookkeeping events
  (`HistoryDone`, `EventIdsWrapped`), maps flags to `FileEvent.Kind` (`created`, `removed`, `renamed`,
  `modified` for modified or cloned, `metadata` for inode, Finder info, owner or extended attributes,
  `mustRescan` for must-scan-subdirectories, user or kernel dropped, mount and unmount, `rootChanged`) and
  calls its handler. `stop()` stops, invalidates and releases the stream on its queue, which waits for a
  callback in progress.
- **`FileEventHub`** is an actor. `watch(_:)` starts a `FileWatcher` whose handler yields into an internal
  `AsyncStream`, consumed in order by one task that calls `receive(_:)`. `receive` appends the events to the
  pending batch, notes the first arrival, and restarts a timer of `min(quietDelay, first arrival +
  maximumDelay − now)`; when a timer fires for the latest generation, the pending events are yielded to
  `batches` as one array. `stop()` stops the streams and finishes `batches`. The delays are 300 ms and 2 s;
  tests pass shorter ones.

### ExternalTools

Running the command-line tools, with the rules of child processes below. Source files in
`Sources/ExternalTools/`:

| File | Contents |
| --- | --- |
| `ChildProcess.swift` | `ProcessRequest`, `ProcessTermination` (`isSuccess`, `code`), `ChildProcessError`, `ChildProcess`, `ProcessResult`, `ChildProcessRunner.run(_:input:timeout:killGrace:started:)`; the private `ExitWaiter`, `PipeCollector`, `TimeoutFlag` |
| `ProcessRunning.swift` | `ProcessRunning`, `SystemProcessRunner` (`shared`, `runningCount`, `terminateAll()`) |
| `ShellEnvironment.swift` | `ShellEnvironment`: `capture(processEnvironment:runner:shell:arguments:timeout:)`, `Capture`, `Outcome`, `forChildren(_:)`, `parseNULSeparated(_:)` |
| `ToolLocator.swift` | `Tools` (`environment`, `git`, `ssh`, `kubectl`, `gh`), `ToolLocator`: `lookUp(environment:runner:xcodeSelect:)`, `executable(named:inPATH:)`, `isExecutableFile(_:)` |
| `Git.swift` | `Git`: `originURL(in:)` |
| `SSH.swift` | `SSH`: `hostName(alias:in:)`, `hostName(inConfiguration:)` |
| `Kubectl.swift` | `Kubectl`: `namespaces(kubeconfig:)`, `deployments(namespace:kubeconfig:)`, `currentContext(kubeconfig:)`, `prefix(kubeconfig:namespace:homeDirectory:)`, `expandingHome(_:homeDirectory:)`, `command(_:)`; `KubectlError` |

The rules of child processes:

1. **Environment.** Every child gets the login shell's environment, captured once with `/bin/zsh -lic 'env
   -0'` (timeout 10 s), so tools installed with Homebrew or in `~/.local/bin` are found as in Terminal. A
   capture that fails, times out, prints no `NAME=VALUE` part or can't start falls back to the app's own
   environment and says so (`Outcome`: `captured(count:)`, `failed(_:)`, `timedOut`, `empty`,
   `couldNotStart(reason:)`). Variables starting with `HEPHAESTUS_` never reach a child
   (`ShellEnvironment.forChildren`).
2. **Lookup.** A tool is the first executable regular file of its name in the environment's `PATH`; empty and
   relative entries are skipped. `/usr/bin/git` counts only when `/usr/bin/xcode-select -p` succeeds (timeout
   10 s): otherwise it is the stub that asks to install the Command Line Tools.
3. **Spawning.** `ChildProcess.spawn` uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (the child leads a new
   process group), `CLOEXEC_DEFAULT`, an empty signal mask and default signal actions. Standard input is
   `/dev/null` or a pipe whose write end has `F_SETNOSIGPIPE`; standard output and error are pipes. Pipe ends
   are close-on-exec at once; a failed spawn closes each descriptor once.
4. **Waiting and reading.** A thread per child reaps it with a blocking `waitpid` (retrying `EINTR`); a thread
   per pipe reads it to end of file in 64 KiB blocks. After the exit, collection waits at most 500 ms more, so
   a grandchild that kept the pipe open doesn't block the caller.
5. **Timeout.** When `timeout` passes first, the process group gets `SIGTERM`, then `SIGKILL` 2 s later
   (`killGrace`) if it is still running; the result says `timedOut`.
6. **Quitting.** `SystemProcessRunner` keeps the running children; `terminateAll()` sends `SIGTERM` to each
   one's process group.
7. **Testing.** Code that runs tools takes an `any ProcessRunning`; tests pass a fake that answers from a
   script, so no test starts the user's shell or tools. The process tests themselves start only `/bin/sh`,
   `echo` and `sleep`.

| Tool | Command | Timeout | Gives |
| --- | --- | --- | --- |
| git | `git config --get remote.origin.url`, in the project's folder | 5 s | The origin's URL, trimmed; nil outside a work tree, without an origin, on failure or timeout |
| ssh | `ssh -G <alias>`, in the project's folder | 5 s | The value of the first `hostname` line (case-insensitive); nil for an alias starting with `-`, on failure or timeout |
| kubectl | `[--kubeconfig=<file>] [--namespace=<ns>] get namespaces -o json` | 15 s | The `metadata.name` of each item, in kubectl's order |
| kubectl | `[--kubeconfig=<file>] [--namespace=<ns>] get deployments -o json` | 15 s | Same |
| kubectl | `[--kubeconfig=<file>] config current-context` | 15 s | The context's name |

kubectl never gets `--context`: it uses the kubeconfig file's current context. A kubeconfig path starting
with `~/` is expanded with the home folder (trailing `/` removed; `/` gives no prefix). Failures are
`KubectlError`: `failed(command:code:message:)` (`<command> exited with code <n>: <stderr>`, or `… with code
<n>.` without standard error; `n` is the status, or 128 + the signal), `timedOut(command:)` (`<command> did
not finish within 15 seconds.`), `unexpectedOutput(command:)` (`Unexpected output from <command>.`),
`couldNotStart(reason:)`. `<command>` is `kubectl` and its arguments, each argument that is empty or holds a
character other than letters, digits and `-_./:=,@+%` in single quotes.

### ProjectData

The files of [Data](data.md). Source files in `Sources/ProjectData/`:

| File | Contents |
| --- | --- |
| `ProjectFile.swift` | `ProjectFile`, `ProjectKind`, `ProjectColor`, `EnvironmentEntry` (`baseURL`), `EnvironmentOverride` (`isEmpty`, `applied(to:)`) |
| `DashboardWidgetEntry.swift` | `DashboardWidgetEntry` (`Kind`, `Field`, `Status` with `defaultStatuses`, `ChatKind`; `countRange`, `titleLimit`, `defaultID(_:)`, `checked(_:keeping:)`, the keys per kind and the write rules), `DashboardGraphWindow` |
| `RegistryFile.swift` | `RegistryFile` (`loadableEntries`) |
| `CurrentEnvironmentsFile.swift` | `CurrentEnvironmentsFile` |
| `ProjectFolder.swift` | `ProjectFolder`: the `.hephaestus/` paths, `isProject`, `ensureGitignore(ownWrites:)`, `gitignoreLine` |
| `DataFolder.swift` | `DataFolder`: `resolve(environment:applicationSupport:)`, `folderName`, `appGroup`, `appGroupContainer`, `migrateFromAppGroup(container:)`, `overrideVariable`, `registryFile`, `currentEnvironmentsFile`, `invalidCopy(of:)`, `createIfNeeded()`, `lock()` |
| `ProjectRules.swift` | `ProjectRules`, `ProjectRuleError` |
| `GitHub.swift` | `GitHubPage`, `GitRemote` (`init?(remoteURL:)`, `isGitHubHost`, `gitHubPage(resolvedHostName:)`) |
| `ProjectSnapshot.swift` | `ProjectSnapshot` (`revision`, `projects`, `issues`, `project(_:)`, `project(atRoot:)`, `family(of:)`), `LoadedProject` (`root`, `file`, `parentID`, `depth`, `childIDs`, `resolved`, `fileIssue`), `ResolvedSettings` (`environments`, `inheritedEnvironments`, `currentEnvironment`, `githubPage`, `defaultGithubPage`, `graphEnabled`, `inheritedGraphEnabled`; [Data › Resolution](data.md#resolution)), `ProjectIssue` (`path`, `source`, `reason`) |
| `ProjectError.swift` | `ProjectError` |
| `ProjectLibrary.swift` | `ProjectLibrary` (`load()`, `handle(_:)`, `watchedFolders`, `setTools(_:)`, `refreshOrigins()`, `create(_:)`, `open(folder:)`, `update(_:_:)`, `remove(_:)`, `setCurrentEnvironment(_:to:)`, `allocateNumber(for:_:)` with `NumberKind`), `NewProject`, `ProjectChange` |
| `ProjectSession.swift` | `ProjectSession` (`phase`, `snapshot`, `shell`, `tools`, `isLookingUpTools`, `hasLookedUpTools`, `waitForTools()`, `kubectl`, `projectLibrary`, `start()`, `lookUpTools()`, `stop()`, `observeFileEvents(_:)`, and the changes) |

- **File types.** Each is a `Codable`, `Sendable`, `Hashable` struct whose `init(from:)` reads with a
  `MappingReader` and whose `encode(to:)` writes with a `MappingWriter`, key by key in the order of its table
  in [Data](data.md), then its unknown keys. Single-line strings are trimmed with
  `ProjectRules.trimmedOrNil`.
- **`ProjectFile`** keeps the known keys it doesn't use in `keptKeys`, read with `raw(_:)` and written with
  `encodeIfPresent` at their places: `useParentSettings` (V2's, without effect) after `githubPage`; `webTabs`,
  `skills`, `chatDefaults` after `subprojects`;
  `dashboardWidgets`, `dashboardGraphWindow`, `deletedChats`, `commentAnswers` after `environmentOverrides`.
  `color`, `icon`, `githubPage` and `graphEnabled` are left out when nil. `EnvironmentOverride` writes V2's
  six keys with `encodeOptional` (`null` included) and V3's `namespace` and `kubeconfig` only when set.
  `environmentOverrides` is written through `EnvironmentOverride.SortedMap`, its names in Unicode code point
  order; `CurrentEnvironmentsFile.projects` likewise.
- **Equality** compares every field, the kept and unknown keys included: a file that decodes to the value in
  memory is no change.
- **`ProjectLibrary`** is an actor holding the registry, the choices, the loaded projects (a node per
  identifier: root, file, parent, depth, children), the issues, the file issues, the origins by folder and
  the host names by SSH alias. `load()` and every change call `rebuild()`, which loads the whole tree again
  from the registry and the files (cheap: a project file is small), keeping the version loaded before of a
  project whose file became invalid; `publish()` then builds the snapshot, resolving each project
  ([Data › Resolution](data.md#resolution)), and gives it a new revision only when it differs from the last.
  `handle(_:)` and `refreshOrigins()` return nil when nothing changed. Changes throw `ProjectError`: `rule`
  (a `ProjectRuleError`), `storage` (a `StorageError`), `noDataFolder`, `noProject(path:)`,
  `alreadyContainsProject(path:)`, `folderMissing(path:)`, `notInsideParent(parentName:)`,
  `projectNotLoaded(_:)`, `unknownEnvironment(_:)`. The rules are in [Data › Changes](data.md#changes).
- **`ProjectSession`** is `@MainActor @Observable`: the windows observe `phase` (`starting`, `ready`,
  `failed(ProjectError)`), `snapshot`, `shell` and `tools`, and call its async throwing
  changes, which forward to the library and keep the snapshot they return (a snapshot is kept only when its
  revision is higher). `start()` runs the order of [Data › Loading](data.md#loading); it consumes the
  `FileEventHub`'s batches in a task, hands each to `handle(_:)`, and updates the watched folders after each
  change. `lookUpTools()` captures the shell, looks the tools up, gives them to the library and reads the
  origins. The tools are looked up after the projects load, so a window that opens with the app (one macOS
  restores) can ask for a tool before they are known: `hasLookedUpTools` turns true after the first lookup,
  and `waitForTools()` returns then (at once after it, or when the session failed to start or stops; the
  waiters are `CheckedContinuation`s resumed together). What runs a tool as the app opens waits for it
  rather than finding the tool missing: Project Settings' cluster check, `LiveServiceMapStore.refresh` and
  `LiveBuildStore.refresh` (through its `toolsReady` closure). `stop()` stops the streams, ends the running tools and releases the lock. `kubectl` is the
  tools' kubectl for the settings' suggestions. Tests give it a temporary data folder, a fake runner and a
  hub with short delays.
- **Shared with other features.** `allocateNumber(for:_:)` takes a ticket or bundle number from a project's
  counter ([Data › Ticket rules](data.md#ticket-rules)) and writes the project file; `observeFileEvents(_:)`
  adds a `@MainActor` function called with every batch, after the projects reloaded, so that each feature
  reads its own files again without a second stream.

### MCPKit

The MCP server of [MCP](mcp.md). No UI, no default isolation. Source files in `Sources/MCPKit/`:

| File | Contents |
| --- | --- |
| `JSONValue.swift` | `JSONValue` (`null`, `bool`, `int`, `double`, `string`, `array`, `object`): `parse(_:)` (`JSONSerialization`, fragments allowed; a number is a boolean when it is a `CFBoolean`, an integer when it isn't a float type or is a float with an integral value below 9.2e18), `data` and `text` (sorted keys, slashes not escaped), `init(encoding:)` (`JSONEncoder` with sorted keys), accessors, `subscript(key:)`, `removingNullMembers`, literals |
| `ToolSchema.swift` | `ToolSchema` (`object`, `string`, `integer`, `boolean`, `array` builders, and `anyValue` for a value of any type, which has no `type` and takes anything: `ask_color`'s suggestions; `json`; `violation(of:)`, the validation of [MCP › Argument validation](mcp.md#argument-validation)) |
| `ToolOperation.swift` | `ToolError` (`code`, `message`), `ToolPermission` (`read`, `changeTickets`, `deleteTickets`, `changeProjects`, `removeProjects`, `renameChats`; `changes`), `ToolCallText` (`action`, `request`, `preview`, `item`), `ToolItem` (`tool`, `projectID`, `focus`, `title`), `ToolOperation` (`name`, `description`, `inputSchema`, `permission`, `describe: (@Sendable (JSONValue) -> ToolCallText)?`, `run: @Sendable (JSONValue) async throws(ToolError) -> JSONValue`, `listing`), `ToolRegistry` (`operations`, `names`, `subscript(name:)`; names unique), `JSONValue.string(_:)` |
| `MCPProtocol.swift` | `MCPReply` (`json`, `accepted`, `unsupportedVersion`), `MCPProtocol` (`supportedVersions`, `serverName`, `Gate`, `init(registry:version:gate:)`, `handle(body:protocolVersions:caller:)`) |
| `HTTP.swift` | `HTTPHead`, `HTTPResponse` (the rejections' texts, `data`), `HTTPParser` (`head(in:)`, `body(of:in:)`, the limits) |
| `MCPTokens.swift` | `MCPCaller` (`external`, `chat(String)`, `internalSkill(String)`, `chatID`, the task-local `current`), `MCPTokens` (a token → caller map: `replace(with:)` for the external tokens, `issue(forChat:)`, `issue(forSkill:)`, `revoke(_:)`, `caller(for:)` and `accepts(_:)` in constant time, `generate()` with `SecRandomCopyBytes`, `bearer(_:)`) |
| `MCPServer.swift` | `MCPServer` (actor: `state`, `states`, `start(port:)`, `stop()`), the private `MCPConnection` and `OneShot` |

- **Operations.** A kit declares its tools as `ToolOperation`s whose `run` is a `@MainActor` closure calling
  the same function its window calls (ProjectsKit's `ProjectTools.operations(session:)`, TicketsKit's
  `TicketTools.operations(tickets:projects:)`, ChatKit's `ChatTools.operations(chats:projects:)`). Each also
  gives `describe`, its wording of a call for the chat (`TicketTools.text`, `ProjectTools.text`). ToolsScenes
  gathers them in order (`AppTools.registry(session:tickets:chats:open:)`), adds `open_in_app`, and hands the
  registry to an `MCPProtocol` with its gate. `handle` runs the request with `MCPCaller.$current` set to the
  token's caller; `MCPProtocol.call` validates the arguments, removes `null` members, asks the gate (nil runs
  the call; an error refuses it as a tool error), runs the operation, and wraps its JSON, or its error's
  message, in a tool result. The gate is `ChatGate.check` ([MCP › Permissions](mcp.md#permissions)).
- **The server** binds an `NWListener` whose `requiredLocalEndpoint` is `127.0.0.1:<port>` (local endpoint
  reuse allowed) on a private dispatch queue; `start(port:)` awaits the listener's `ready` or `failed` state
  through a `OneShot`, five attempts a second apart. Each connection reads with `receive(minimumIncompleteLength: 1,
  maximumLength: 65536)`, raced against a 60-second sleep, parses the head, checks it
  ([MCP › HTTP transport](mcp.md#http-transport)), sends `100 Continue` when asked, reads the body, answers,
  and loops until a response closes it.
- **AppData** (ToolsScenes) starts it once the projects are loaded: the port from `settings.yml` or
  `HEPHAESTUS_MCP_PORT`, the external token from `secrets.json` (made when missing), the registry, the app's
  `CFBundleShortVersionString` as version. It follows `states` into `mcpState`, and offers `changePort(to:)`,
  `regenerateToken()` and `addCommand`. `open_in_app` calls `AppData.openRoute`, the route action of the
  first window that appeared. **Settings ▸ MCP** is `MCPSettingsPane(appData:)` over `MCPSettingsView`, a
  view on plain values with its previews ("Listening", "Failed, Dark", "Port From Environment").

### TicketData

The ticket and bundle files of [Data › Tickets and bundles](data.md#tickets-and-bundles). No UI, no default
isolation. Source files in `Sources/TicketData/`:

| File | Contents |
| --- | --- |
| `TicketFile.swift` | `TicketIDs` (`parseTicket`, `parseBundle`, `ticket(project:number:)`, `bundle(project:number:)`), `TicketFileStatus`, `Author`, `TicketPriority`, `TicketFile`, `AttachmentEntry`, `CommentEntry`, `TicketLinkEntry`, `HistoryEntry` (`Kind`, `HistoryAuthor`), `BundleFile` (`Status`) |
| `TicketRules.swift` | `TicketActor` (`user(device:)`, `claude(chat:)`, `automatic` (history author `automatic`, no device or chat), `isClaude`), `TicketError` (`invalid`, `notFound`, `forbidden`, `conflict`, `storage(StorageError)`, `project(ProjectError)`; `description` is the message), `TicketRules` (`title`, `title(fromAnswer:)`, `provisionalTitle(from:)`, `provisionalBundleTitle(from:)`, `normalized`, `labels`, `attachmentName(_:id:)`, `contentType(of:)`, `attachmentLimit`, `imageTypes`), `ImplementRules` (`refusal(of:)` of a ticket and of a bundle: [Data › Implement chats](data.md#implement-chats)) |
| `TicketLibrary.swift` | `LoadedTicket` (`file`, `projectID`, `inverseLinks`), `TicketSnapshot` (`revision`, `tickets`, `bundles`, `invalidFiles`, `ticket(_:)`, `bundle(_:)`), `TicketLibrary` (`sync(with:)`, `handle(_:)`, `snapshot`, `create`, `onUntitled(_:)` (a `@Sendable` handler called with an `UntitledTicket` (`id`, `provisionalTitle`, `description`) after each ticket created without a title, by any actor), `setGeneratedTitle(_:of:replacing:)` (renames as `automatic` only while the title is still the provisional one; nil otherwise), `update`, `setStatus`, `delete`, `addComment`, `updateComment`, `deleteComment`, `addAttachments`, `removeAttachment`, `attachmentURL`, `createBundle`, `updateBundle`, `setBundleStatus`, `deleteBundle`, `linkChat(_:toTicket:)`, `linkChat(_:toBundle:)`, `startImplementation(of:chat:)`), `NewTicket`, `TicketChange` |
| `TicketSession.swift` | `TicketSession` (`snapshot`, `isLoaded`, `library`, `device`, `computerName()`, `start()`, `refresh()`, and the changes, made as `.user(device:)`, Implement's `linkChat(_:toTicket:)` and `startImplementation(of:chat:)`, and the CI chats' `linkChat(_:toBundle:)`, among them) |

- **`TicketLibrary`** is an actor holding, per loaded project, its folder, its ticket files and its bundle
  files by id, and the invalid files with their reasons. `sync(with:)` follows a `ProjectSnapshot`: it loads
  the projects it doesn't hold (and those whose folder changed), drops the others, and applies the Complete
  rule to each project it loads. `handle(_:)` reads again the files a batch names under `.hephaestus/ticket/`
  and `.hephaestus/bundle/` (both as given and with symbolic links resolved), or the whole project after
  dropped events, then applies the automatic bundle rules. Each change checks everything before its first
  write, takes numbers through `ProjectLibrary.allocateNumber`, writes in the order of [Data › Ticket
  changes](data.md#ticket-changes) with the shared `OwnWrites`, and moves files with its `Trash` (tests pass
  `Trash.folder(_:)`). `publish()` sorts tickets and bundles by number, computes every ticket's inverse
  links, and gives a new revision only when the snapshot differs.
- **`TicketSession`** is `@MainActor @Observable`. `start()` runs once the `ProjectSession` is ready: it
  creates the library on the session's `projectLibrary`, syncs, registers with `observeFileEvents` (sync
  then `handle` for each batch), and follows `ProjectSession.snapshot` with `Observations` to sync after
  in-app project changes. Its changes forward to the library as the user on this Mac (`device` is
  `SCDynamicStoreCopyComputerName`) and keep the snapshot they return when its revision is higher. The MCP
  tools use `library` directly with the actor `.claude(chat:)`, then call `refresh()`.

### ClusterData

The clusters of [Data › Clusters](data.md#clusters). No UI, no default isolation. Depends on ExternalTools,
MCPKit (its `JSONValue`) and BuildData (gh, for the sources). Source files in `Sources/ClusterData/`:

| File | Contents |
| --- | --- |
| `Cluster.swift` | `ClusterTarget` (`argoCD`), `ClusterError`, `DeploymentStatus`, `PodStatus`, `ClusterEvent`, `ArgoCDStatus`, `Cluster` (`deployments`, `status`, `logs`, `events`, `restart`, `scale`, `argoCDStatus`, `argoCDSync`) |
| `PortForwards.swift` | `PortForward`, `PortForwards` (actor: `forward`, `list`, `stop`, `stopAll`, the 60 s reaper, `forwardingPort`) |
| `ServiceGraph.swift` | `ServiceGraph` (`Box`, `Arrow`, `image`, `requiredModules`, `values`, `build`) |
| `Jaeger.swift` | `TraceSpan` (`spans(_:)` from OTLP JSON), `JaegerClient` (`spans(service:from:to:)`, `trace(_:)`) |
| `ServiceActivity.swift` | `ServiceActivity` (`analyze`, `request`), `ServiceSources` (actor: the sources read with gh, kept), `ServiceMapRead` (`read`: Deployments, sources, Jaeger) |

ExternalTools' `Kubectl` gained a public `run(_:timeout:directory:)`; its timeout message says the timeout.

### ContractData

The contracts of [Data › Contracts](data.md#contracts). No UI, no default isolation. Depends on FileStorage
and Yams. Source files in `Sources/ContractData/`:

| File | Contents |
| --- | --- |
| `ContractValue.swift` | `ContractValue` (an ordered YAML/JSON value: `parse(_:)` with Yams, `subscript(key:)`, accessors, `json(pretty:)`) |
| `OpenAPIContract.swift` | `OpenAPIContract` (`read(_:file:root:)`, `operation(_:)`, `schemes(for:)`), `ContractError`, `OpenAPIOperation` (`key`, `RequestBody`, `MediaType`, `DocumentedResponse`), `OpenAPIParameter`, `SecurityScheme`, `ContractResolver` (the `$ref` rules) |
| `ContractSamples.swift` | `ContractSamples` (prefilled bodies, samples from schemas, type summaries) |
| `RequestBuilder.swift` | `RequestValues`, `RequestBuilder` (`encode`, `url`, `headers`, `request`), `ContractResponse` (`text`), `ContractHTTPClient` (strict and lenient ephemeral sessions), `ContractCallError` |
| `StoredValues.swift` | `StoredContract`, `StoredHeader`, `StoredOperation`, `StoredValuesFile` (`read`, `write`) |

### BuildData

The gh calls of [Data › Builds](data.md#builds). No UI, no default isolation. Depends on ExternalTools. Source
files in `Sources/BuildData/`:

| File | Contents |
| --- | --- |
| `GitHubCLI.swift` | `GitHubRepository` (`init?(page:)`, `repoArgument`, `webURL`), `BuildError` (`unavailable`, `unexpected`, `storage`; `noPage`, `noGH`, `noLogin`), `GitHubCLI` (`gh`, `environment`, `runner`, `childEnvironment`, `run(_:_:timeout:)`, `reason`) |
| `GitHubBuilds.swift` | `GitHubRun`, `GitHubJob`, `GitHubStep`, `gitHubDuration`, `GitHubRelease`, `GitHubAsset` (all `Decodable` from gh's JSON), `StepLogs.parse`, `GitHubBuilds` (`runs`, `run`, `log(job:)`, `rerun`, `cancel`, `releases`, `download`, `pattern(forAsset:)`, the move and the quarantine) |

Tests pass a fake `ProcessRunning` that answers gh's calls from a script and records them: no test reaches
GitHub.

### ChatData

The chats of [Data › Chats](data.md#chats): their files, the Claude CLI, its stream-json protocol and the chats'
processes. No UI, no default isolation; `ChatSession` and `ChatRun` are `@MainActor`. Depends on FileStorage,
ExternalTools, ProjectData and MCPKit. Source files in `Sources/ChatData/`:

| File | Contents |
| --- | --- |
| `ChatFile.swift` | `ChatFile` (`Kind`, the keys of [Data › Chat file](data.md#chat-file), `kindViolation`), `ChatSettings` (`model`, `effort`, `permissionMode`, `ultracode`, `contextWindow`, `isModel`), `Effort`, `ChatIDs` (`make`, `isChatID`); `ChatPermissionMode` (`init(stored:)`, `cliValue`) and `ChatContextWindow` (`init(stored:)`, `autocompact`), which `ChatLaunch` passes and `setSettings(_:_:)` changes live |
| `ChatItem.swift` | `ChatItem` (`user`, `assistant`, `thinking`, `toolUse`, `toolResult`, `permissionRequest`, `system`, `result`; `id`, `created`, `json`, `init?(json:)`), the item structs, `ChatItemReference` (`projectTool`), `ToolUseItem.split(_:)` |
| `Transcript.swift` | `Transcript` (`Op`, `replay(_:)`, `line(_:_:)`, `append(_:to:endingLine:)`) |
| `StreamMapper.swift` | `StreamOutput` (with `toolResultImages`), `StreamMapper` (`effort`, `stopping`, `map(_:)`, `finish()`, `itemID`, `mcpProblem`, `tokens`, `truncated`), `ResultImage`; `ChatSession.storeResultImages(_:of:in:)` in `ChatRun.swift` |
| `ClaudeCLI.swift` | `ClaudeStatus`, `ClaudeModel` (`fallback`, `list(_:)`, `name(of:in:)`), `ClaudeCLI` (`locate`, `status`), `ClaudeCommand` (`name`, `description`, `argumentHint`, `isBuiltIn`, `isSynced`, `plugin`; `syncedMark`; `list(_:)`, from `initialize`'s `commands`; `marking(_:syncedPlugins:)`, `syncedPlugins(claudeFolder:)`) |
| `ClaudeProcess.swift` | `ChatLaunch` (`arguments`, with `--plugin-dir` when `pluginDir` is set, `request`, `logLine`, `mcpConfiguration`), `ClaudeInput` (the lines written: `message(_:images:uuid:)`, the images as base-64 blocks before the text, `control`, `allow`, `deny`, `unsupported`, `text(_:carrying:)`, `attachedLine`), `ClaudeConnection` and `ClaudeLaunching` (protocols), `SystemClaudeLauncher`, `SystemClaudeConnection` |
| `ChatSession.swift` | `LoadedChat`, `ChatState`, `ChatError`, `StreamingText`, `ChatSession` (state, start, the CLI's check, settings, `commands` and `projectCommands`, `commands(forProject:)`, `markingSynced(_:)`, reading, files, `refreshState`) |
| `ChatRun.swift` | `ChatRun` (one live process), and `OutgoingMessage` (`text`, `images`), and `ChatSession`'s `send(_:references:to:projectID:origin:title:images:)`, `makeChat` and `post` (a new chat's file, then a message recorded and written), the launch, which writes the [chat plugin](data.md#chat-plugin) first (a warning item when it can't), launch, output handling, turns, exit, `stop`, `stopAll`, `answer`, `requestApproval`, `setSettings`, `rename`, `probeModels` |
| `InternalSkill.swift` | `InternalSkill` (`name`, `defaults`, `isCalledFromChats`, `init(name:defaultContent:defaultModel:defaultEffort:isCalledFromChats:)`, `setTicketTitle`, `reportFeedback`, `resumeChat`, `resumeAgent`, `notificationSummary`, `implementTicket`, `implementBundle`, `watchCI`, `all`, `pluginName` `hephaestus-skills`, `command`, `isValidName(_:)`), `InternalSkillValues` (`content`, `model`, `effort`, `otherLines`), and on `DataFolder`: `skillsFolder`, `skillFile(of:)`, `readSkill(_:)`, `writeSkill(_:of:)`, `pluginsFolder`, `writeChatPlugin(_:)` ([Data › Internal skills](data.md#internal-skills)) |
| `InternalSkillRun.swift` | `InternalSkillRun` (`timeout` 120 s, `arguments(_:mcpConfig:tools:)`, `request(cliPath:values:environment:folder:mcpConfig:tools:)`, `message(_:attaching:)`: `ClaudeInput.text(_:carrying:)`, or the `attachedLine`s alone for a blank input, `answer(from:)`), and `ChatSession.run(_:input:attaching:) async throws(ChatError) -> String`: fails at once without an available CLI or data folder; otherwise issues a token (`tokens.issue(forSkill:)`), writes `Runtime/mcp/skill-<UUID>.json` with `ChatLaunch.mcpConfiguration(port:token:)`, reads the skill's values, runs the request with the session's `toolNames` through its `runner`, the message on standard input, and returns `answer(from:)`; the token is revoked and the file deleted however the run ends |
| `FeedbackChat.swift` | `FeedbackReport` (`projectID`, `comment`, `context`, `screenshot`, `files`, `settings`; `sizeLimit` 20 MiB; `message(comment:context:screenshot:attachments:)`), and on `ChatSession`: `createFeedback(_:) async throws(ChatError) -> String` ([Data › Feedback chats](data.md#feedback-chats)), `isUnlinkedFeedback(_:)`, `linkFeedback(_:toTicket:)` |
| `ImplementChat.swift` | `ImplementChat` (`Item`: `ticket(_:orchestrator:)`, `bundle`; `Orchestrator` (`chatID`, `bundleID`); `title`, `message`, `file(id:created:)`, `report(ticketID:turn:stopped:failed:)`, `questionsRefusal`), `ChatWorktree` (`folder(dataFolder:projectID:ticketID:)`, `branch(bundleID:ticketID:)`, `workingFolder(worktree:projectRoot:)`, `prepare`: V2's four git steps, 60 s each), and on `ChatSession`: `startImplementChat(_:link:)` (the CLI, an orchestrated chat's worktree one at a time through `preparingWorktree` and `worktreeWaiters`, the file, `link`, the first message), `orchestrator(for:caller:bundleTickets:)`, `ownsItem(_:chat:bundleTickets:)`, `questionsRefusal(in:questions:)` (nil for `ask_questions` while `ciQuestionChats` holds the chat), `chats(ofTicket:)`, `chats(ofBundle:)` (each chat followed by those it orchestrates), `isOrchestrating(_:)`, `worktreeFolder(of:projectRoot:)` (which `root(ofChat:)` and the launch use), `reportToOrchestrator(_:from:to:)` (called by `refreshState`; a CI chat's text from `CIChat.report`; nothing once `stopAll` set `quitting`), as [Data › Implement chats](data.md#implement-chats) says. `send` lifts `questionsBlocked`; Resume and the agents' Resume send with `fromUser: false`. |
| `CIChat.swift` | `CIChat` (`projectID`, `orchestrator`, `item` (`ticket`, `bundle`), `commit`, `settings`; `title`, `message`, `file(id:created:)`, `report(turn:stopped:failed:)`, `isFailure(_:)`, `isFullHash(_:)`, V2's refusals), and on `ChatSession`: `startCIChat(commit:caller:link:)` (the checks of [Data › CI chats](data.md#ci-chats) but the item's, which `link` makes; the file, `link`, the first message carrying the project), `ciQuestionChats` (the orchestrators that may post one question set after a CI failure: set and cleared by `reportToOrchestrator`, used up by `postQuestions`, dropped by `delete`) |
| `ChatQuestions.swift` | `ChatQuestion` (`Kind`, `Option`, `accepts(choices:)`), `QuestionsItem` (`skipped`, `answersMessage()`, `questions(from:)`: the rules, `checkedAnswer(_:for:)`), and on `ChatSession` `waitingQuestions(in:)`, `postQuestions(_:questions:)` and `answerQuestion(_:setID:label:answer:)`, as [Data › Questions](data.md#questions) says. `ChatItem.questions` holds the item; `ChatState.waitingAnswers` follows it. |
| `ChatManagement.swift` | `ContextUsage` (`left`, `percentLeft`, `from(_:received:)`), `ChatFile.contextUsage`; on `ChatSession`: `askContextUsage`, `received(contextUsage:success:for:)`, `compactions(in:)`, `close`, `closeNow`, `reopen`, `delete` (to its `trash`), `needsResume`, `resume`, `CloseResult` and `closeChats(_:caller:)`. `ChatRun` holds `closesAfterTurn`, `contextRequestID`, `contextAskedAgain`, `lastAssistantMessage`. |
| `ChatAgents.swift` | `ChatAgentState`, `ChatWorkflow`, `ChatAgent` (`Kind`, `inBackground`), `ChatAgents` (`read(_:)`, `put`), `AgentTranscriptLine`, `WorkflowFolderReader` (`newLines(_:)`, by byte offsets), and on `ChatSession`: `agentRecords`, `agentTranscripts`, `workflowFolders`, `workflowReaders`, `agents(of:)`, `loadAgents`, `noteAgents(of:in:)` (after each recorded item), `applyTaskLine(_:in:)` (`StreamOutput.taskLine`), `applyWorkflowLaunch`, `readWorkflowFolder`, `stopForegroundAgents` (each `result`), `stopAllAgents` (the exit), `agentTranscript(_:in:)`, `openAgent`, `stopWorkflow` (`ChatRun.stopRequests`, `stopAnswered`), `resumeAgent`, as [Data › Agents](data.md#agents) says. |
| `ChatPickers.swift` | `PickerKind` (`symbol`, `color`, `sound`, `shortcut`, `font`, `animation`; `toolName`, `title`, `markerScheme`, `needsApplicationProject`, V2's messages), `PickerSuggestion` (a value, or a pair's light and `dark`), `ShortcutInUse`, `PickerItem` (V2's keys, `otherKeys` kept; `answerMessage`, `marker(_:)`, `pairMarker(light:dark:)`, `line(_:)`; `request(_:from:catalogs:created:)`: the rules; `checkedAnswer(_:)`), `PickerCatalogSnapshot`, and on `ChatSession` `waitingPicker(in:)`, `waitingConflict(in:)` (questions or a request: `postQuestions` uses it too), `pickerCatalogs(_:for:)`, `projectFiles(ofProject:)`, `soundFile(named:projectRoot:)`, `postPicker(_:kind:input:)` and `answerPicker(_:requestID:answer:)`, as [Data › Picker requests](data.md#picker-requests) says. `ChatItem.picker` holds the item; `ChatState.waitingAnswers` follows it. |
| `PickerCatalogs.swift` | `PickerCatalogs` (actor: `Sources` with `system(runner:environment:)`; `symbols()`, `systemSounds()`, `installedFonts()` read once; `sounds(project:files:)`, `fonts(project:files:)` at each call), `ProjectFiles` (git's files, else a walk), `SFSymbolCatalog`, `SoundCatalog` (`SystemSounds`, `Runtime`, `search`, `listRuntimes`), `FontFace`, `FontFamily`, `FontCatalog` (`search`, `nearestFace`, `nameFace`, `readInstalledFamilies`, `projectFamilies`), as [Data › Picker catalogues](data.md#picker-catalogues) says. `ChatSession.catalogs` holds them; `init(…catalogs:)` takes the sources (tests: fixtures). |
| `ChatShownImages.swift` | `ImagesItem` (`caption`, `images`, `contentType(ofSignature:)`), `ChatItem.images`, and on `ChatSession` `postImages(_:paths:caption:)`, as [Data › Images item](data.md#images-item) says; `ChatTools.showImage` calls it, and `ChatBlock.Content.images` shows it. |
| `ChatMentions.swift` | `ChatMentions` (`ids(in:)` of an item and of a transcript) and on `ChatSession`: `mentions` (published), `scanMentions()` (`mentionsScanned`, `mentionScan`, `mentionRescan`), `noteMentions(of:in:)` (called by `record`), `dropMentions(keeping:)` and `scanMentions()` (called by `reload`), `chats(mentioning:)`, as [Data › Mentioned ids](data.md#mentioned-ids) says. ChatData depends on TextFormats for `MarkdownItemIDs.linkedIDs(inMarkdown:)`. |
| `ChatNotifications.swift` | `ChatEvent` (`Kind` `needsYou`, `finished`; `chatID`, `projectID`, `title`, `detail`, `summaryInput`; `summaryLimit` 150, `inputLimit` 4,000, `cleanSummary(_:)`), and on `ChatSession`: `noticeTransition(_:from:to:)` (called by `refreshState` on each change of state), `event(_:chatID:chat:state:)`, `summary(of:)` (`notification-summary`, 30 s, two at a time through `summaryRuns` and `summaryWaiters`), `showing(_:inKeyWindow:view:)` and `isInKeyWindow(_:)` (on `keyViews`), `waitingChats`, `runningChats`, as [Data › Chat events](data.md#chat-events) says; a picker request's input is `<Kind> request:` and its question. `ChatSession.onEvent` and `onOpen` (called by `open(_:)` and by a chat that starts to show in the key window) are the notifier's hooks. |
| `MessageAttachment.swift` | `MessageAttachment` (`id`, `name`, `path`, `contentType`, `size`, `otherKeys`; `stored(id:name:chatID:size:)`, `contentType(ofName:)`, `url(inProject:)`), as [Data › Message files](data.md#message-files) says, `sizeLimit` (20 MB), `check(_:)` and `store(_:chatID:in:failure:)`, and `FeedbackReport.files(inMessage:chatID:root:)`, the files a feedback message of 1.0.31 to 1.0.33 names. `ChatSession.send(…files:)` stores a message's files. `UserItem.attachments` holds them; `post` takes them; `createFeedback` records its stored files. |
| `ChatFileTools.swift` | `ChatFileEdits` (`never`, `askFirst`, `always`), `ClaudeFileTools` (`reading` `Read`, `Grep`, `Glob`; `editing` `Edit`, `Write`, `NotebookEdit`; `question` `AskUserQuestion`; `disallowed(edits:)`, the value of `--disallowedTools`; `Decision` `allow`, `ask`, `deny(_:)`; `editRefusal`; `decision(tool:input:root:edits:)`, nil for another tool; `path(tool:input:root:)`; `Location` `inside`, `appData`, `outside`; `location(_:in:)`), as [Data › File tools](data.md#file-tools) says; on `ChatSession`, `fileEdits` (Ask First until `AppData` sets it to read Settings ▸ Chat) and `root(ofChat:)`. `ChatRun` gives the launch `tools(edits:)` and answers each `can_use_tool` with `decision`. |

- **`ChatSession`** (`@MainActor @Observable`, one for the app, made by `AppData`) publishes `chats` (every
  loaded project's, by id), `status`, `models`, `transcripts` (those read: of chats open in a window and of
  running ones, at most 12 others), `streaming`, `states`, `turnStarts`, `compacting`, `defaults` and
  `claudePath`. `start(tools:port:)` runs after the MCP server starts: settings, chats, file events, the
  projects' snapshot (`Observations`), then the CLI's check and model probe. Files are written on the main
  actor: metadata with `YAMLFile.write` and its `OwnWrites`, transcript lines with `Transcript.append`; only
  transcript reads go off the main actor.
- **Processes.** `send` writes the message's item, then writes it to the chat's `ChatRun` or launches one:
  a chat token from `MCPTokens.issue(forChat:)`, the MCP configuration, `ClaudeLaunching.launch`, the
  `initialize` request and the messages. A `Task` reads `connection.lines` on the main actor through the
  run's `StreamMapper`, then awaits the exit. Timers (start 60 s, idle 20 min, Stop's signals 5 s apart) are
  `Task`s on the run. Every rule is in [Data › Chat processes](data.md#chat-processes).
- **Approvals.** `requestApproval(_:tool:input:)` writes a `permissionRequest` item and suspends on a
  `CheckedContinuation` kept per chat and request; `answer`, `stop`, the exit and `stopAll` resume it. A
  CLI's `can_use_tool` request is kept with its input until `answer` writes the control response.
- **Testing.** Tests pass a `FakeLauncher` whose connections replay captures of the CLI (`ChatDataTests/Fixtures`)
  and record the lines written, and a runner that answers `--version`: no test starts Claude.

### MachineData

The virtual machines of [Data › Virtual machines](data.md#virtual-machines). No UI (it imports Virtualization),
no default isolation; `MachineHost`, `MachineRun`, `MachineConfiguration`, `MachineInstaller`, the
`GuestMachine` and `MachineBackend` protocols and their system implementations are `@MainActor`, as the
framework's machines are. Depends on FileStorage, MCPKit (`JSONValue`) and ProjectData (`DataFolder`, the
settings). Source files in `Sources/MachineData/`:

| File | Contents |
| --- | --- |
| `MachineFiles.swift` | `ImageFile` (`State`), `MachineFile`, `MachineFolder` (the files of a folder, `diskGB`, `bytesOnDisk`), `MachineLibrary` (`images`, `machines`, `readImages`, `readMachines`, `write`, `createMachine`, `clone`) |
| `MacOSVersions.swift` | `MacOSVersion`, `MacOSVersions` (`fetch`, `parse`, `compare`, `ListError`) |
| `GuestDisk.swift` | `GuestDisk` (`grow`, `growContainerCommand`), `PartitionTable`, `RecoveryMove`, `CRC32` |
| `MachineVirtualization.swift` | `MachineFailure`, `MachineConfiguration` (`agentPort`, `isSupported`, `platform`, `make`, `createDisk`, `newMACAddress`), `MachineInstaller.install`, `IPSWDownload`, `DHCPLeases` |
| `GuestAgent.swift` | `GuestAgentFrame`, `GuestAgentError`, `GuestAgentStatus`, `GuestAgentResponse`, `GuestAgentConnection` (`open`, `request`, `refreshStatus`, `shutDownGuest`, `close`) |
| `GuestMachine.swift` | `GuestMachineEvent`, `GuestMachine`, `MachineBackend`, `SystemMachineBackend`, `MacGuestMachine` (the framework's machine, its socket listener, start and stop in order, pause, resume), `GuestTools` (`bundled(in:)`, `installCommand`, `fill`) |
| `MachineHost.swift` | `MachineError` (`Kind`), `MachineDefaults` (ranges from this Mac), `MachineRun` (`State`, `agent`, `address`, `isRestarting`), `ShellResult`, `MachineHost` (`load`, `loadVersions`, `addImage`, `setAccount`, `deleteImage`, `startSetup`, `restartInRecovery`, `finishSetup`, `stopSetup`, `createMachine`, `start`, `stop`, `pause`, `resume`, `updateMachine`, `deleteMachine`, `setDefaults`, `stopAll`, `agentRequest`, `shell`, `screenshot`) |
| `GuestFiles.swift` | `GuestShell` (`quote`, `path`, `isGuestPath`), `MachineHost.copyIn`, `copyOut` (8 MiB chunks, tar for folders) |

`MachineHost` is `@Observable`: `images`, `machines`, `progress`, `downloadSizes`, `runs`, `setups`,
`installing`, `versions`, `defaults`, `failures`. `AppData` makes one with the data folder and the system backend,
loads it after the projects, and stops everything at quit. Tests pass a `FakeBackend` making `FakeGuest`s: no test
downloads, installs or starts a machine.

## ToolsFoundation

The vocabulary every target speaks. Its data types are `nonisolated public` value types, `Hashable` and
`Sendable`, so that windows can carry them as `WindowGroup` values and focused values even though the target
defaults to the main actor.

| File | Contents |
| --- | --- |
| `Project.swift` | `Project`, `ProjectTint`, `DeploymentEnvironment`, `ProjectActivity`, `SampleClock`, `ProjectTree` |
| `SampleProjects.swift` | `Project.samples`, `Project.tree`, `Project.sample(_:)`, `deploymentEnvironments` |
| `Vocabulary.swift` | `TicketStatus`, `TimeWindow` |
| `Routing.swift` | `ToolKind`, `Route` (with `.projectSettings(id)`), `OpenRouteAction`, `FocusRequest`, `onFocusRequest(_:)`, the `activeProject` focused value |
| `ProjectDirectory.swift` | `ProjectDirectory` (`state`, `tree`, `projects`, `unavailable`, `project(_:)`, `update(projects:state:unavailable:)`, `samples()`), `ProjectDirectory.State`, `ProjectDirectory.Unavailable`, the `projectDirectory` and `availableTools` environment values |
| `NewItemCommand.swift` | `NewItemCommand`, the `newItem` focused value, `newItemCommand(_:action:)` |
| `ChatVocabulary.swift` | `ChatReference`, `ToolReading`, `ToolReader`, `ReportChatSubjectAction`, `ChatPanelControl`, `ChatPanelToolbarItem`, `MentioningChat` (`State`, `Kind`: `chat`, `implement`, `ci`, `feedback`) and `ChatMentionsReader` (`\.chatMentions`), `ItemChatsReader` (`\.itemChats`: a ticket's or bundle's own chats), `ImplementTarget` and `ImplementAction` (`\.implement`: the window opens the Implement sheet) |
| `PlaySoundAction.swift` | `PlaySoundAction` (a `@MainActor @Sendable` closure from a sound's name and the view's project folder to the failure's message, called with `callAsFunction(_:projectRoot:)`) and the `playSound` environment value, nil by default: ToolsScenes sets it in `RouteHost` to `ChatSounds.player(appData.chats)`; a sound marker's ▶ calls it ([Text › Markers › Sounds](text.md#sounds)) |
| `Dashboard.swift` | `DashboardWidget`, `DashboardCells`, `DashboardGrid`, `DashboardWidgetKind`, `DashboardProjectField`, `DashboardContext` |
| `GenerateTitleAction.swift` | `GenerateTitleError` (`message`), `GenerateTitleAction` (a `@MainActor @Sendable` closure from a description and a `GenerateTitleAction.Ticket?` (`id`, `projectID`: the ticket the run links, nil in New Ticket) to a title, `async throws(GenerateTitleError)`, called with `callAsFunction(_:ticket:)`) and the `generateTitle` environment value, nil by default: ToolsScenes sets it in `RouteHost` to `AppData.generateTitle`; **Generate Title** shows only with it |
| `DashboardWidgetRenderer.swift` | `DashboardWidgetRenderer` (a `@MainActor @Sendable` closure from `(DashboardWidget, DashboardContext)` to `AnyView`, called with `callAsFunction`) and the `dashboardWidgetRenderer` environment value, nil by default: ToolsScenes sets it in `RouteHost` to its `DashboardWidgetView`, so that a window can draw another tool's widget (the project overview's graph) |
| `Appearance.swift` | Titles, symbols, shortcuts and colors of the shared types |
| `Components.swift` | `ProjectIcon` |

### Projects

`Project: Identifiable, Hashable, Sendable`:

| Property | Type | Meaning |
| --- | --- | --- |
| `id` | `String` | The identifier, also its tickets' prefix: `ORD`. |
| `name` | `String` | `Orders`. |
| `kind` | `Project.Kind` | `.service`, `.app`, `.library` or `.other` (`String` raw values, `CaseIterable`; titles Service, App, Library, Other; sections Services, Apps, Libraries, Other Projects; symbol `folder` for Other). |
| `tint` | `ProjectTint` | `.accent`, `.accentSecondary`, `.info`, `.success` or `.warning`; each is the AZDesign color of the same name (`color`). |
| `symbol` | `String` | An SF Symbol name. |
| `path` | `String` | The folder, such as `~/Developer/Services/shop/orders`. |
| `repository` | `String` | Such as `services/orders`. |
| `environments` | `[DeploymentEnvironment]` | Where the project runs, whatever its type. Default `[]`. For the app's projects, as they apply (`environmentsAreResolved`); for a sample, its own. |
| `activity` | `ProjectActivity?` | The figures the Projects window shows; nil for the app's projects until their tools report them. |
| `parentID` | `Project.ID?` | The project whose folder holds this one; nil at the top level. Default nil. |
| `environmentsAreResolved` | `Bool` | True for the app's projects: `environments` already apply inheritance, and `ProjectTree.environments(of:)` returns them as they are. Default `false`. |
| `githubPage`, `currentEnvironment`, `fileIssue` | `String?` | The resolved GitHub page, the environment the user works in, and why the project's file is invalid now. Default nil. |
| `graphEnabled` | `Bool` | Whether the project's graph is on, resolved (`ResolvedSettings.graphEnabled`); the samples Shop, Orders, Payments and Edge Gateway have it. Default `false`. |

`tools: [ToolKind]` decides which tools apply, in menu order:

| Kind | Tools |
| --- | --- |
| Service with `activity.contractVersion` | dashboard, tickets, serviceMap, contracts, builds, chat |
| Service without one | dashboard, tickets, serviceMap, builds, chat |
| App, library | dashboard, tickets, builds, chat |

`DeploymentEnvironment: Identifiable` has `name` (its `id`), `cluster: String?`, `namespace: String?`,
`url: String?` (the base URL), `health: Health?` (`.healthy`, `.degraded`, `.down`; nil until the Service
Map reads it), `deployment`, `jaeger`, `argoCDApplication`, `kubeconfig` (all `String?`),
`allowsInvalidCertificates: Bool` and `inheritedFrom: Project.ID?` (the parent it comes from);
`inherited(from:)` gives a copy with `inheritedFrom` set. Appearance adds `healthTitle` (Unknown
without health), `healthSymbol`, `healthColor` and `place` (`<cluster> / <namespace>`, or the one known).

`ProjectActivity` has `openTickets`, `ticketsInReview`, `draftTickets`, `lastBuild` (`BuildOutcome`:
`.passed`, `.failed`, `.running`), `lastBuildAt`, `contractVersion: String?` (default nil), `operationCount`
and `serviceCount` (default 0). In the real suite each tool would answer these figures.

**`ProjectTree`** wraps the flat list `projects: [Project]` and walks it:

| Member | Returns |
| --- | --- |
| `project(_ id: Project.ID?)` | The project with that id. |
| `children(of: Project.ID?)` | Direct sub projects, in list order; the top-level projects for nil. |
| `descendants(of:)` | Every sub project at any depth, depth first. |
| `family(of:)` | The project, then its descendants. |
| `ancestors(of:)` | Its ancestors, the top-level one first. |
| `depth(of:)` | 0 at the top level, 1 for a sub project, and so on. |
| `ordered(topLevel:)` | `[(project:, depth:)]`: each top-level project followed by its descendants. |
| `environments(of:)` | The environments as they apply: an app's project's as they are; for a sample sub project, its parent's (as this resolves them, each `inherited(from:)` the parent), then its own whose names they don't have. |
| `ticketTotals(of:)` | `(open:, inReview:, drafts:)` summed over the family. |
| `path(of:)` | The names of the ancestors and the project, joined with `" › "`: `Shop › Orders`. |

### Sample projects and the sample clock

`SampleClock.date(days:hours:minutes:)` is 11 November 2026 at 14:00 in `Calendar.current`, moved by the
given amounts. Every sample date uses it, so previews always show the same thing.

`Project.samples` holds seven projects, in this order. `Project.tree` is `ProjectTree(samples)`, and
`Project.sample(_:)` finds one by id.

| Id | Name | Kind | Tint | Symbol | Parent | Contract | Services |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ORD` | Orders | service | accent | `cart` | `SHOP` | 1.4.0, 6 operations | 8 |
| `PAY` | Payments | service | success | `creditcard` | `SHOP` | 2.1.0, 4 operations | 8 |
| `GW` | Edge Gateway | service | info | `network` | `SHOP` | 1.0.2, 3 operations | 8 |
| `TLS` | Tools | app | accentSecondary | `wrench.and.screwdriver` | — | — | — |
| `AZD` | AZDesign | library | warning | `paintpalette` | — | — | — |
| `SHOP` | Shop | service | accentSecondary | `storefront` | — | — | 9 |
| `TKIT` | ToolsKit | library | info | `shippingbox` | `TLS` | — | — |

The services have three environments, Local (`docker-desktop`), Staging (`staging-eu`) and Production
(`prod-eu`), all in the namespace `shop`. Their figures, paths and health are in the source and in
[Projects](ui/projects.md). `Project.deploymentEnvironments` is `Project.tree.environments(of: id)` for a
sample project, else its own `environments`: the environments every tool reads.

### Shared vocabulary

| Type | Cases | Notes |
| --- | --- | --- |
| `TicketStatus` | `draft`, `created`, `inProgress`, `inReview`, `done` | `String` raw values, `Codable`, `CaseIterable` in workflow order. In ToolsFoundation because the Dashboard's Tickets widget counts by status. |
| `TimeWindow` | `fiveMinutes`, `hour`, `day` | `String` raw values, `Codable`. `minutes`: 5, 60, 1,440. Shared by the Service Map and the service widgets. |

`Appearance.swift` gives the shared types their words and looks. Every title is `String(localized:bundle: #bundle)` from ToolsFoundation's catalog.

| Type | Members |
| --- | --- |
| `ToolKind` | `title`, `symbol`, `shortcut` (below) |
| `TicketStatus` | `title`: Draft, Created, In Progress, In Review, Done |
| `TimeWindow` | `title`: 5 min, 1 hour, 24 hours |
| `Project.Kind` | `title` (Service, App, Library), `pluralTitle` (Services, Apps, Libraries), `symbol` (`server.rack`, `macwindow`, `books.vertical`) |
| `ProjectTint` | `color` |
| `DeploymentEnvironment.Health` | `title`, `symbol` (`checkmark.circle.fill`, `exclamationmark.triangle.fill`, `xmark.octagon.fill`), `color` (success, warning, danger) |
| `ProjectActivity.BuildOutcome` | `title`, `symbol` (`checkmark.circle.fill`, `xmark.circle.fill`, `arrow.triangle.2.circlepath`), `color` (success, danger, info) |
| `DashboardWidgetKind` | `title`, `symbol` |
| `DashboardProjectField` | `title`: Name, Identifier, Type, Folder |

### Tools

`ToolKind: String, CaseIterable, Identifiable, Codable, Sendable` names the tools, each shown in a tab for one
project at a time.

| Case | `title` | `symbol` | `shortcut` (with ⌘) |
| --- | --- | --- | --- |
| `dashboard` | Dashboard | `square.grid.2x2` | 1 |
| `tickets` | Tickets | `checklist` | 2 |
| `serviceMap` | Service Map | `point.3.connected.trianglepath.dotted` | 3 |
| `contracts` | Contracts | `curlybraces.square` | 4 |
| `builds` | Builds | `hammer` | 5 |
| `chat` | Chat | `bubble.left.and.text.bubble.right` | 6 |

Projects and Virtual Machines aren't tools: they have no `ToolKind`.

### Routes

| Type | Definition |
| --- | --- |
| `Route` | `.project(Project.ID)`, `.projectWindow(Project.ID)`, `.tool(ToolKind, project: Project.ID, focus: String? = nil)`, `.machine(String? = nil)`, `.projectSettings(Project.ID)`. `Hashable, Sendable`. |
| `OpenRouteAction` | Wraps `@MainActor @Sendable (Route) -> Void`; called as `openRoute(route)`. |
| `EnvironmentValues.openRoute` | The action. Its default does nothing, so previews open nothing. |
| `FocusedValues.activeProject` | `Project?`: the key window's selected tab's project, for the menu commands. |
| `FocusRequest` | `Equatable, Sendable`: `focus: String` plus a private `UUID`, so every request is a new value, even for the same item. |
| `EnvironmentValues.focusRequest` | `FocusRequest?`: the latest route's request for this tab. Default nil. |
| `View.onFocusRequest(_ select: @escaping (String) -> Void)` | Runs `select(request.focus)` on each change of `focusRequest` (through a private `FocusRequestModifier`). |

A route's focus reaches a tool in one of two ways:

1. **A tab that opens** gets the focus in its `WorkspaceTab.focus`. The tool's tab state passes it to its
   model's initializer, which selects it.
2. **A tab already open** gets a new `FocusRequest` in its environment (`Workspace.focusRequests`). The root
   view applies `onFocusRequest { model.select(focus: $0) }`, which selects the item without starting afresh:
   filters, modes and scroll positions stay.

The focus formats are listed in [Navigation › Routes](ui/navigation.md#routes) and under each kit below.

### File ▸ New item

`NewItemCommand` holds a menu title (`"New Ticket…"`, with an ellipsis when it asks for more) and a
`@MainActor () -> Void` action, called as `newItem()`. `FocusedValues.newItem` carries the key window's
command. A view provides one with `newItemCommand(_ title:action:)`, which is
`focusedSceneValue(\.newItem, NewItemCommand(title, action: action))`. ToolsScenes turns it into the
File menu's ⇧⌘N item.

### Chat vocabulary

The chat never looks into a tool's window. A tool says which item it has selected, as a reference, and the
chat reads that item through the tool's own read function.

| Type | Definition |
| --- | --- |
| `ChatReference` | `Hashable, Codable, Sendable, Identifiable`: `tool: ToolKind`, `projectID`, `focus` (in the tool's focus format), `title` (as a chip names it: `ORD-142`, `payments-api`, `Run 1288`), `environment: String?` (set by the Service Map only). `id` is `"<tool>/<project>/<focus>"`, plus `"@<environment>"` when there is one. `route` is `.tool(tool, project: projectID, focus: focus)`. |
| `ToolReading` | `Hashable, Sendable`: `action` (`Read ticket ORD-142`), `detail` (the gist in a sentence), `suggestions: [String]` (questions for the item's current state, worded by the tool). |
| `ToolReader` | Wraps `@MainActor @Sendable (ChatReference) -> ToolReading?`; called as `toolReader(reference)`. |
| `EnvironmentValues.toolReader` | Default reads nothing. ToolsScenes sets the app's reader. |
| `ReportChatSubjectAction` | Wraps `@MainActor @Sendable (ChatReference?) -> Void`. |
| `EnvironmentValues.reportChatSubject` | A tool calls it with its selected item. Default does nothing. |
| `ChatPanelControl` | `isShown: Binding<Bool>`; `toggle()` flips it inside `withMotion(.panel)`. |
| `EnvironmentValues.chatPanel` | `ChatPanelControl?`: the window's panel, nil where there is none. |
| `ChatPanelToolbarItem` | `ToolbarContent`, `init(pushesToTrailingEdge: Bool = false)`. Shows nothing when `chatPanel` is nil. Otherwise an optional `ToolbarSpacer(.flexible, placement: .primaryAction)`, then a `.primaryAction` button "Chat" with `sidebar.right` that calls `toggle()`, its help "Show the Chat Panel (⌃⌘C)" or "Hide the Chat Panel (⌃⌘C)", identifier `toolbar.chatPanel`. |

See [Components › Chat panel button](ui/components.md#chat-panel-button).

### The Dashboard model

The Dashboard's data types live here, not in DashboardsKit, because each tool draws its own widgets from
them and tools can't import DashboardsKit. The grid and its placement rule are specified in [Dashboard ›
Grid, Placement, Lists without positions](ui/dashboard.md#grid).

**`DashboardWidget`** (`Sendable, Hashable, Identifiable`): what the Dashboard shows of a widget. DashboardsKit's
`LiveDashboardStore` maps it to and from the project file's `DashboardWidgetEntry` (ProjectData).

| Property | Type | Default | Used by |
| --- | --- | --- | --- |
| `id` | `UUID` | `UUID()` | |
| `kind` | `DashboardWidgetKind` | | |
| `title` | `String` | `""` (the kind's title shows) | every kind |
| `column`, `row`, `width`, `height` | `Int?` | nil (no stored position) | every kind |
| `fields` | `[DashboardProjectField]` | all | Project |
| `statuses` | `[TicketStatus]` | all | Tickets |
| `includeSubprojects` | `Bool` | `true` | Tickets |
| `count` | `Int` | `5` | Recent Builds, Busiest Calls, Failed Requests |

- `countRange = 1...20`; `titleLimit = 100`.
- `cells: DashboardCells?` gets the four position values, brought inside the grid by `DashboardGrid.clamped`,
  or nil when any is missing; setting it writes all four.
- `defaultList(for:)`: Project, Tickets, Recent Builds, plus Service Graph when `showsGraph(project)`, with
  the ids `00000000-0000-0000-0000-00000000000<n>`.
- `DashboardWidgetKind` also has `recentChats` and `cost`, kept and never shown. `isShown(for:tools:)`: Project
  always; Tickets with `.tickets`; Recent Builds with `.builds`; Instances with `.serviceMap`; the four service
  widgets with `.serviceMap` and `showsGraph(project)`; Recent Chats and Cost never. `shown(for:tools:)` is
  the set of those kinds; `addable(for:tools:)` the shown kinds, Instances only for a service.
- `DashboardGrid.layout(of:shown:rows:)` places the widgets whose kind is in `shown`; the others get nil and
  take no place.
  Their ids are fixed: `00000000-0000-0000-0000-00000000000N`, N from 1.

**`DashboardCells`** (`column`, `row`, `width`, `height`; `bottom`; `overlaps(_:)`).

**`DashboardGrid`**:

| Member | Value or role |
| --- | --- |
| `columns` | 24 |
| `halfWidth` | 12: the width of a widget without position and of an added widget |
| `rowLimit` | 100,000: the largest stored row and height counted |
| `rowBound` | `Int.max / 2` (internal) |
| `clamped(_:)` | Width 1–24, a column that keeps the widget inside, row 0…`rowLimit`, height 1…`rowLimit`. |
| `placed(_:first:)` | The placement rule. `first` is the widget being moved or resized. |
| `layout(of:graphEnabled:rows:)` | The cells of each widget of a list (nil for a hidden service widget). |
| `layout(_:placing:at:)` | The arrangement once one widget covers new cells. |

**`DashboardWidgetKind`** (`String` raw values, `Codable`, `CaseIterable`): `project`, `tickets`,
`recentBuilds`, `instances`, `serviceGraph`, `busiestCalls`, `failedRequests`, `requestsPerMinute`.

| Member | Meaning |
| --- | --- |
| `isGraph` | True for `serviceGraph`, `busiestCalls`, `failedRequests`, `requestsPerMinute`: hidden when the map can't be read. |
| `fillsWidget` | True for `serviceGraph` and `requestsPerMinute`. |
| `hasCount` | True for `recentBuilds`, `busiestCalls`, `failedRequests`. |
| `hasServiceMap(_:)` | The project has the Service Map tool and at least one environment (the Dashboard tile's text). |
| `showsGraph(_:)` | `hasServiceMap` and the project's `graphEnabled`: the graph widgets and the overview's graph show. |
| `addable(for:)` | The Add Widget menu's kinds: `instances` only for a service, graph kinds only with `showsGraph`. |

**`DashboardProjectField`**: `name`, `identifier`, `type`, `folder`.

**`DashboardContext`**: `project`, `environment: DeploymentEnvironment?`, `window: TimeWindow`, `editing: Bool`
(in edit mode a widget's content takes no click). Every widget view takes `(DashboardWidget, DashboardContext)`.

### Components

`ProjectIcon(_ project:)`: the project's symbol in its tint, hidden from VoiceOver. Every other shared
component comes from AZDesign.

## ToolsScenes

`ToolsScenes.swift` (the scenes, `RouteHost`, the commands, the tool reader, the widget mapping, Mac widths),
`Workspace.swift` (a window's tabs), `WorkspaceView.swift` (the window: tab bar, tabs, chat panel),
`WindowDirectory.swift` (the windows and their tabs, for routes), `AppData.swift` (the app's data),
`AppTools.swift` (the MCP server's tools), `Implementer.swift` (Implement: `Implementer`, its checks, `implement_ticket` and `implement_bundle`; `watchCI(_:caller:)` and `watch_ci`, which link a CI chat to its ticket or bundle; and `implementSheet()`, which gives a tab `\.implement` and shows ChatKit's `ImplementView`), `MCPSettingsView.swift` (Settings ▸ MCP), `GeneralSettingsView.swift`
(Settings ▸ General), `NotificationSettingsView.swift` (Settings ▸ Notifications), `ChatNotifier.swift` (the
chats' notifications, the Dock's badge and bounce), `StatusBar.swift` (the status bar, its chat counts and
feedback) and `WindowCapture.swift` (a window's PNG). Its only public type is `public struct ToolsScenes: Scene` with `public init()`, which sets
`NSWindow.allowsAutomaticWindowTabbing = false`: the app draws its own tabs, and macOS adds neither its tab
items nor its tabs ([Navigation › Tabs](ui/navigation.md#tabs)).

### Scenes

`SceneID.workspace = "workspace"`. Every scene's content is wrapped in `RouteHost`.

| Scene | Type | Id | Content | Default size | At launch |
| --- | --- | --- | --- | --- | --- |
| Window | `WindowGroup(Text(verbatim: "Hephaestus V3"), id:, for: WorkspaceValue.self)`, `.commands { NewItemCommands(); ToolCommands(); TabCommands(); ChatPanelCommands(); FeedbackCommands() }` | `workspace` | `WorkspaceRoot(value: $value, appData:, selectedProjectID: $selectedProjectID, machineFocus:, machineFocusRequest:)` | 1320 × 840 | Opens, with no value: Projects |
| Menu bar | `MenuBarExtra(String(localized: "Open Project"), systemImage: "wrench.and.screwdriver")`, `.menuBarExtraStyle(.window)` | — | `ProjectLauncher(projects: appData.directory.projects)` | 360 × 460 (the panel's own) | Always present |
| Settings | `Settings` | — | `TabView(selection:)` on `@AppStorage(SettingsPane.storageKey)` (each tab tagged with its `SettingsPane` raw value): `GeneralSettingsPane(appData:)` labeled General (`gearshape`), `ProjectsSettingsPane(session: appData.session)` labeled Projects (`folder`), `MCPSettingsPane(appData:)` labeled MCP, `MachineSettingsView(store: appData.machineStore)` labeled Virtual Machines (`desktopcomputer`) while it is available, then `ChatSettingsView()` labeled with Chat's title and symbol and `NotificationSettingsPane(appData:)` labeled Notifications (`bell.badge`) while Chat is available; `.frame(width: 520, height: 440)`, `.tint(.accent)` | 520 × 440 | — |
| Chat window | `WindowGroup(Text(verbatim: "Chat"), id:, for: ChatWindowValue.self)`, `.defaultSize(width: 720, height: 820)`, `.windowResizability(.contentMinSize)` | `chat` (`SceneID.chat`) | `ChatWindowScene(value:)`: `ChatWindowView(chatID:)` (ChatKit) at least 480 × 480, `.statusBar(_:countsChats: false)` with the source "Chat", the chat's project and title, and a `WindowReader` that calls `WindowDirectory.shared.register(_:chat:)` | 720 × 820 | Restored with its `ChatWindowValue` (`chatID`) |

macOS restores the windows open at quit with their `WorkspaceValue`: their tabs, each tab's focus, and the
selected tab.

**`AppData`** (`AppData.swift`, `@MainActor @Observable`) is the app's data, created once as ToolsScenes'
`@State`: `session = ProjectSession(dataFolder: DataFolder.resolve())` and `directory =
ProjectDirectory(projects: [], state: .loading)`. `start()` runs once, from the first `RouteHost`'s `.task`:
it starts following the session (`withObservationTracking { directory.update(from: session) }`, registered
again after each change), adds an observer of `NSApplication.willTerminateNotification` that calls
`SystemProcessRunner.shared.terminateAll()`, the chats' `stopAll()` and the machine host's `stopAll()`, awaits
`session.start()`, reads `settings.yml`, then loads the machine host (`machineHost.load()`). `AppData` also holds
`machineHost = MachineHost(dataFolder: DataFolder.resolve())` and `machineStore = LiveMachineStore(host:)`, and
gives the host to the MCP registry's `vm_` tools. `AppData.availableTools` (every tool) and
`AppData.machinesAvailable` (true) say which tools the app shows, all of them
([Navigation › Available tools](ui/navigation.md#available-tools)): the Window menu lists only those, and
`RouteHost` gives every view `\.availableTools`, `\.projectDirectory` and `\.dashboardWidgetRenderer` (each tool's
widgets, as the Dashboard draws them).

`ToolsScenes` keeps three `@State` values that every `RouteHost` gets as bindings, and every window's
`WorkspaceRoot`:

| State | Initial | Role |
| --- | --- | --- |
| `selectedProjectID: Project.ID?` | nil | Projects' selection; routes set it. Projects is one tab in the whole app. |
| `machineFocus: String?` | nil | The machine the Virtual Machines tab opens on. |
| `machineFocusRequest: FocusRequest?` | nil | A route's request for the open Virtual Machines tab. |

### RouteHost and route handling

`private struct RouteHost<Content: View>` reads `@Environment(\.openWindow)` and gives its content
`.environment(\.openRoute, …)`, `.environment(\.toolReader, appToolReader(…))`, the stores
(`\.serviceMapStore`, `\.contractStore`, `\.buildStore`, `\.ticketStore`, `\.dashboardStore`, `\.chatStore`),
`\.projectDirectory`, `\.availableTools`, `\.dashboardWidgetRenderer`, `\.feedbackTarget`, and `.tint(.accent)`;
its `.task` stores the first `OpenRouteAction` in `appData.openRoute` (for `open_in_app`) and runs
`appData.start()`. Its `OpenRouteAction` is the one place where routes are opened, through `WindowDirectory`:

| Route | Handling |
| --- | --- |
| `.project(id)` | Sets `selectedProjectID = id`, then `showOrOpen(.projects)`. |
| `.projectWindow(id)` | `show(where: { $0.tab(showingProject: id) })`: in the frontmost window that has one, its selected tab when it shows the project, else its first tab that does. If none, as `.project(id)`. |
| `.tool(tool, project, focus)` | `showOrOpen(.tool(tool, project:), focus: focus)`. |
| `.projectSettings(id)` | `showOrOpen(.projectSettings(id))`. |
| `.machine(id)` | Sets `machineFocus = id`. If `show(.machines)` succeeds and `id` isn't nil, sets `machineFocusRequest = FocusRequest(id)`. Otherwise `open(WorkspaceTab(content: .machines))`. |

Behavior is specified in [Navigation › Routes and Window reuse](ui/navigation.md#routes).

### The tool reader

`appToolReader(directory:tickets:builds:)` makes the `ToolReader` every window gets: it finds the project of
`reference.projectID` in the app's directory (else a sample project; nil if none), then dispatches on
`reference.tool`:

| Tool | Read function |
| --- | --- |
| `.tickets` | `TicketsReader.read(reference.focus, store: appData.ticketStore)` |
| `.serviceMap` | `ServiceMapReader.read(reference.focus, environment: reference.environment, project: project, store: appData.serviceMapStore)` |
| `.contracts` | `ContractsReader.read(reference.focus, project: project, store: appData.contractStore)` |
| `.builds` | `BuildsReader.read(reference.focus, project: project, store: appData.buildStore)` |
| `.dashboard`, `.chat` | nil |

### Tabs: Workspace

`Workspace.swift` holds a window's tabs ([Navigation › Tabs](ui/navigation.md#tabs)).

- **`WorkspaceContent`** (`Codable, Hashable, Sendable`): `.projects`, `.tool(ToolKind, project: Project.ID)`,
  `.projectSettings(Project.ID)`, `.machines`, `.systemPrompts`. `projectID` is the tool's or the settings' project; `tool` the
  tool; `isSingle` is true for all but a tool (Projects, a project's settings and Virtual Machines are each one
  tab in the app, which routes select; New Tab and New Window make none).
- **`WorkspaceTab`** (`Codable, Hashable, Identifiable, Sendable`): `id: UUID`, `content`, `focus: String?` (the
  item the tab has selected, which its tool starts on when the window is restored).
- **`WorkspaceValue`** (`Codable, Hashable, Sendable`): `tabs`, `selection: UUID?` (the first tab when nil).
  `init(_ content:focus:)` makes a window of one tab; `.initial` is Projects. It is the window's scene value.
- **`Workspace`** (`@MainActor @Observable`), one per window, made by `WorkspaceRoot` from its value (an empty
  list gives Projects; an unknown selection, the first tab):
  - `tabs`, `selection`, `selectedTab` (the selected tab, else the first), `showsTabBar` (two tabs or more),
    `subjects: [UUID: ChatReference]`
    (each tab's reported item), `focusRequests: [UUID: FocusRequest]` (a route's focus for an open tab),
    `lastProjectID` (the project of the last selected tab that showed one), and `value`.
  - `select(_:)` (and `lastProjectID`), `selectNext()` and `selectPrevious()` (wrapping), `add(_:)` (after the
    selected tab, then selected), `remove(_:) -> WorkspaceTab?` (drops what the tab keeps; selects the next tab,
    else the one before), `move(_:to:)` (clamped), `switchProject(of:to:)` (a tool tab's project: the focus,
    the kept state, the subject and the request go), `report(_:in:)` (sets the subject, and the focus when
    there is a subject), `request(_:in:)`, `tab(_:)`, `tab(showing:)` (the first tab of that content),
    `tab(showingProject:)` (the selected tab when it shows the project, else the first that does).
  - `state(for:make:)`: the kept tool state of a tab on its current content, else a new one from `make`,
    kept (not observed). `keepsState(of:)` is for tests.
  - `panel(for:make:)`: the chat panel's `ChatPanelModel` for a project, kept for the window's life.

Each tool kit has a public tab state that owns its model (`DashboardTabState(project:store:)`,
`TicketsTabState(project:focus:store:directory:)`, `ServiceMapTabState(project:focus:store:)`,
`ContractsTabState(project:focus:store:)`, `BuildsTabState(project:focus:store:)`,
`ChatTabState(project:focus:store:directory:)`, `MachinesTabState(focus:store:)`), and a root view
`init(state:)` (`DashboardRootView(state:widgetContent:)`) that starts from that model. Only the selected tab
is drawn: a tab that comes back gets its kept model, with its selection, filters and drafts; its views' own
`@State` (scroll positions, open popovers) starts afresh. Projects and Project Settings start from the
project data each time.

### The window: WorkspaceView

`WorkspaceRoot` (`WorkspaceView.swift`) takes the scene's `@Binding value: WorkspaceValue?`, `appData`, the
Projects selection and the machine focus, keeps a `@State Workspace` made from the value (or `.initial`), and
writes `workspace.value` back to the binding on every change (`onChange(of:initial: true)`), for restoration.
`WorkspaceWindow` draws it:

| State | Type | Role |
| --- | --- | --- |
| `@SceneStorage("chatPanelShown") chatPanelShown` | `Bool`, true | Whether this window shows the chat panel; per window, across launches. |
| `@AppStorage(ChatPreferences.showsPanelKey) chatPanelEnabled` | `Bool`, true | Settings ▸ Chat: whether windows offer the panel. |
| `@State adaptiveWindow` | `AdaptiveWindowState()` | The window's measured size and size classes. |

Constants: `panelWidth = 341` (the panel with its divider), `minimumWidth = 390`; the minimum height is 420.
For the selected tab: `offersChatPanel = chatPanelEnabled && tool != .chat`; `showsChatPanel = offersChatPanel
&& chatPanelShown`; `layout = adaptiveWindow.layout(macWidth: tool?.macLayoutWidth ?? 760, sidePanelWidth:
showsChatPanel ? 341 : 0)`.

1. An `HStack(spacing: 0)`: a `VStack(spacing: 0)` of `TabBar` and a `Divider` while `showsTabBar`, then the
   selected tab's `TabContentView` (`.id(tab.id)`, filling); then, in the `.mac` layout with the panel shown, a `Divider` and the
   panel, 341 wide, with `.motionTransition(.panel, edge: .trailing)`.
2. In `.pad` and `.phone`, the panel is an overlay at the trailing edge instead: after a `Divider` (not in
   `.phone`), 341 wide (the window's width in `.phone`), with a shadow of radius 14 in `.pad`.
3. `.adaptiveWindow($adaptiveWindow, layout:)`, `.frame(minWidth: 390, minHeight: 420)`, then
   `.statusBar(FeedbackSource(…))` under everything.
4. `.environment(\.chatPanel, offersChatPanel ? ChatPanelControl(isShown: $chatPanelShown) : nil)`, and
   `focusedSceneValue` for `chatPanel`, `workspace`, `activeProject` (the tab's project; for Projects, its
   selection) and `activeTool`.
5. A `WindowReader` registers the window with `WindowDirectory.shared.register(_:workspace:)`.

**The panel**: `ChatPanel(project:origin: tab.content.tool ?? .dashboard, subject: workspace.subjects[tab.id],
model: workspace.panel(for: project.id) { ChatPanelModel(store: appData.chatStore) })`, whose hide closure
toggles `chatPanelShown`, on `.canvas`. Its project is the tab's (Projects: the selection), else
`workspace.lastProjectID`'s. Without any, a `ContentUnavailableView` "No Project", "Select a project to chat
about it." (`chatPanel.noProject`).

**`TabContentView`** draws the selected tab, with `.scrollEdgeEffectHidden(underTabBar, for: .top)` and
`.toolbarBackgroundVisibility(underTabBar ? .hidden : .automatic, for: .windowToolbar)`. A single tab's content
goes under the toolbar, and keeps both. Under the tab bar:

- the toolbar's edge effect would blur the content's first rows;
- a `NavigationSplitView` (AppKit's split view) gives each of its columns, inspector included, a titlebar
  background as high as the toolbar (52 pt, an `NSScrollPocket` in it) at its own top, as if the split view
  started at the top of the window. Under the tab bar it starts 37 pt lower, so those backgrounds cover the
  columns' first 52 pt with a band (seen in dark mode). The toolbar background's visibility hides them.

The screenshot tool can't show the band: it hosts SwiftUI in a plain `NSWindow`, whose columns' backgrounds draw
nothing. A SwiftUI `Window` scene does.

| Content | View |
| --- | --- |
| `.projects` | `ProjectsRootView(directory:session:selection: $selectedProjectID)`, `.toolbar { ChatPanelToolbarItem() }` |
| `.tool(tool, project)` | `ToolTab`; "No Project", "This tab's project isn't loaded. Pick another one in Projects." (`window.noProject`) when the directory doesn't have it |
| `.projectSettings(project)` | `ProjectSettingsWindow(session:projectID:)`, `.toolbar { ChatPanelToolbarItem() }` |
| `.machines` | `MachinesRootView(state: workspace.state(for:) { MachinesTabState(focus: machineFocus, store:) })`, `.environment(\.focusRequest, machineFocusRequest)`, `.toolbar { ChatPanelToolbarItem() }` |
| `.systemPrompts` | `SystemPromptsView(store: appData.skillStore)`, `.toolbar { ChatPanelToolbarItem() }` |

**`ToolTab`** builds the tool's root view from its kept state (`TicketsRootView(state: workspace.state(for: tab)
{ TicketsTabState(project:focus: tab.focus, …) })`, and so for each tool; the Dashboard's widgets through
`DashboardWidgetView`), with `.environment(\.focusRequest, workspace.focusRequests[tab.id])` and a
`ReportChatSubjectAction` calling `workspace.report(_:in:)`. It sets `.navigationTitle(Text(tool.title))`,
`.navigationSubtitle` (the project's path), `.toolbar(removing: .title)` below 760 points of width, and a
`.navigation` toolbar item `ProjectSwitcher(projects: directory.projects, selection:, tool:)` whose binding
calls `workspace.switchProject(of:to:)`. Each tool adds its own items and puts `ChatPanelToolbarItem()` last.

**`TabBar`** (`workspace`, `title`, `symbol`, `newTab: (() -> Void)?`, `moveToNewWindow`), 36 points high on
`canvas`: a horizontal `ScrollView` (indicators hidden, 8 points of padding) of `TabButton`s, 4 points apart,
each `min(240, max(120, (width − 16 − 4 × (count − 1)) / count))` wide; then, when `newTab` is set, a borderless
`plus` button (`tabs.new`, "New Tab (⌘T)"). A `DragGesture(minimumDistance: 6)` on each tab offsets it while
dragging; on release, a vertical move over 48 points gives it a window of its own (`moveToNewWindow`, with two
tabs or more), otherwise it moves by `round(dx / (width + 4))` places. `newTab` adds a tab of the selected tab's
content, for a tool's tab only. Closing the last tab closes the window (`performClose`). Identifiers:
`tabs`, `tabs.tab.<projects | tool.PROJECT | projectSettings.PROJECT | machines>`.

**`TabButton`**: the symbol (16 points), the title (one line, truncated in the middle) and a borderless `xmark`
close button, shown while hovered or selected ("Close Tab (⌘W)", "Close <title>"); `callout`, `textPrimary`
when selected else `textSecondary`; 10 points of horizontal padding, 28 high, in a capsule of `.surface` when
selected, `textSecondary` at 8 % when hovered. A tap selects it. Its context menu: Close Tab, Close Other Tabs,
Move Tab to New Window (the last two with two tabs or more). For VoiceOver it is one button with its title, the
Selected trait when selected, and the actions Close Tab and Move Tab to New Window.

Titles: a tool's tab `WindowDirectory.tabTitle(tool.title, project: name)` ("Tickets – Orders"), Project
Settings' `tabTitle("Project Settings", project: name)`, then "Projects" and "Virtual Machines". Symbols: the
tool's, `folder`, `gearshape`, `desktopcomputer`.

### WindowDirectory

`final class WindowDirectory`, a singleton (`static let shared`), keeps every window with its `Workspace`, so
that a route selects a tab already showing what it asks for instead of opening a second one.

- Entries are keyed by `ObjectIdentifier(window)`: `weak var window: NSWindow?`, `weak var workspace:
  Workspace?`. `register(_:workspace:)` adds or replaces one, and sets the window's `tabbingMode` to
  `.disallowed`.
- `windows()` drops entries whose window or workspace is gone, keeps the visible or minimized windows, and
  orders them by their index in `NSApp.orderedWindows` (minimized ones last). `frontmost()` is the first that
  isn't minimized, else the first. `window(of:)` finds a workspace's window.
- `show(where:focus:)`: in the frontmost window whose workspace `find` gives a tab, selects the tab, calls
  `request(focus, in:)` when there is a focus, and `show(_:)` the window; false when none. `show(_ content:focus:)`
  uses `tab(showing:)`.
- `opensWindowsAsTabs` (true; `AppData.opensWindowsAsTabs` sets it). `open(_ tab:newWindow:)` adds the tab to
  `frontmost()` and shows its window when `opensWindowsAsTabs` and a window is open; otherwise it calls
  `newWindow(WorkspaceValue(tabs: [tab]))` and `activate()`. `open(_:openWindow:)` passes
  `openWindow(id: "workspace", value:)`. `showOrOpen(_:focus:openWindow:)` shows, else opens.
- `mergeAll(into:)`: every other window's tabs, in window order, are added to the workspace, and those windows
  close; the selected tab stays selected.
- Chat windows are kept apart (`ChatEntry`: weak `window`, `chatID`): `register(_:chat:)` adds one and disallows
  macOS tabs; `chatWindow(showing:)` gives the visible or minimised window of a chat. `windows()` never lists
  them, so tab routes and Merge All Windows leave them alone. `RouteHost` opens `.chatWindow(chat:)` with
  `show(_:)` on that window, else `openWindow(id: SceneID.chat, value: ChatWindowValue(chatID:))` and
  `activate()`; `.settings(pane)` writes the pane's raw value to `SettingsPane.storageKey` in the user defaults,
  then calls the environment's `openSettings()` and `activate()`.
- `static func show(_:)` deminiaturizes the window if needed, `makeKeyAndOrderFront(nil)`, `NSApp.activate()`;
  `static func activate()` calls `NSApp.activate()`; `static func tabTitle(_:project:)` is
  `String(localized: "\(window) – \(project)")`, key `%@ – %@`.

`WindowReader: NSViewRepresentable` reports its `NSWindow` from `viewDidMoveToWindow()` and from every
`updateNSView`.

**Status bar and feedback** (`StatusBar.swift`, [Navigation › Status bar](ui/navigation.md#status-bar),
[Chat › Feedback](ui/chat.md#feedback)).

- `FeedbackTarget` (`project: Project`, `chats: LiveChatStore`; `Sendable`) is
  `AppData.feedbackTarget`: the project of `feedbackProjectID` while the directory has it, with the app's
  chat store; nil otherwise. `RouteHost` puts it in every window's environment, `\.feedbackTarget`.
- `FeedbackSource` (`window: String`, `project: Project?`, `item: String?`) says what a window shows;
  `context(version:build:system:)` makes the feedback's context lines, by default from the main bundle's
  `CFBundleShortVersionString` and `CFBundleVersion` and `ProcessInfo.operatingSystemVersion`.
- `View.statusBar(_ source:)` puts the window's content (`frame(maxWidth: .infinity, maxHeight: .infinity)`)
  above `StatusBar` in a `VStack(spacing: 0)` while `\.feedbackTarget` is set: under the tab area and the chat
  panel together. Its modifier keeps a
  `FeedbackStarter` in `@State`, gives it its window through a `WindowReader`, publishes
  `focusedSceneValue(\.sendFeedback, SendFeedbackAction)` while there is a target, and shows
  `FeedbackView` (ChatKit) in a `.sheet(item:)` on `FeedbackStarter.request`. The sheet's finish calls
  `FeedbackStarter.finish(_:)`, then, with a chat id, `openRoute(.tool(.chat, project:, focus: id))`.
- Applied once per window, by `WorkspaceWindow`, for the selected tab: `windowName(of:)` (the tool's title,
  Projects, Project Settings or Virtual Machines), the tab's project (for Projects, its selection) and the
  tab's reported item (`workspace.subjects[tab.id]?.title`).
- `FeedbackStarter` (`@MainActor @Observable`): `request: FeedbackRequest?`, `weak window` (ignored by
  observation). `start(_ source:isOn:)` does nothing when off, while a request is open, without a window, or
  while the window has an attached sheet or is one; otherwise it captures the window
  (`WindowCapture.capture`), writes the PNG as `screenshot.png` in a new
  `<temporary>/HephaestusV3-Feedback-<UUID>` folder (no screenshot when either fails), and sets the request
  (`folder`, `screenshot`, `context`). `finish(_:)` clears it and deletes the folder.
- `SendFeedbackAction` (`@MainActor @Sendable` closure) is `FocusedValues.sendFeedback`. `FeedbackCommands`
  puts `CommandGroup(after: .help)` with **Send Feedback…** (⇧⌘B), shown only while the focused value is set.
- `StatusBar(chats:start:openChat:)`: `Divider`, then an `HStack(spacing: 12)` 26 points high, 10 points in, on
  `canvas`: a flexible space, the running count and the waiting count (borderless buttons that open
  `StatusChatsPopover` in a `.popover(arrowEdge: .top)`), a flexible space, and the ladybug button while `start`
  isn't nil. `StatusChat` (`id`, `title`, `projectID`, `State` `starting`, `running`, `waitingPermission`,
  `waitingAnswers`, `updated`) is made by `StatusChat.list(_:)` from the session's `states` and `chats`, sorted
  waiting first, then latest updated first. `RouteHost` puts the session in `\.chatSession`; the modifier shows
  the bar while `\.feedbackTarget` is set or the list isn't empty, and opens a row's chat with
  `openRoute(.tool(.chat, project:, focus:))`.

**`WindowCapture`** (`WindowCapture.swift`) is V2's capture without its web-view step: `capture(_:) -> Data?`
renders `hostWindow(of:)`'s frame view with `cacheDisplay` (`bitmapImageRepForCachingDisplay`), fills the
`.behindWindow` `NSVisualEffectView`s with `NSColor.windowBackgroundColor` in their appearance
(`destinationOver`), draws `fullScreenToolbarWindow(of:)` and `overlayWindows(of:)` at
`placement(of:in:)`, encodes PNG, and renders again at 1 pixel per point above `maximumPNGSize`
(5,000,000 bytes).

**Titles written by Claude** ([Tickets › Titles written by Claude](ui/tickets.md#titles-written-by-claude)).
After `tickets.start()`, `AppData.start()` gives the ticket library an `onUntitled` handler that calls
`queueTitling(_:)` on the main actor. `queueTitling` chains a `Task` after the previous one (`titling`), so the
titles are written one after the other; each runs `titleUntitled(_:)`: `chats.run(.setTicketTitle, input: "",
attaching: [AppData.link(ticket:in:)])`, the link being the ticket's `ChatItemReference` (tool `tickets`, the
ticket's project, its id as focus and title; `UntitledTicket` is `id`, `projectID` and `provisionalTitle`), then
`TicketRules.title(fromAnswer:)`, `library.setGeneratedTitle(_:of:replacing:)` and `tickets.refresh()` when it
renamed; any failure leaves the provisional title. `AppData.generateTitle` is the `GenerateTitleAction` of
**Generate Title**, in New Ticket and the ticket editor: the same run and rule. Given a ticket (the editor's,
as `TicketEditor` passes its ticket's id and project to `GeneratedTitleField`), it links it, with the
description as input only while it differs from the saved one (`tickets.snapshot`); without one (New Ticket),
the description is the input. Its error is a `ChatError`'s description, or "Claude's answer has no title."

**Notifications** (`ChatNotifier.swift`, [Chat › Notifications](ui/chat.md#notifications)). `AppData.notifier`
(lazy) is a `ChatNotifier` (`@MainActor`, `NSObject`, `UNUserNotificationCenterDelegate`) on the session, posting
unless `HEPHAESTUS_DATA_DIR` is set (`ChatNotifier.posts`; its `center` is then nil). `AppData.start()` reads
`NotificationChoices(settings)` with the other settings, then sets `notifier.open` to `openRoute` and calls
`start()`: it sets `chats.onEvent` and `chats.onOpen`, follows `chats.waitingChats` with
`withObservationTracking` for `NSApp.dockTile.badgeLabel` (nil at 0), becomes the center's delegate, and asks
for `.alert`, `.sound`, `.badge` when the status is `notDetermined` or `badgeSetting` is `notSupported`.
`receive(_:)` bumps the chat's generation, calls `NSApp.requestUserAttention(.informationalRequest)` for
`needsYou` while the app isn't active, then, as the choices allow, posts the detail at once or awaits
`chats.summary(of:)` and posts it while the generation, the chat and its waiting still hold. `post` skips a chat
`isInKeyWindow` while the app is active; it adds a `UNNotificationRequest` with identifier `chat/<id>`
(`identifier(of:)`), title `title(project:chat:)` (key `%@ · %@`), the line as body, the default sound and
`userInfo` `chatID` and `projectID`. `onOpen` removes the delivered notification. The delegate presents
`[.banner, .list, .sound]`, and a response activates the app and opens `.tool(.chat, project:, focus:)`. In
ChatKit, `reportsShownChat(_:store:)` (`ShownChatReporter`, on the Chat window's detail and the panel) calls
`ChatStore.showing(_:inKeyWindow:view:)` on appear, on a change of the conversation or of
`controlActiveState`, and with nil on disappear.

**Mentioned In.** `AppData.chatMentions` is a `ChatMentionsReader` (ToolsFoundation) on `chats.chats(mentioning:)`,
each chat made a `MentioningChat` (`id`, `title`, `projectID`, `updated`, `State` from the chat's state,
`closed`); `RouteHost` puts it in `\.chatMentions`. TicketsKit's `MentionedInSection` and the bundle menu read it;
`ChatMentionsReader.samples` (`MentioningChat.samples`) serves the previews and captures.

**Settings ▸ Notifications.** `AppData.notificationChoices` (`NotificationChoices`: `needsYou`, `finished`,
`aiSummary`, each `true` when `settings.yml` has no key) is set by `setNotificationChoices(_:)
throws(StorageError)`, which writes the three keys as `setFeedbackProject` writes its own.
`NotificationSettingsPane(appData:)` gives `NotificationSettingsView(choices:change:)` both; the Settings
`TabView` shows it after the Chat tab, while Chat is available.

**Settings ▸ General.** `AppData.opensWindowsAsTabs` (`private(set)`, true until read) is read from
`settings.yml` (`SettingsFile.opensWindowsAsTabs`) once the session has started, and its `didSet` sets
`WindowDirectory.shared.opensWindowsAsTabs`. `setOpensWindowsAsTabs(_:) throws(StorageError)` reads the file,
sets the value, writes it, then sets the property; without a data folder it only sets the property.
`GeneralSettingsPane(appData:)` gives `GeneralSettingsView(opensWindowsAsTabs:change:)` the value and that
function; the view's radio group calls it on a new choice and shows the error's `description` when it throws
([Navigation › Settings ▸ General](ui/navigation.md#settings--general)). `AppData.feedbackProjectID` is read
from `settings.yml` at the same time; `setFeedbackProject(_:) throws(StorageError)` writes it the same way
(nil removes the key). The view's Feedback section takes `feedbackProjectID`, `projects: [ProjectChoice]`
(`id`, and `title` from `ProjectTree.path(of:)`, in the directory's order) and `changeFeedbackProject`.

### Menu commands and focused values

| Command group | Placement | Items |
| --- | --- | --- |
| `NewItemCommands` | `CommandGroup(replacing: .newItem)` (File), and `CommandGroup(replacing: .saveItem) {}`, which takes out SwiftUI's Close | New Window (⌘N), New Tab (⌘T), `NewItemMenuItem` (⇧⌘N), Add Existing Folder… (⌘O), a divider, Close Tab (⌘W) and Close Window (⇧⌘W), a divider, Project Settings… (⇧⌘,). |
| `ToolCommands` | `CommandGroup(before: .windowList)` (Window) | `ToolMenuItems`: Projects (⌘0), one item per available `ToolKind` (`tool.shortcut`), Virtual Machines (⌘7), a divider. |
| `TabCommands` | `CommandGroup(after: .windowArrangement)` (Window) | A divider, Show Previous Tab (⌃⇧⇥), Show Next Tab (⌃⇥), both with two tabs or more; Move Tab to New Window (two tabs or more); Merge All Windows (two windows or more). |
| `ChatPanelCommands` | `CommandGroup(after: .sidebar)` (View) | `ChatPanelMenuItem`: Show Chat Panel / Hide Chat Panel, ⌃⌘C. |
| `FeedbackCommands` | `CommandGroup(after: .help)` (Help) | Send Feedback… (⇧⌘B). |

- **New Window** (`workspace` focused value): `openWindow(id: "workspace", value: WorkspaceValue(content))` with
  the selected tab's content, for a tool's tab; disabled otherwise.
- **New Tab**: `workspace.add(WorkspaceTab(content:))` with the selected tab's content, for a tool's tab.
- **Close Tab**: removes the selected tab when the key window has two tabs or more; otherwise
  `NSApp.keyWindow?.performClose(nil)`, which also closes Settings. **Close Window**: `performClose`.
- **Project Settings…**: `showOrOpen(.projectSettings(project.id))` for `activeProject`.
- **`ToolMenuItems`**: Projects `showOrOpen(.projects)`; each tool `showOrOpen(.tool(tool, project:))` for
  `activeProject`, disabled unless `project?.tools.contains(tool)`; Virtual Machines `showOrOpen(.machines)`.
- **Move Tab to New Window**: removes the selected tab and opens a window with it. **Merge All Windows**:
  `WindowDirectory.shared.mergeAll(into:)`.
- **`NewItemMenuItem`** reads `newItem`: its title (or "New Item", disabled, without one), ⇧⌘N.
- **`ChatPanelMenuItem`** reads `FocusedValues.chatPanel`, calls `toggle()`, and is disabled when nil.

| Focused value | Declared in | Set by |
| --- | --- | --- |
| `activeProject: Project?` | ToolsFoundation (public) | `WorkspaceWindow`: the selected tab's project; for Projects, its selection. |
| `newItem: NewItemCommand?` | ToolsFoundation (public) | Views that call `newItemCommand(_:action:)`. |
| `addFolder` | ProjectsKit (public) | Projects. |
| `activeTool: ToolKind?` | ToolsScenes (internal) | `WorkspaceWindow`, for a tool's tab. |
| `workspace: Workspace?` | ToolsScenes (internal) | `WorkspaceWindow`. |
| `chatPanel: ChatPanelControl?` | ToolsScenes (internal, `ChatPanelFocusKey`) | `WorkspaceWindow`, while it offers the panel. |
| `sendFeedback: SendFeedbackAction?` | ToolsScenes (internal) | The status bar, while there is a feedback project. |

All are set with `focusedSceneValue`; only the selected tab is drawn, so its values are the window's. The menus
are specified in [Navigation › Menus and shortcuts](ui/navigation.md#menus-and-shortcuts).

### Dashboard widgets

`private struct DashboardWidgetView` is where the Dashboard meets the tools. DashboardsKit draws the grid and
the title rows; this view draws a widget's content by its kind:

| Kind | View | From |
| --- | --- | --- |
| `.project` | `DashboardProjectWidget(widget:context:)` | DashboardsKit |
| `.tickets` | `TicketsDashboardWidget(widget:context:)` | TicketsKit |
| `.recentBuilds` | `BuildsDashboardWidget(widget:context:)` | BuildsKit |
| `.instances`, `.serviceGraph`, `.busiestCalls`, `.failedRequests`, `.requestsPerMinute` | `ServiceMapDashboardWidget(widget:context:)` | ServiceMapKit |

### Mac widths

The width a window's columns need side by side. Below it, a regular-width window takes the iPad layout. With
the chat panel open beside it, a window needs 341 more. `ToolKind.macLayoutWidth` is an internal extension in
ToolsScenes; Projects and Virtual Machines keep their own, and the window uses 760 for their tabs and Project
Settings'.

| Window | Mac width | Where |
| --- | --- | --- |
| Dashboard | 900 | `ToolKind.macLayoutWidth` |
| Tickets | 900 | same |
| Service Map | 880 | same |
| Contracts | 760 | same |
| Builds | 900 | same |
| Chat | 960 | same |
| Projects | 900 | `ProjectsRootView.macWidth` |
| Virtual Machines | 900 | `MachinesModel.macWidth` |

The layouts are specified in [Foundations › Layout system](ui/foundations.md#layout-system).

### Where a tool plugs in

A new tool touches these places, and no other tool's target:

| Place | Change |
| --- | --- |
| `Package.swift` | `toolTarget("<Name>Kit")`, its `testTarget`, and a dependency of `ToolsScenes`. |
| `Sources/<Name>Kit/` | Its root view, model, store protocol and sample store, `Localizable.xcstrings`; a reader and a widget if it has them. |
| `ToolsFoundation/Routing.swift`, `Appearance.swift` | A `ToolKind` case with its `title`, `symbol` and `shortcut`. |
| `ToolsFoundation/Project.swift` | `Project.tools`, for the projects it applies to. |
| `ToolsScenes.swift` | A `toolScene(_:size:)`, a case in `content(for:focus:)`, `appToolReader`, `macLayoutWidth`, and `NewWindowMenuItem`'s title. |
| `ToolsFoundation/Dashboard.swift`, `DashboardWidgetView` | For a widget: a `DashboardWidgetKind` case and its mapping. |
| `docs/ui/` | Its page, and a row in the README's contents. |

## The tool kits

Each kit follows the same shape. Its public root view takes plain values (`project`, `focus`) and builds its
model with the sample store; an internal `init(model:)` takes a ready model for previews and tests. Its
reader, if any, is a `public enum` with a `public static func read`, plus internal variants that take a store.

| Kit | Public root view | Model | Store → sample store | Reader | Focus format | Dashboard widget | ⇧⌘N | Chat subject |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ProjectsKit | `ProjectsRootView`, `ProjectSwitcher`, `ProjectLauncher` | `ProjectsModel`, `ProjectPickerModel` | `ProjectStore` → `SampleProjectStore` | — | project id | — | New Project… | — |
| DashboardsKit | `DashboardRootView`, `DashboardProjectWidget` | `DashboardModel` | `DashboardStore` → `LiveDashboardStore` (app), `SampleDashboardStore` (previews) | — | none | Project | — | — |
| TicketsKit | `TicketsRootView` | `TicketsModel` | `TicketStore` → `SampleTicketStore` | `TicketsReader` | ticket id | Tickets | New Ticket… | selected ticket |
| ServiceMapKit | `ServiceMapRootView` | `ServiceMapModel` | `ServiceMapStore` → `SampleServiceMapStore` | `ServiceMapReader` | `service:<name>`, `request:<id>` | Instances and the four service widgets | — | inspected service or request |
| ContractsKit | `ContractsRootView` | `ContractsModel` | `ContractStore` → `SampleContractStore` | `ContractsReader` | operation id | — | — | selected operation |
| BuildsKit | `BuildsRootView` | `BuildsModel` | `BuildStore` → `SampleBuildStore` | `BuildsReader` | run number, `release:<tag>` | Recent Builds | — | selected run or release |
| ChatKit | `ChatRootView`, `ChatPanel`, `ChatSettingsView` | `ChatWindowModel`, `ChatPanelModel` | `ChatStore` → `LiveChatStore`, `SampleChatStore` | — | conversation id | — | New Chat | — |
| MachinesKit | `MachinesRootView` | `MachinesModel` | `MachineStore` → `SampleMachineStore` | — | machine id | — | New Machine… | — |

### ProjectsKit

The project selector. Spec: [Projects](ui/projects.md), [Menu bar](ui/menu-bar.md),
[Components › Project switcher](ui/components.md#project-switcher).

| File | Contents |
| --- | --- |
| `ProjectStore.swift` | `ProjectStore`, `DirectoryProjectStore`, `SampleProjectStore`, `ProjectListEntry`, `ProjectListSection`, the filter on `ProjectTree` |
| `ProjectMapping.swift` | `Project.Kind(ProjectKind)`, `Project.Kind.stored`, `ProjectTint(stored:)`, `DeploymentEnvironment(_:inheritedFrom:)`, `Project(_ loaded:)`, `ProjectDirectory.update(from:)`, `ProjectMessages` |
| `NewProjectModel.swift` | `NewProjectModel` |
| `NewProjectSheet.swift` | `NewProjectSheet` |
| `ProjectsSettingsView.swift` | `ProjectsSettingsPane` (public), `ProjectsSettingsView` |
| `ProjectSettingsModel.swift` | `ProjectSettingsBackend` (`ProjectSession` conforms), `ProjectSettingsModel` |
| `ProjectSettingsView.swift` | `ProjectSettingsWindow` (public), the form, `PreviewSettingsBackend`, `previewSettings(_:)`, `TintSwatch` (the Tint menu's colored dots, non-template images) |
| `ProjectsModel.swift` | `ProjectsModel`, `ProjectEnvironments`, `ActivityEntry`, `OverviewGrid` |
| `ProjectPickerModel.swift` | `ProjectPickerModel` |
| `ActivityItem.swift` | `ActivityItem`, its tone colors and samples |
| `ProjectsRootView.swift` | `ProjectsRootView`, the sidebar and its rows, `NoMatchingProjects` |
| `ProjectOverview.swift` | `ProjectOverview`: header, figures, tool tiles, sub project cards, environment cards, activity |
| `ProjectSwitcher.swift` | `ProjectSwitcher`, `ProjectSwitcherList` |
| `ProjectLauncher.swift` | `ProjectLauncher`, `ProjectLauncherPanel` |

**Public API**

- `ProjectsRootView(directory: ProjectDirectory, session: ProjectSession, selection: Binding<Project.ID?>)`: the
  app's window, whose New Project, Add Existing Folder and Remove Project go through the session.
- `ProjectsRootView(projects: [Project], selection: Binding<Project.ID?>, onNewProject: () -> Void = {}, onNewSubProject: (Project.ID) -> Void = { _ in }, onAddFolder: () -> Void = {})`:
  a window on given projects, whose actions only call the closures.
- `ProjectsSettingsPane(session:)`; `ProjectSettingsWindow(session:projectID:)`; `AddFolderCommand` and the
  `addFolder` focused value; the mapping of `ProjectMapping.swift`.

**`ProjectSettingsModel`** (`@Observable`) takes a `ProjectSettingsBackend` (`snapshot`, `kubectl`,
`hasLookedUpTools`, `waitForTools()`, `update(_:_:)`): `ProjectSession` in the app, a real session on a temporary folder in the tests, a fixed
snapshot whose kubectl answers from fixed lists in the previews. It reads the project from the snapshot at each
access and keeps the text of each field (`name`, `icon`, `docsPath`, `githubPage`, and the environment's
`environmentName`, `kubeconfig`, `namespace`, `deployment`, `jaeger`, `url`, `port`), which `reload(except:)`
refills from the stored values, except the field being edited; the form calls it when it appears and when the
project changes. `hasValues` turns true at the first `reload` that finds the project: until then each text
field's apply calls `reload()` instead, so a field opened before the project loaded never applies its empty
text. `pickIcon(_:)` fills the icon field with a symbol picked in the picker and applies it. Every change is `async`: `applyName()`,
`applyKind(_:)`, `applyTint(_:)` (the tint's name), `applyIcon()` (checked with `NSImage(systemSymbolName:)`),
`applyDocsPath()`, `applyGitHubPage()`, `applyGraph(_:)` (`true`, `false`, or `nil` to take the parent's;
`graphSetting` is the stored value, `graphEnabled` and `inheritedGraphEnabled` the resolved ones); `select(_:)`,
`addEnvironment()`, `removeEnvironment()`, `applyEnvironmentField(_:)`, `applyPendingEnvironmentFields()` (every
changed field in one `ProjectChange`), `applyCertificates(_:)`; `checkCluster()`. Each calls the backend with a
`ProjectChange` of the values it sets and, on failure, keeps `ProjectMessages.message(_:)` for the field
(`message(_:)`). An own environment changes in `environments` (the whole list, the entry edited in place, its
other keys kept); an inherited one in `environmentOverrides` (every field but the name), an empty field
giving `nil`, the certificates stored only while they differ from the parent's, and a change that sets
nothing removed. `OptionalSection` (`github`, `service`, `environments`, each with a `title` and `symbol`) names
the sections the form shows only when they apply. `typeUses(_:)` is true for a `goService` project's Service and
Environments; `hasOwnValues(_:)` for a typed `githubPage`, a set `graphEnabled`, own `environments` or any
`environmentOverrides`. `shows(_:)` is true when the section was added with `add(_:)` while the window is open
(`addedSections`), the type uses it or it has own values. `addableSections` lists the others, in that order.
`canRemove(_:)` is true for a section that shows and the type doesn't use; `remove(_:)` deletes its own values
in one `ProjectChange` (`githubPage: .some(nil)`; `graphEnabled: .some(nil)`; `environments: []` with
`environmentOverrides: [:]`) and takes it out of `addedSections`, or leaves it when the change fails. `connection`
(`none`, `checking`, `connected`, `failed(message)`), `namespaces` and `deployments` come from
`kubectl.namespaces(kubeconfig:)` then `deployments(namespace:kubeconfig:)`, run by the view's
`.task(id:)` on the selected environment, its kubeconfig file and its namespace.

**`ProjectSettingsWindow`** shows the form, or "Project Not Found" when the project left the list. The form
applies a text field on Return (`onSubmit`) and when the focus leaves it (`onChange(of: focus)`), calls
`reload(except: focus)` when the project changes, and offers `fileImporter` for the kubeconfig file
(`fileDialogDefaultDirectory` `~/.kube`, hidden files shown).
- `ProjectSwitcher(projects: [Project], selection: Binding<Project.ID>, tool: ToolKind)`.
- `ProjectLauncher(projects: [Project])`.

**Store.** `protocol ProjectStore { var projects: [Project] { get }; var state: ProjectDirectory.State { get };
var unavailable: [ProjectDirectory.Unavailable] { get }; func activity(of: Project.ID) -> [ActivityItem] }`.
`DirectoryProjectStore(directory:)` reads the directory (observed, so the window follows its changes) and
reports no events. `SampleProjectStore(projects: [Project] = Project.samples, state: = .ready, unavailable: =
[])` returns `ActivityItem.samples(for:)`.

**Mapping** (`ProjectMapping.swift`). `Project(_ loaded: LoadedProject)`: the file's identifier, name and
kind (`goService` → service, `swiftApplication` → app, `library` → library, `none` → other); the tint from
`ProjectTint(stored:)` (a tint name gives that tint; `#RRGGBB` the tint of the nearest hue among accent 265°,
accentSecondary 326°, info 191°, success 135° and warning 31°, a color whose channels differ by less than 0.08
giving accent; no color gives accent); the icon, else the kind's symbol; the root as `path`; the GitHub
page's `owner/name` as `repository` (empty without one); the resolved environments, each with `inheritedFrom`
= the parent when an inherited environment has its name; `activity` nil; `environmentsAreResolved` true; the
GitHub page, current environment and file issue. `ProjectDirectory.update(from:)` maps the session's
snapshot, its phase (`starting` → loading, `ready`, `failed` → the message) and its issues, each with its
reason from `ProjectMessages.reason(_:names:)`. `ProjectMessages.message(_:)` and `ruleMessage(_:)` give the
user's words for every `ProjectError` and `ProjectRuleError` (the texts of [Projects](ui/projects.md)).

**`NewProjectModel`** (`@Observable`): `name` (its `didSet` makes `identifier` the suggestion and
`folderName` the folder name while they aren't edited), `identifier`, `setIdentifier(_:)` (an empty value
follows the name again; `identifierTouched` keeps its messages showing), `pickedKind`,
`pickedParent: Project.ID??`, `pickParent(_:)` (moves `location` to the parent's folder), `folderMode`
(`newFolder`, `existingFolder`), `location`, `folderName`, `setFolderName(_:)` (an empty value follows the name again), `existingFolder`; the folder
panel's `choosingFolder`, `folderChoice` (`FolderChoice`: `location`, `existingFolder`), `chooseFolder(for:)` and
`chose(_:)`, which fills the field the panel was opened for (kept in the model because SwiftUI closes the panel,
setting its binding to false, before it hands the folder over);
`projectFolder`, `detectedKind` (service when the folder holds `go.mod`, else other), `kind`,
`detectedParent` (the innermost project whose `path` strictly holds the folder), `parentID`, `parent`,
`insideProject`, `parentChoices`; the messages `nameMessage`, `identifierMessage`, `folderMessage`;
`request: NewProject?` and `canCreate`; `folderName(from:)`, `isFolderName(_:)`,
`defaultLocation(selected:in:home:)`. `init(projects:location:parentID:existingFolder:)`: a parent makes it
New Sub Project; an existing folder sets that mode and the name.

**`ProjectsRootView` with a session** keeps the sheet's model, the folder panel's flag, the project to remove
and the failure to show; `presentations(_:)` applies the sheet, `fileImporter` (folders), the two alerts and
the `addFolder` focused value. `onChange` of the project ids calls `model.keepSelection()`.

**Filtering.** An extension of `ProjectTree` adds `normalized(_:)` (trimmed query), `matching(_:)` (name or id
contains the query, ignoring case and diacritics, through `localizedStandardContains`) and
`sections(matching:) -> [ProjectListSection]`. Without a query, the tree in order, each project in its
top-level project's kind section; with one, the matches flat in their own kind's section. A section shows
only when it has a project. `ProjectListEntry` is a project with its depth.

**`ProjectsModel`** (the Projects window):

| Member | Role |
| --- | --- |
| `tree` (from the store, at each read), `state`, `unavailable`, `isEmpty`, `selection` (private set), `query`, `folded: Set<Project.ID>` (private set) | The tree, whether the projects are loaded, the entries that didn't load, the selected project, the sidebar's filter, the folded parents. |
| `keepSelection()` | A selection that left the list moves to its nearest ancestor still listed (remembered at `select`), else to the first top-level project; no selection gets the first. |
| `activityLimit = 40` | The most events the overview lists. |
| `selectedProject`, `isFiltering`, `sidebarSections` (top-level rows only, unless filtering), `hasNoMatches` | The sidebar. |
| `children(of:)`, `isExpanded(_:)`, `setExpanded(_:_:)` | Folding, which lasts while the window is open. |
| `select(_:)` | Selects and unfolds the ancestors, even for the project already selected. |
| `select(focus:)` | Selects the project the focus names; an unknown id changes nothing. |
| `ancestors(of:)`, `descendantCount(of:)`, `ticketTotals(of:)` | The overview's path and figures. |
| `environments(of:) -> ProjectEnvironments` | For the app's projects, their environments, and the parent they inherit from; for samples, the settings source's environments, and `inheritedFrom` when it isn't the project. |
| `graphEnvironment(of:tools:) -> DeploymentEnvironment?` | The overview's Graph: nil unless `DashboardWidgetKind.serviceGraph.isShown(for:tools:)` (which needs `showsGraph`); then the environment named by `currentEnvironment`, else the first of `tree.environments(of:)`. |
| `activity(of:) -> [ActivityEntry]` | The family's events, newest first, at most 40. `ActivityEntry.id` is `"<project>.<event id>"`. |

The window's selection and the model's follow each other: `onAppear` and `onChange(of: selection)` call
`model.select`, and `onChange(of: model.selection)` writes the binding. A route sets the binding (ToolsScenes'
`selectedProjectID`). The view also applies `onFocusRequest { model.select(focus:) }`.

**`ProjectPickerModel`** (the switcher's popover and the menu bar panel): `tree`, `requiredTool: ToolKind?`,
`query` (each change highlights the first match), `highlighted` (private set), `isFiltering`, `sections`,
`entries`, `hasNoMatches`, `isAvailable(_:)` (has `requiredTool`), `highlightedProject` (what Return picks),
`highlight(_:)`, `move(by:)` (over available rows, stopping at the ends), `reset(highlighting:)`.
`init(store:requiredTool:highlighting:)`. The switcher creates one with `requiredTool: tool`; the launcher with
none, and resets it at `onAppear`, on each change of `appearsActive` and after each action.

**`ActivityItem`**: `id` (`"<tool>.<subject without #>"`), `tool`, `text`, `subject`, `date`, `tone`
(`neutral`, `info`, `success`, `warning`, `danger`, each an AZDesign color), `focus: String?`;
`route(in:)` is `.tool(tool, project:, focus:)`. `samples(for:)` holds the events of each sample project.

**`OverviewGrid.columnCount(for:minimum:spacing:width:)`** picks as many equal columns as fit, preferring a
count that divides the items; from four items without a divisor that fits, the count with the fewest empty
places.

**Routes it sends**: a tool tile opens `.tool(tool, project:)`; an activity row opens its item's route; the
switcher's Show All Projects opens `.project(id)`; the launcher's Return opens `.projectWindow(id)` and
⌘1–⌘6 or a tool button `.tool(tool, project:)`, then dismisses the panel.

**Layout.** `ProjectsRootView` measures itself with `adaptiveWindow` (Mac width 900, minimum 390 × 420): a
`NavigationSplitView` (sidebar 220–320, ideal 250; `.detailOnly` in `.pad`) or a `PhoneStack` in `.phone`.
⇧⌘N is "New Project…", which calls `onNewProject`.

### DashboardsKit

The Dashboard's grid, edit mode, settings and saving in the project files. The widgets' content comes from
the tools. Spec:
[Dashboard](ui/dashboard.md). The grid's code is in `DashboardGridLayout.swift` and `DashboardRootView.swift`.

| File | Contents |
| --- | --- |
| `DashboardModel.swift` | `DashboardModel`, `DashboardGridState`, `DashboardItem` |
| `DashboardStore.swift` | `DashboardStore`, `SampleDashboardStore` |
| `LiveDashboardStore.swift` | `LiveDashboardStore`, the mapping to and from `DashboardWidgetEntry`, `EnvironmentValues.dashboardStore` |
| `DashboardEdits.swift` | `DashboardContent`, `DashboardSlot`, `DashboardArrangement`, `DashboardStep`, `DashboardEdits` |
| `DashboardGridLayout.swift` | `DashboardSmallestSize`, `DashboardGridMetrics`, `DashboardFrame`, `DashboardGridLayout`, `DashboardDrag`, `DashboardAutoScroll`, `DashboardResizeHandle`, `DashboardOverflow`, `DashboardOverflowLayout`, `DashboardWidgetScroll` |
| `DashboardRootView.swift` | `DashboardSpace`, `DashboardRootView`, the list, the grid, `DashboardScroll`, `DashboardWidgetMenu`, `DashboardWidgetCard`, `DashboardWidgetTitleRow`, `DashboardWidgetSettings`, `DashboardProjectWidget` |
| `DashboardSamples.swift` | `DashboardWidget.sample(for:)` |

**Public API**

- `DashboardRootView<WidgetContent: View>(project: Project, store: LiveDashboardStore, @ViewBuilder widgetContent: @escaping (DashboardWidget, DashboardContext) -> WidgetContent)`.
  It passes each new `project` and the `availableTools` environment value to its model (`onChange`, initial),
  and shows the store's failure under the toolbar (`safeAreaInset(edge: .top)`, `dashboard.failure`).
- `LiveDashboardStore(session: ProjectSession)`, `@MainActor @Observable`; ToolsScenes' `AppData` makes one and
  gives it to every window as `EnvironmentValues.dashboardStore` (nil in previews).
- `DashboardProjectWidget(widget: DashboardWidget, context: DashboardContext)`: the Project widget's fields.

**Store and saving.**

- `@MainActor protocol DashboardStore: AnyObject`: `widgets(of:) -> [DashboardWidget]?` (nil: no stored list),
  `window(of:) -> TimeWindow?`, `environment(of:) -> String?` (a choice not yet the project's current
  environment), `failure(of:) -> String?`, `setWidgets(_:of:)`, `setWindow(_:of:)`, `setEnvironment(_:of:)`. A
  store is a shared `@Observable` reference, so a change in one Dashboard window shows at once in every other
  window of the project.
- `LiveDashboardStore` reads `session.snapshot.project(id)?.file.dashboardWidgets` and `dashboardGraphWindow`.
  A change goes into a private `shown` overlay at once, then into a queue: each write is a `Task` that awaits
  the previous one, then calls `session.update(id, ProjectChange(dashboardWidgets:))` (the list merged with the
  stored entries when its turn comes), `ProjectChange(dashboardGraphWindow:)` or
  `session.setCurrentEnvironment(id, to:)`. When a project's last queued write ends, its overlay is dropped and
  the file's values show. A failure keeps `ProjectError.description` in `failure(of:)` until the next change,
  drops the overlay, and raises the project's generation, so the writes queued before it are skipped. `settle()`
  awaits the queue (tests).
- Mapping: `widget(_:)` and `entries(_:merging:)`. A widget takes the stored entry of its slot (same id, same
  rank among equal ids), so Recent Chats' settings and unknown keys survive; a new widget takes the
  file's defaults. Statuses map `draft`↔Draft, `todo`↔Created, `in_progress`↔In Progress, `review`↔In Review,
  `done`↔Done; `week` maps to no `TimeWindow` (nil: the last hour shows).
- `SampleDashboardStore(_ widgets: [Project.ID: [DashboardWidget]] = [:], failures: [Project.ID: String] = [:])`
  keeps everything in memory; a project with nothing kept shows `DashboardWidget.sample(for:)`, its sample
  layout, or the default list.

**`DashboardModel`**, `init(project:store:tools: = Set(ToolKind.allCases), editing: = false)`:

| Group | Members |
| --- | --- |
| State | `project` (the view passes each new version), `tools`, `editing` (private set), `settingsSlot: DashboardSlot?`, `drag: DashboardDrag?` (private set), `areaWidth` (0 until laid out), `neededHeights: [DashboardSlot: CGFloat]`, `smallestSizes: [DashboardSlot: CGSize]` |
| What it shows | `widgets` (stored list, else `defaultList(for:)`), `widget(_:)`, `shownKinds`, `showsTimeWindow`, `showsEnvironment`, `showsNoWidgets`, `addableKinds`, `failure`, `environment` (the store's choice, else `project.currentEnvironment`, else the first not healthy of `deploymentEnvironments`, else the first), `window` (stored, else `.hour`), `setEnvironment(_:)`, `setWindow(_:)` (both ignore the value already shown), `context` |
| Arrangement | `metrics`, `arrangement(_:)`, `cells(of:)`, `listOrder` (shown widgets by row then column), `grid(metrics:) -> DashboardGridState` (items, the floating widget and the placeholder during a drag) |
| Edit mode | `startEditing()`, `endEditing()` (closes settings, ends a drag), `add(_:rows:)`, `remove(_:)`, `update(_:_:)`, `canStep(_:_:)`, `steps(of:)`, `step(_:_:)` |
| Drag | `dragChanged(_:_:start:location:scrollOffset:)`, `dragEnded(_:_:location:)`, `scrolled(to:)` |
| Measures | `measured(_:height:)`, `measuredSmallest(_:size:)`, `keep(_:)` (forgets widgets that left) |
| Saving | Private `change(_:)` applies an edit to the newest list and gives it to `store.setWidgets` only if it changed. |

The view reports what only its layout knows: the widget area's width, each widget's needed height and its
title row's size.

**Edits.** `DashboardSlot` (`id: UUID`, `occurrence: Int`) names a widget even when a hand-edited list
repeats an id; `identifier` is the uuid, or `"<uuid>-<n>"` from the second occurrence.
`DashboardArrangement` (`shown: Set<DashboardWidgetKind>`, `rows: [DashboardSlot: Int]`) gives `cells(of:)` and `storing(_:in:)`.
`DashboardStep` has `moveLeft`, `moveRight`, `moveUp`, `moveDown`, `wider`, `narrower`, `taller`, `shorter`.
`DashboardEdits` makes each change a new list: `appending`, `removing`, `placing`, `stepping`, `target`,
`resized`, `updating`, `toggling`, `flipping`, `steppingCount`. A move, resize, addition or removal stores the
positions the Dashboard shows; a change of settings stores no position. `DashboardContent` gives a widget's
title (`Title` trimmed, else the kind's), its fields in settings order, its row limit (1–20), and validates a
title (trimmed, at most 100 characters, one line).

**Grid geometry.** `DashboardGridMetrics(width:)`: `gap = 16`, `padding = 14`, `cell = (width − 23 × 16) / 24`.
`DashboardGridLayout` is a `Layout` that places each subview at its `DashboardFrame` (`.cells` or
`.floating(CGRect)`), set with `dashboardFrame(_:)`. `DashboardAutoScroll`: `zone = 40`, `speed = 600` points
per second. `DashboardResizeHandle.side = 18`. `DashboardSpace`: `margin = 20`, `listWidth = 900` (the
one-per-row list below it), `listMargin = 16`, `scrollBarWidth` from `NSScroller`. `DashboardScroll` is a
plain class held in `@State`, read during drags without invalidating the view.

**Samples.** `DashboardWidget.sample(for:)` has placed lists for `ORD` (8 widgets) and `SHOP` (6 widgets), with
ids `D0000000-0000-0000-0000-00000000000N`. Other projects show the default list.

**Motion.** Steps and removals apply inside `withMotion(.layout)`.

The Dashboard has no focus format, no reader and no ⇧⌘N item, and reports no chat subject.

### TicketsKit

Spec: [Tickets](ui/tickets.md). Data: `TicketData` ([TicketData](#ticketdata)) and `TextFormats` ([Text](text.md)); descriptions and comments are drawn by `TextViews`' `MarkdownView`.

| File | Contents |
| --- | --- |
| `Ticket.swift` | `TicketPriority`, `TicketLink` (`Kind`: `dependsOn`, `blocks`, `related`, `service`, `request`, `contract`, `build`; `isDeclared`, `isMissing`, `route(in:)`), `TicketAttachment` (`isImage`), `TicketAuthor`, `TicketEvent`, `Ticket`, `BundleStatus`, `TicketBundle`, `TicketLinkDraft` |
| `TicketStore.swift` | `TicketStorePhase`, `TicketChangeRequest`, `TicketStoreError`, `TicketStore` (with defaults and `count`), `SampleTicketStore` |
| `LiveTicketStore.swift` | `LiveTicketStore` (public) and its mapping from `TicketData`; `EnvironmentValues.ticketStore` |
| `TicketsModel.swift` | `TicketFilter`, `TicketFilterSection`, `TicketGroup`, `NewTicketDraft`, `TicketEdit`, `TicketConfirmation`, `BundleDraft`, `TicketsModel` |
| `TicketsReader.swift` | `TicketsReader` |
| `TicketsRootView.swift` | `TicketsRootView`, `TicketMenu`, `TicketSidebar`, `BundleRow`, `TicketFilterMenu` |
| `TicketListView.swift` | `TicketListState`, `TicketListView<RowMenu>`, `TicketFilterBar`, `TicketRow` |
| `TicketDetailView.swift` | `TicketDetailView`, `TicketSection`, `TicketText`, `TicketEditor`, `CommentEditor`, `TicketProperties`, `LinkRow`, `EventRow`, `AttachmentStrip`, `AttachmentView`, `PendingFileChip`, `FlowStack`, `TicketNotFoundView` |
| `TicketSheets.swift` | `AddLinkSheet`, `BundleSheet` |
| `TicketActions.swift` | `TicketActions: ToolbarContent` |
| `NewTicketView.swift` | `NewTicketView` |
| `AttachmentContent.swift` | `AttachmentContent` (`nonisolated`): `read(_:name:contentType:)`, `get_attachment`'s result, an image as a `ClaudeImage` (FileStorage); `text(_:)`, UTF-8 without NUL cut at `maxTextBytes` (256 KB) on a character's boundary |
| `GeneratedTitleField.swift` | `GeneratedTitleField`: a Title field given as content, **Generate Title** after it (from `\.generateTitle`, absent without one, called with the field's `ticket`, nil in New Ticket) and the failure's reason under it, as two views; used by `NewTicketView` and `TicketEditor` |
| `TicketImplement.swift` | On `TicketsModel` (whose `implementPending` holds the ticket waiting for the dependencies alert): `implementRefusal(of:)`, `undoneDependencies(of:)`, `implement(_:with:)`, `confirmImplement()`, `implementAlertMessage(_:)`, `canImplement(_:)` of a bundle, `target(_:)`; `View.implementAlert(_:)`. The detail's Implement… and Chats (`TicketChatsSection`, sharing `ChatListSection` and its rows with `MentionedInSection`), the list's and the bundles' menus call them ([UI › Tickets › Implement](ui/tickets.md#implement)) |
| `TicketAppearance.swift` | `TicketWords` (shared labels and the activity sentences, one per author); symbols, colors, shortcuts, next steps and `next` of statuses; priorities, bundle statuses, links and events |
| `TicketsDashboardWidget.swift` | `TicketsDashboardWidget` |
| `TicketTools.swift` | `FeedbackLink` (`isUnlinked`, `link`: the feedback chats, for `create_ticket`), `TicketTools.operations(tickets:projects:feedback:)` (public), the private `TicketToolSet`, `ticketToolError`, `TicketJSON`, `BundleJSON` |
| `SampleTickets.swift` | `Ticket.samples` (18 tickets), `TicketBundle.samples` |

**Public API**: `TicketsRootView(project:focus:store:directory:)`, `TicketTools.operations(tickets:projects:feedback:)`,
`FeedbackLink(isUnlinked:link:)`, `LiveTicketStore(session:)` with `counts() -> [Project.ID: TicketCounts]`,
`EnvironmentValues.ticketStore`, `TicketsReader.read(_:store:)`, `TicketsDashboardWidget(widget:context:)`.

**Store.** `@MainActor protocol TicketStore`: `phase` (`loading`, `ready`, `failed`), `tickets(of:)`,
`bundles(of:)`, `ticket(_:)`, `perform(_: TicketChangeRequest) async throws(TicketStoreError) -> String?` (the id
of what it created), `url(of:in:)` (an attachment's file), `retry()`; defaults: `ready`, a `perform` that
refuses ("This store doesn't change tickets."), no URL. `TicketChangeRequest` has one case per change of
[Data › Ticket changes](data.md#ticket-changes): `create`, `setStatus`, `edit`, `setPriority`, `setLinks`,
`delete`, `addComment`, `editComment`, `deleteComment`, `addAttachments`, `removeAttachment`, `createBundle`,
`editBundle`, `setBundleStatus`, `deleteBundle`.

- **`LiveTicketStore`** (`@Observable`) reads `TicketSession.snapshot` and maps it once per revision (a cache
  ignored by observation): statuses (`todo` is Created, `review` In Review), priorities, the reporter ("You",
  "Claude"), declared links (`dependsOn`, `related`, titled `<id> · <title>`, `isMissing` without a ticket),
  inverse links (`blocks`, `related`), `isBlocked` (a Depends On ticket that exists and isn't done), the
  attachments, and the activity: each history entry with its sentence, then the comments, merged by date
  (at equal dates the creation, the comments, then the other entries). `perform` calls the session's change
  as the user on this Mac and gives `TicketError.description` as the message. `phase` is `loading` until the
  session has loaded.
- **`SampleTicketStore`** (`@Observable`) applies each change in memory, without the rules of [Data › Ticket
  rules](data.md#ticket-rules), and records it
  in `changes`, for previews and tests.

**`TicketsModel`**, `init(project:focus:filter: = .all, store:, directory: = .previewSamples)`: reads live
from the store (`tickets`, `bundles`) and the directory (`family`, `indent(of:)`).

| Group | Members |
| --- | --- |
| State | `filter`, `selection`, `isComposing`, `draft`, `commentDrafts`, `commentFiles`, `edit: TicketEdit?`, `commentEdit`, `linkingTicket`, `bundleDraft`, `confirmation`, `failure` (the message of the last failed change), `isWorking` |
| List | `isGrouped`, `filterSections` (Bundles always, for New Bundle), `isFiltered`, `visibleTickets`, `groups`, `listState` (`loading` and `failed` from the store's phase), `lets(_:through:)`, `count(_:)`, `doneCount(of:)`, `showAllTickets()`, `title(of:)`, `symbol(of:)` |
| Selection | `selectedTicket`, `ticket(_:)`, `missingSelection`, `select(focus:)` (a bundle id selects its bundle in the sidebar), `bundles(of:)`, `chatSubject` |
| Changes | `perform(_:)` (sets `failure` on error; returns nil then), `setStatus(_:of:)`, `nextStep(of:)`, `confirm(_:)` |
| Editing | `startEditing(_:)`, `cancelEditing()`, `saveEditing()`, `setPriority(_:of:)`; `editBinding(_ opened:)` (in `TicketDetailView.swift`): the editor's `Binding<TicketEdit>`, which reads the open edit of `opened`'s ticket, else `opened`, and writes only while that edit is open. A force-unwrapped `Binding($model.edit)` crashed when Save cleared the edit while SwiftUI updated the closing editor once more. |
| Links | `declaredLinks(of:)`, `linkCandidates(for:)`, `addLink(_:to:)`, `removeLink(_:from:)` |
| Comments | `commentDraft(for:)`, `setCommentDraft(_:for:)`, `files(for:)`, `attach(_:to:)`, `detach(_:from:)`, `canComment(on:)`, `sendComment(on:)`, `startEditingComment(_:of:)`, `saveComment()` |
| Attachments | `addAttachments(_:to:)`, `url(of:in:)` |
| Bundles | `startNewBundle(with:)`, `startEditing(_ bundle:)`, `bundleCandidates(in:)`, `saveBundle()`, `add(_:to:)`, `remove(_:from:)`, `setStatus(_:of: bundle)` |
| New Ticket | `newTicketProjects`, `defaultNewTicketProjectID`, `startNewTicket()`, `cancelNewTicket()`, `createNewTicket()` (creates, closes the sheet, selects the ticket and clears a filter that hides it) |

**Reader.** `TicketsReader.read(_:store:)` reads the app's `LiveTicketStore` (the samples without one). `detail(of:)`
has one sentence per status and priority, and one per status without a priority.

**Widget.** `TicketsDashboardWidget` counts with `store.count(…, tree:)` over the environment's directory, in
the app's `\.ticketStore` (the samples without one).

**Root view.** `NavigationSplitView` with sidebar (190–280), list (300–480) and detail in `.mac` and `.pad`
(`.doubleColumn` in `.pad`), or a `PhoneStack` in `.phone`. It presents the New Ticket, Add Link and bundle
sheets, the failure alert and the confirmation alert; the list's context menu (`contextMenu(forSelectionType:)`)
and ⌘⌫ (`onDeleteCommand`); `TicketActions` call `setStatus` and `nextStep`, disabled while `isWorking`.
ToolsScenes' `ToolTab` builds it from a `TicketsTabState` with the app's ticket store and directory.

### ServiceMapKit

Spec: [Service Map](ui/service-map.md), and the service widgets in [Dashboard](ui/dashboard.md#widgets). The
graph's code is `GraphLayout.swift`, `GraphMapView.swift`, `GraphColorScale.swift` and
`GraphCanvasView.swift`: keep its algorithm, geometry and X-Ray look.

| File | Contents |
| --- | --- |
| `ServiceMap.swift` | `ServiceMap`, `ServiceNode`, `GraphArrow`, `ServiceCall`, `ServiceRequest`, `Span`, `LogLine`, `MapSelection`, `Project.openingEnvironment` |
| `ServiceMapStore.swift` | `ServiceMapStore`, `SampleServiceMapStore` |
| `ServiceMapModel.swift` | `ServiceMapModel`, `RequestRow` |
| `ServiceMapReader.swift` | `ServiceMapReader` |
| `ServiceMapRootView.swift` | `ServiceMapRootView`, `NamespaceSummary`, `RequestsTable`, `CompactRequestsList` |
| `GraphLayout.swift` | `GraphLayout`: positions of the nodes |
| `GraphMapView.swift` | `GraphMapModel`, `GraphColorScale`, `GraphGeometry`, `GraphMapView`, `GraphNodeView` |
| `GraphCanvasView.swift` | `GraphContent`, `GraphCanvasView<Accessory>`, `RightClickCatcher`, `GraphLegend` |
| `MapInspector.swift` | `ServiceInspector`, `RequestInspector`, `SpanRow`, `MissingItemView`, `LogList` |
| `ServiceMapAppearance.swift` | Kind and level appearance, `statusColor(_:)`, `ServiceMapFormat`, `rateText(_:)`, `durationText(_:)` |
| `ServiceMapDashboardWidgets.swift` | `ServiceMapDashboardWidget`, `ServiceWidgetReading`, `DashboardGraphLayouts`, the five widget contents |
| `SampleServiceMap.swift` | `ServiceMap.sample(environment:)`, `ServiceMap.ownService(of:)` |
| `SamplePods.swift` | `Pod`, `Pod.samples(of:environment:)` |

**Public API**: `ServiceMapRootView(project: Project, focus: String? = nil)`,
`ServiceMapReader.read(_ focus: String, environment: String? = nil, project: Project) -> ToolReading?`,
`ServiceMapDashboardWidget(widget:context:)`.

**Types.** `ServiceMap`: `nodes`, `calls`, `requests`, `logs`; `node(_:)`, `request(_:)`, `services` (nodes
whose kind `isService`), `serviceCount(of:)`, `calls(of:)`. `ServiceNode`: `id`, `kind` (`gateway`, `service`,
`worker`, `database`, `queue`, `bucket`, `external`, `client`; `isService` for the first three), `requestsPerSecond`,
`p95` (ms), `errorRate`, `readyPods`, `pods`, `health`, `throughput: [Double]`; `hasPods`; `ServiceNode.client`.
`ServiceCall` (`from`, `to`, `requestsPerSecond`, `errorRate`; `graphArrow`, `count(in:)`, `windowArrow(_:)`).
`GraphArrow` (`from`, `to`, `weight`, `label`, `spokenLabel`; `id` `"<from>→<to>"`). `ServiceRequest` (`id`,
`method`, `path`, `status`, `duration` in ms, `startedAt`, `spans`; `failed` from 400, `isSlow` from 1,000 ms,
`calledSpans`). `Span` (`id`, `service`, `operation`, `start`, `duration`, `isError`). `LogLine` (`id`,
`date`, `service`, `level` `info`/`warning`/`error`, `message`, `requestID`).

**Focus.** `MapSelection`: `.service(ServiceNode.ID)` or `.request(ServiceRequest.ID)`. `init?(focus:)` reads
`service:<name>` or `request:<id>`; anything else is nil. `focus` writes it back.

**Store.** `protocol ServiceMapStore { map(environment: String) -> ServiceMap; ownService(of: Project.ID) -> ServiceNode.ID?; pods(of: ServiceNode, environment: DeploymentEnvironment) -> [Pod] }`.
`SampleServiceMapStore` returns `ServiceMap.sample(environment:)` (the `shop` namespace; traffic scaled by 3.2
in Production and 0.05 in Local; Staging has the slow payment provider), `ServiceMap.ownService(of:)`
(`ORD` → `orders-api`, `PAY` → `payments-api`, `GW` → `edge-gateway`, others nil) and
`Pod.samples(of:environment:)` (names from a fixed hash of the service id).

**`ServiceMapModel`**, `init(project:focus:environment: = nil, store:)`:

| Group | Members |
| --- | --- |
| State | `project`, `environment: String` (its `didSet` reloads the map), `timeWindow = .hour` and `isLive = true` (not wired), `scope: MapSelection?` (nil for the whole namespace), `history: [MapSelection?]`, `map`, `sortOrder` (newest first), `ownService` |
| Opening | The named environment, else `project.openingEnvironment`: the first not healthy, else the first, among `deploymentEnvironments` (the project's own, or those of the project it takes its settings from). A sub project opened without a focus shows its own service, with `history = [nil]`. |
| Views | `select(focus:)`, `show(_:)` (pushes the current view; a request replaces a request), `canGoBack`, `back()`, `showAll()`, `tap(_:)` (services only), `requestSelection` (get/set for the table) |
| Shown | `currentEnvironment`, `showsRequest`, `graphContent: GraphContent`, `inspected: Inspected` (`.service`, `.request`, `.missingService`, `.missingRequest`, `.nothing`), `chatSubject`, `isOwnService(_:)`, `logs(ofService:)`, `logs(ofRequest:)`, `serviceCount`, `servicesNeedingAttention`, `requestRows: [RequestRow]` |

`RequestRow` is `nonisolated` so `Table` can sort it by key paths; ties keep the map's order through `position`.

**Graph.** `GraphLayout(nodes:arrows:iterations: = 600)`: rings, groups, Fruchterman–Reingold forces and group
arrangement, with `spacing = 130`, `orbit = 95`, `ringSpacing = 110`, `margin = 90`, `groupGap = 200`. Its rules
are in [Service Map › Layout](ui/service-map.md#layout). `GraphColorScale.color(weight:busiest:)` mixes
`success` → `warning` → `danger`; `grey` is `textSecondary` mixed with `canvas` at 0.45. `GraphGeometry.nodeDiameter = 54`.
`GraphCanvasView` handles zoom, pan, fit, focus, Back (⌘[) and Show All; `RightClickCatcher` is an
`NSViewRepresentable` for the right click that goes back. `DashboardGraphLayouts` caches layouts by topology.

**Reader.** `ServiceMapReader.read` reads `SampleServiceMapStore`, in the named environment or the opening one.
`reference(_:in:environment:)` carries the environment, so the chat reads what the user has on screen.
`detail(of:in:)` uses `AttributedString(localized:)` with inflected counts, and `ServiceMapFormat.literal(_:)`
escapes Markdown punctuation in data. `ServiceMapFormat` also has `rate`, `spokenRate`, `compactCount`,
`spokenCalls`, `duration(_:width:)`, `percent`, `route(of:)`.

**Widgets.** `ServiceMapDashboardWidget` reads the map of `context.environment` through `ServiceWidgetReading`
(`graphArrows`, `busiestCalls(limit:)`, `failedRequests(limit:)` over the time window) and shows
`InstancesContent`, `ServiceGraphContent`, `BusiestCallsContent`, `FailedRequestsContent` or
`RequestsPerMinuteContent` (Swift Charts). Without an environment it says "This project has no environments."

**Root view.** `VSplitView` of the graph over the requests (table at 600 points and wider, else the two-line
list), with an always-open `.inspector` (280–440) in `.mac` and `.pad`; in `.phone`, its own
`NavigationStack` with the details as a destination page. It reports `model.chatSubject` and applies
`onFocusRequest`. The Service Map has no ⇧⌘N item.


**Live data.** `ServiceMapStore.swift` holds `MapStatus`, `MapActionError`, the protocol
`ServiceMapStore` (`map(of:environment:)`, `status`, `refresh(_:environment:window:)`, `ownService(of:environment:)`,
`pods`, `acts`, `restart`, `scale`, `argoCD`, `sync`), `SampleServiceMapStore` and `LiveServiceMapStore` (`@Observable`,
one for the app: reads with `ServiceMapRead.read`, maps it to `ServiceMap`, keeps the own service's pods, owns the
`PortForwards`; `cluster(_:environment:)` gives Claude's tools their `Cluster`). `ServiceMapModel` refreshes in a
`.task(id:)` loop every 5 s while Live, and runs the Deployment's actions. `ClusterTools.swift` declares the eleven
cluster and map tools. Public API: `ServiceMapRootView(project:focus:store:)`, `LiveServiceMapStore(projects:runner:)`,
`ServiceMapReader.read(_:environment:project:store:)`, `ClusterTools.operations(maps:projects:)`,
`EnvironmentValues.serviceMapStore`.
### ContractsKit

Spec: [Contracts](ui/contracts.md). Data: `ContractData` ([ContractData](#contractdata)). Depends on
ContractData, MCPKit and ProjectData.

| File | Contents |
| --- | --- |
| `Contract.swift` | `Contract`, `HTTPMethod`, `Operation` (`lastResponse?`, `mediaType`, `details`, `key`), `Parameter`, `DocumentedResponse` (`code`, `status`), `SampleResponse`, `RequestDraft` |
| `ContractStore.swift` | `ContractLoad`, `ContractStore` (protocol), `ContractSendError`, `ContractAccess`, `SampleContractStore`, `LiveContractStore`, `EnvironmentValues.contractStore` |
| `ContractTools.swift` | `ContractTools` (`api_operations`, `api_call`) |
| `ContractsModel.swift` | `OperationSection`, `ContractsModel` |
| `ContractsReader.swift` | `ContractsReader` |
| `ContractsRootView.swift` | `ContractsRootView`, `OperationList`, `ContractAccessSheet` |
| `OperationView.swift` | `OperationView`, the request, response and documented-response views |
| `SampleContracts.swift` | `Contract.sample(for:)` |

**Public API**: `ContractsRootView(project:focus:store: LiveContractStore)`, `LiveContractStore(projects:)`,
`ContractsReader.read(_:project:store:)`, `ContractTools.operations(contracts:projects:)`.

**Stores.** `protocol ContractStore` (`@MainActor`, a class): `contract(of:) -> ContractLoad` (`none`,
`loading`, `loaded`, `failed`), `refresh(_:)`, `send(_:to:of:)`, `lastResponse(of:in:)`, `setEnvironment(_:of:)`,
`access(of:)`, `setAccess(_:of:)`. `LiveContractStore` (`@Observable`, one for the app) reads
`openapi/contract.yaml` off the main actor with `OpenAPIContract.read`, maps it to the window's `Contract`,
reads it again after file events under `openapi/`, keeps the responses of the run and the stored values,
and sends with `ContractHTTPClient`. `SampleContractStore` reads the samples and sends
nothing.

**`ContractsModel`**, `init(project:focus:store:)`: `contractLoad`, `contract`, `refresh()` (applies a focus that
waited for the contract), `query`, `sections`, `selection`, `environmentName`, `pickEnvironment(_:)`, `canSend`,
`isSending`, `send()`, `responses`, `failures`, `response(for:)`, `chatSubject`.

### BuildsKit

Spec: [Builds](ui/builds.md). Data: `BuildData` ([BuildData](#builddata)). Depends on BuildData, MCPKit,
ProjectData and ExternalTools.

| File | Contents |
| --- | --- |
| `Builds.swift` | `RunStatus` (and `init(status:conclusion:)` from GitHub's values), `WorkflowRun`, `Job`, `Step`, `Release`, `StepReference`, their appearance, `elapsedText(_:)`, `LogLineKind`, the samples and logs |
| `BuildStore.swift` | `BuildLoad`, `BuildStore` (protocol), `BuildActionError`, `SampleBuildStore`, `LiveBuildStore`, `EnvironmentValues.buildStore` |
| `BuildsModel.swift` | `BuildsFocus`, `BuildsModel` |
| `BuildTools.swift` | `BuildTools` (the seven MCP tools and their wording for the chat) |
| `BuildsReader.swift` | `BuildsReader` |
| `BuildsRootView.swift` | `BuildsRootView` and its rows, tables, inspectors, `LogPane`, `ReleaseNotes` |
| `BuildsDashboardWidget.swift` | `BuildsDashboardWidget` |

**Public API**: `BuildsRootView(project:focus:store: LiveBuildStore)`, `LiveBuildStore(cli:temporary:downloads:toolsReady:)` (`toolsReady`, awaited at the start of each refresh, is the
session's `waitForTools()` in the app),
`BuildsReader.read(_:project:store: LiveBuildStore?)`, `BuildsDashboardWidget(widget:context:)` (reads
`\.buildStore`), `BuildTools.operations(projects:runner:)`.

**Types.** `RunStatus`: `success`, `failure`, `running`, `queued`, `cancelled`. `WorkflowRun` (`id`: GitHub's id,
a sample's number; `number`, `displayNumber`; `title`, `workflow`, `branch`, `commit`, `event`, `status`,
`startedAt`, `duration` in seconds, `jobs`, `hasJobs`; `defaultStep`: the failed step, else the running one,
else the last that passed; `step(_:)`). `Job` (`name` as id, `status`, `duration`, `steps`, `jobID`) and `Step`.
`Release` (`tag` as id, `title`, `publishedAt`, `assets`, `isPrerelease`, `isLatest`, `notes`). `StepReference`
(`job`, `step`). `LogLineKind(_ line:)`: `error`, `detail`, `quiet`, `plain`, by how the line starts.

**Focus.** `BuildsFocus`: `.run(Int)` or `.release(String)`; `releasePrefix = "release:"`. `init?(_:)` accepts
ASCII digits for a run, or `release:` and a non-empty tag; `focus` writes it back.

**Stores.** `protocol BuildStore` (`@MainActor`, a class): `runs(of:)` and `releases(of:)` as `BuildLoad`
(`loading`, `loaded`, `failed(message)`), `run(_:of:)` (with its jobs once read), `log(of:in:of:)`,
`refresh(_:releases:)`, `load(run:of:)`, `loadLog(of:in:of:)`, `rerun(_:failedOnly:of:)`, `cancel(_:of:)`,
`download(_:of:of:)`, `webURL(of:in:)`.

- `LiveBuildStore` (`@Observable`, one for the app, made by `AppData` with gh and the environment of the
  projects' tool lookup) keeps per repository (`owner/name`) the runs, the releases, the runs' details by id
  and the jobs' logs by job id, nothing on disk. A refresh of a key already reading is skipped; a run whose
  status changed is read again with its details. It maps `GitHubRun` and `GitHubRelease` to the window's types.
- `SampleBuildStore` reads the samples of the repository's owner: the first sample project with the same
  `repository`, so ToolsKit shows Tools' builds; its actions fail with an alert.

**`BuildsModel`**, `init(project:focus:store:)`: `Mode`, `project`, `store`, `runsLoad`, `releasesLoad`, `runs`,
`releases`, `mode`, `selectedRunID` (another run shows its `defaultStep`), `selectedReleaseID`, `selectedStep`,
`pageOnOpen`, `isRefreshing`, `isActing`, `downloads`, `failure`, `currentRun`, `currentRelease`,
`currentStep`, `stepLog`, `select(focus:)` (a focus naming nothing read yet waits for the lists), `chatSubject`,
`refresh()`, `loadSelectedRun()`, `loadLog()`, `rerun(failedOnly:)`, `cancel()`, `webURL`, `download(_:of:)`.
The root view runs `refresh()` in a `.task(id: mode)` loop every 30 s, and `loadSelectedRun()` and `loadLog()`
in `.task(id:)`s on the selection.

**Reader.** `BuildsReader.read` reads the store's runs and releases (the samples without a store).
`reference(_ run:in:)` titles it "Run <number>" with the run's id as focus; `reference(_ release:in:)` "Release
<tag>" with focus `release:<tag>`.

**Widget.** `BuildsDashboardWidget.recentRuns(of:count:store:)` lists the newest runs within 1–20; a row opens
`.tool(.builds, project:, focus: "<id>")`, except in edit mode. It reads the app's store, refreshing it when it
shows and every 30 s.


**Root view.** One body per `WindowLayout`: `.mac` is a `VSplitView` of the table over the log or notes with an
always-open `.inspector` (280–440); `.pad` is a `VSplitView` of the table over an `HSplitView` of the log or
notes and the details; `.phone` is one `PhoneStack` per mode. The mode picker is segmented in the principal
placement, or a menu in `.phone`. Refresh has an empty action. It reports `chatSubject` and applies
`onFocusRequest`.

### TextViews

Spec: [Text](text.md). `MarkdownView.swift`: `MarkdownView` (public; `init(_:projects:root:keepsLineBreaks:)`,
`markerOptions`), its private block views, `MarkdownLinkActions` (what a click on an id, a sound's ▶ or a relative
link does, and the alert **Play Sound failed**), and `MarkdownInlines` (attributed inlines, `text(_:dark:)` joining
the markers' images, highlighted code, token colors). `MarkerDrawing.swift`: `ColorSwatches` (`nsColor`, `color`,
`resolved`, the swatch image), `FontFaces` (the system designs, installed faces and the project faces
`register(family:style:file:postScriptName:)` remembers), `SoundPlayer` (one `NSSound` at a time), `SoundLinks`
(`hephaestus-sound:`) and `MarkerText` (plain text with markers and ids) ([Text › Markers](text.md#markers)). It
moved out of TicketsKit when the chat needed it (V2's chat rendered the same Markdown). A code block has a **Copy**
button (`doc.on.doc`, `markdown.code.copy`) that puts its code on the pasteboard. Its strings: "Done", "Not done",
"Image", "Copy", "OK", "Play Sound failed", "The sound cannot be played.", "This window can't play sounds.", and
"%@%@", the join of a line's pieces, never translated.

### ChatKit

Spec: [Chat](ui/chat.md): the Chat window, the chat panel, Settings ▸ Chat; [System Prompts](ui/system-prompts.md).
Depends on ChatData, MCPKit, ProjectData and FileStorage.

| File | Contents |
| --- | --- |
| `ChatModel.swift` | `ChatConversation` (with `waitingQuestions` and `waitingPicker`), `ChatTurn` (with `files`), `ChatMessageFile`, `ChatQuestionSet` (`firstUnanswered`, `nextUnanswered(after:answered:)`, `completes(at:)`), `ChatToolDetails`, `ChatToolInput`, `ChatTurnCaption`, `ChatBlock` (`Content`: `text`, `call`, `approval`, `notice`, `questions`, `thinking`, `images`, `picker`; `toolCall(_:_:)`), `ChatToolCall`, `ChatNotice`, `ChatApproval` (`Channel`, `comment(id:on:preview:decision:)`), `ChangePermission`, `ChatPreferences` |
| `ChatStore.swift` | `ChatStore` (protocol; `answerPicker(_:request:of:)`, `pickerCatalogs(of:)`), `ChatSendError`, `PickerCatalogAccess` (the catalogues a picker card reads; `samples`: this Mac's, without project files), `SampleChatStore` |
| `LiveChatStore.swift` | `LiveChatStore` (`turns(_:streaming:root:chatID:isRunning:)`: results and sub-agents' items gathered first, each call with its details and steps; `input(_:)`; `files(of:root:chatID:)`: a message's files as `ChatMessageFile`s; `answerPicker`, `pickerCatalogs(of:)` on the session's catalogues), `EnvironmentValues.chatStore` |
| `FileToolText.swift` | `FileToolText` (`call(_:input:root:)`: a file tool's row, its path from the project's folder; `request(_:input:root:)`: its card's title and preview; `display(_:root:)`), `CLIToolText` (`call(_:input:)` and `request(_:input:)`: the CLI's shell, web, agent and workflow tools, as [UI › Chat › Files](ui/chat.md#files) words them); `stopsOnEscape(_:)` is in `ChatStatusViews.swift`, `ChatStore.queuesMessages` true for the live store |
| `ChatTools.swift` | `ChatGate`, `ChatTools` (`list_chats`, `get_chat`, `rename_chat`, `ask_questions` and `askRefusal`, `show_image`, and `askPicker(_:_:)`: `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font`, `ask_animation`, with `pickerRefusal`) |
| `ChatPickerCard.swift` | `PickerCard` (the card of the waiting request's kind, over the composer of the Chat window and of the panel), `PickerCardChrome` (header, Minimize, question, rows, Skip and Submit), `OtherAnswerRow`, `RecommendedStar`, `pickerSelection(_:)`, `PickerSummary` (the transcript's card), `PickerKind.cardTitle` and `cardSymbol`, `PickerItem.preview(_:)` ([UI › Chat › Picker cards](ui/chat.md#picker-cards)) |
| `ChatSymbolCard.swift` | `SymbolCard` (`answer(request:choice:other:)`, `canSubmit(choice:other:)`, the grid's sizes) |
| `ChatColorCard.swift` | `ColorChoice` (`Row`; `choose(_:)`, `setPair(_:)`, `isHighlighted(_:)`, `answer(other:)`), `ColorCard`, `ColorSwatchView` (a split swatch for a pair), `ColorWell` (AppKit's expanded `NSColorWell`) |
| `ChatSoundCard.swift` | `SoundCard` (the list, playing a chosen row) |
| `ChatShortcutCard.swift` | `ShortcutChoice`, `ShortcutCard` (`selected`, `warnings(for:inUse:)`, `answer`, `canSubmit`), `KeyCaps`, `ShortcutRecording` (the `NSEvent` monitors of the recorder) |
| `ChatFontCard.swift` | `FontChoice`, `FontCard` (`family(of:suggestions:)`, `answer`, `canSubmit`; the nearest weight; registers the project's faces with `FontFaces`) |
| `ChatAnimationCard.swift` | `AnimationChoice`, `AnimationCard` (`customStart(_:)`, `answer`, `animation(_:)`: SwiftUI's animation of an expression; `valueText`), `AnimationLane` |
| `ChatSounds.swift` | `ChatSounds.player(_:)`: the `PlaySoundAction` ToolsScenes gives every window |
| `ChatQuestionsCard.swift` | `QuestionsCard` (the card over the composer), `QuestionsSummary` (the transcript's), `RecommendedTag`; `ChatQuestionSet.preview` |
| `ChatEngine.swift` | `ChatEngine`, `SampleChatEngine` |
| `ChatSuggestion.swift` | `ChatSuggestion` |
| `ChatFiles.swift` | `ChatFiles` (`adding(_:to:)`, `pasted(from:now:)`, `clean(_:)`), `PendingFileChip`, `AddFilesButton`: the files waiting to go with the next message, which `ChatWindowModel` and `ChatPanelModel` keep in `files` (`addFiles`, `removeFile`, `pasteFiles`) |
| `ChatToolDetailsView.swift` | `ToolCallDetailsView` (a call's input, result, images and steps; `shownLines` 200; `fenced(_:language:)`), `ChatStepView`, `ThinkingRow`, `IDLinkedText` (plain text with ids as links) |
| `ChatTranscriptScroll.swift` | `TranscriptScrollView` (the anchors, Jump to Latest, scrolling to Find's match), `ChatFind` (`matches(of:in:)`, `texts(of:)`) |
| `ChatStatusViews.swift` | `ContextIndicator` (`tooltip`, `tokens`), `ResumeLine`, `ClosedNotice`, `ChatMarkView`, `ClaudeCLILine` (`shows(_:)`, on `ChatStore.cliStatus`: the session's `status`, the samples' settable value), `reportsShownChat(_:store:)`; `ChatMark` is in `ChatModel.swift`, and `ChatConversation` carries `closed`, `mark`, `contextUsage`, `compactions`, `isCompacting`, `needsResume` and `plainText`. `ChatWindowModel` keeps `selectedIDs`, `hidesClosed`, `renaming`, `confirming` and the actions; `ChatStore` gained `rename`, `close`, `reopen`, `delete`, `resume`. |
| `ChatPermissionCard.swift` | `PermissionCard` (the oldest card waiting, over the composer: reason, preview or diff, message, Don't Allow, Always Allow, Allow, keys armed after 1 s; `shownLines` 20), `AllowAllBadge` |
| `ChatCompletions.swift` | `ChatCompletions` (`limit` 20, `list(for:commands:)`: the skills offered after `/`, as AZDesign `MessageCompletion`s), which the Chat window's and the panel's composers take, from `ChatStore.commands(for:)` |
| `ChatWindowModel.swift` | `ChatWindowModel`; its `draft` and `files` are those of `draftID` (the selection, nil for a new chat) through a `ComposerDraft` |
| `ChatPanel.swift` | `ChatPanel` (`showsHeader`, false in a chat window; the header's `chatPicker` and `symbol(of:)`), `ChatPanelModel` (`draft` and `files` through a `ComposerDraft`, `show(_:)`) |
| `ChatAgentViews.swift` | `ChatAgentRow` (`tag` `agent\|<chat>\|<id>` or `workflow\|<chat>\|<id>`, `parse`), `AgentStateMark`, `AgentListRow`, `AgentDetailView`, `WorkflowDetailView`; `ChatStore` gained `agentRows(of:)`, `agentConversation(_:)`, `openAgent`, `stopWorkflow`, `resumeAgent` (the samples' from `sampleAgents`, `SampleChatStore.withAgents()`); `ChatWindowModel.selectedAgent` and `select(_:)` |
| `ChatWindowView.swift` | `ChatWindowView(chatID:)`: a `ChatPanelModel` on the environment's `chatStore` (previews: `init(chatID:samples:)`), the `ChatPanel` without header, the loading and not-found states, `navigationTitle` and `navigationSubtitle`, and `dismiss()` when the chat goes |
| `ChatDrafts.swift` | `ChatDrafts` (`@Observable`: each chat's text and files, by id, `text(of:)`, `setText(_:of:)`, `files(of:)`, `setFiles(_:of:)`; a value that doesn't change is not written, nor are the models' `draft` and `files` setters: a dictionary or struct written again notifies its views, and the composer's field, writing back what it shows, drew the Chat window forever in 1.0.36 and 1.0.37), `ComposerDraft` (a view's new chat's text and files; `text`, `setText`, `files`, `setFiles` by id, `adopt(_:in:)` when the new chat gets its id, `clear(sentText:sentFiles:from:in:)`). `ChatStore.drafts` holds one per store. |
| `ChatRootView.swift` | `ChatRootView`, `ChatList`, `NewChatPrompt`, `ChatInspector` |
| `ChatTranscript.swift` | `ChatTranscript`, `ChatActivity`, `ChatActivityText`, `ChatAuthorRow`, `ChatTurnView`, `MessageFiles` (a message's files: AZDesign `FileTile`s in a `FlowStack`, Quick Look), `NoticeRow`, `ToolCallRow`, `ApprovalCard`, `ChatFailure`, `ContextChip`, `ProjectChip`, `SuggestionList` |
| `ChatSettingsView.swift` | `ChatSettingsView`, `ReplySettingsRows`, `ChatPermissionsSection`, `ModelRow` |
| `ChatSamples.swift` | `ChatConversation.samples` |
| `SystemPromptsView.swift` | `InternalSkillStore` (protocol: `values(of:)`, `save(_:of:)`), `LiveInternalSkillStore` (public, `init(dataFolder:)`; without a folder it shows the defaults and every save fails), `SampleInternalSkillStore`, `SystemPromptsModel`, `SystemPromptsView` (public, `init(store:)`), `SkillEditor` |
| `FeedbackView.swift` | `FeedbackCLI` (`available`, `checking`, `unavailable`), `FeedbackModel` (`@MainActor @Observable`: `comment`, `screenshot`, `includesScreenshot`, `files`, `context`, `settings`, `isSending`, `failure`; `contextLine`, `cliMessage`, `canSend`, `add(_:)`, `remove(_:)`, `report`, `send()`), `FeedbackView` (public: `init(project:chats:screenshot:context:onFinish:)`, the Send Feedback sheet, [Chat › Feedback](ui/chat.md#feedback)) |
| `ImplementView.swift` | `ImplementModel` (`@MainActor @Observable`: `target`, `settings`, `isStarting`, `failure`; `heading`, `cliMessage`, `canStart`, `start()`), `ImplementView` (public: `init(target:chats:start:onFinish:)`, the Implement sheet with the inspector's `ReplySettingsRows`, [Tickets › Implement sheet](ui/tickets.md#implement-sheet)) |

**System Prompts.** `SystemPromptsModel` (`@MainActor @Observable`) takes the skills (`InternalSkill.all`), a store
and `saveDelay` (1 s). It reads every skill's `InternalSkillValues` at once; `selection` starts on the first
skill. `setContent(_:of:)` shows the change and schedules a save after `saveDelay`, cancelling the one before;
`setModel(_:of:)` and `setEffort(_:of:)` save at once; `save(_:)` writes changed values and records a failure's
`description` in `failures`, cleared by the next save that works; `saveAll()` saves every change. `isSaved(_:)`
compares the shown values with the stored ones. The editor shows `ReplySettingsRows` (identifier
`systemPrompts`) on `ChatSettings(model:effort:)`, with `\.chatStore`'s models, or `ClaudeModel.fallback` while
there are none. The view calls `saveAll()` when the
selection changes and on disappear. ToolsScenes shows it in the `.systemPrompts` tab with `AppData.skillStore`
(`LiveInternalSkillStore(dataFolder: DataFolder.resolve())`), and **System Prompts…** (⌥⌘,) is
`CommandGroup(after: .appSettings)` (`SystemPromptsCommands`), which calls `showOrOpen(.systemPrompts)`.

**Public API**

- `ChatRootView(project:focus:store: LiveChatStore, directory: ProjectDirectory)`; an internal
  `init(project:focus:samples:)` for previews.
- `ChatPanel(project:origin:subject:model:hide:)`; `ChatPanelModel(store: LiveChatStore)`, and the internal
  `init(chats:)` for previews and tests.
- `ChatSettingsView()`: reads `\.chatStore`; the internal `init(previewStatus:)` for previews.
- `LiveChatStore(session: ChatSession, describe: @MainActor (String, JSONValue) -> ToolCallText?)`, its
  `session`, and `EnvironmentValues.chatStore`.
- `ChatGate.check(_:_:_:chats:defaults:mode:bundleTickets:)`: an `internalSkill` caller gets nil for a `read` operation but
  `open_in_app`, otherwise `ToolError(.forbidden, "An internal skill's run only reads.")`; under Ask First, a `changeTickets`
  call whose `ticketID` and `bundleID` are all the chat's own items (`ChatSession.ownsItem`, a bundle's tickets from
  `bundleTickets`, which AppData reads from the ticket session) runs without a card, and so does `watch_ci`; a
  `closeChats` call naming only the calling chat and chats whose `orchestrator` it is runs without one;
  `ChatTools.operations(chats:projects:)`. `ask_questions` and the picker requests refuse a chat whose questions are
  blocked (`ChatSession.questionsRefusal(in:questions:)`), `ask_questions` but once after a CI failure.
- `ChatPreferences.showsPanelKey` (`"chat.showsPanel"`).

**Model.** `ChatConversation`: `id`, `projectID`, `title`, `origin: ToolKind?`, `createdAt`, `turns`,
`updated`; `updatedAt`; `references` (every item attached or read, once, in order). `ChatTurn`: `id`, `author`
(`user`, `claude`), `date`, `attachments`, `blocks`, `isSample`. `ChatBlock`: `id: String`, `content`.
`ChatToolCall`: `action`, `reference?`, `detail?` (nil asks the item's tool through `toolReader`), `failed`.
`ChatApproval`: `id`, `request`, `preview?`, `reference?`, `channel?` (the tool's title and symbol), `decision`.

**Stores.** `protocol ChatStore` (`@MainActor`, internal): `conversation(_:)`, `conversations(of:)`,
`open(_:) async`, `activity(_:) -> ChatActivity?`, `canStop`, `send(_:to:project:origin:attachments:reader:)
async throws(ChatSendError) -> ID`, `decide(_:in:allow:)`, `stop(_:)`, `models`, `replySettings(of:)`,
`setReplySettings(_:of:)`.

- `LiveChatStore` maps `ChatSession`: a conversation is a `LoadedChat`, its turns made by `turns(_:streaming:)`
  from the transcript (a user item starts a user turn; the items after it, the streaming text last, make one
  Claude turn: assistant text, calls, cards, system lines, results that failed other than a stop; sub-agents'
  items and thinking skipped; a result fills its call's `failed` and `detail`). A call of a `hephaestus` tool
  is worded by `describe`; a card's `channel` is the item's tool, or Projects for `projects`. `send` adds the
  project's `ChatItemReference` when the message carries no item.
- `SampleChatStore(conversations: = .samples, engine: = SampleChatEngine())`: the samples and the sample
  engine, for previews and the captures; `activity` is `.reading` while a reply is on its way, and it has no
  models.

**Window and panel models.** `ChatWindowModel(project:focus:store:directory:)` and `ChatPanelModel` keep their
earlier roles; `send` and `sendDraft` are `async` (the draft clears once sent), `failure` holds why a message
wasn't sent, `activity`, `stop` (nil when the store can't stop) and `openSelection()`/`openConversation()`
(called by the views' `.task(id:)`). The window model gives the inspector `replySettings` and
`setReplySettings(_:)`.

**Data flow.** The tool reports its selection with `reportChatSubject` → `Workspace.subjects[tab]` →
`ChatPanel(subject:)` → `ChatPanelModel.attachment(for:)` → `LiveChatStore.send` → `ChatSession.send` → the
CLI → `mcp__hephaestus__<tool>` over HTTP → `ChatGate.check` → the tool's operation → a `toolUse` item → a
`.call` block worded by the operation's `describe`, its detail from `appToolReader`.

**Preferences.** `@AppStorage` keys `chat.showsPanel` (default true), `chat.ticketChanges` and
`chat.projectChanges` (`ChangePermission`, default `askFirst`), `chat.buildStarts` (default `never`). The Chat
window's inspector binds the same three permissions; `ChatGate` reads them.

**Root view.** `NavigationSplitView` (list 220–340) with an `.inspector` (260–400) in `.mac` and `.pad` (on an
iPad, one side column at a time), or a `PhoneStack` with the inspector as a sheet in `.phone`. Toolbar: New Chat
and the inspector toggle. ⇧⌘N is "New Chat". It applies `onFocusRequest`. The composer is AZDesign's
`MessageComposer` with identifier `chat.composer`, with `ChatFailure` over it when a message wasn't sent. The
Chat window has no chat panel.

### MachinesKit

Spec: [Virtual Machines](ui/virtual-machines.md). Not a tool: one window for the Mac, not tied to a project.

| File | Contents |
| --- | --- |
| `Machines.swift` | `VirtualMachine` (`State`: `starting`, `running`, `paused`, `stopping`, `stopped`), `MachineSnapshot`, `MachineImage` (`State`: `ready`, `downloading`, `installing`, `needsSetup`, `failed`), `ImageSetup` (`canFinish`), `MachineStartAction`, their appearance, `StorageSize`, the samples |
| `MachineStore.swift` | `MachineStore`, the `machineStore` environment entry, `LiveMachineStore` (over `MachineHost`), `SampleMachineStore` (`@Observable`, actions in memory) |
| `MachinesModel.swift` | `MachineSelection`, `MachineDetailContent`, `MachinesModel`, `MachineSheet`, `MachineAlert` |
| `MachinesRootView.swift` | `MachinesRootView` (sheets, alerts, the deletion dialog), `MachineList`, `MachineRow`, `ImageRow`, `pageName(_:layout:)` |
| `MachineDetailView.swift` | `MachineDetail`, `MachineInfo`, `SnapshotRow`, `MachineScreen`, `DesktopStandIn`, `ConsoleStandIn` |
| `ImageDetailView.swift` | `ImageDetail`, `GuestAccountSection`, `ImageSetupView` |
| `MachineScreenView.swift` | `VirtualMachineScreen` (`VZVirtualMachineView`), `GuestKeyStroke`, `KeyboardLayoutKeys`, `GuestKeyboard` (Type Password), `TypePasswordButton` |
| `MachineSheets.swift` | `NewMachineSheet`, `EditMachineSheet`, `AddImageSheet`, `ShellSheet` |
| `MachineSettingsView.swift` | `MachineSettingsView` (Settings ▸ Virtual Machines) |
| `MachineTools.swift` | `MachineTools.operations(host:)`, the sixteen `vm_` tools ([MCP](mcp.md#tools)) |

**Public API**: `MachinesRootView(focus:store:)`, `LiveMachineStore(host:)`, `MachineSettingsView(store:)`,
`MachineTools.operations(host:)`, `EnvironmentValues.machineStore`.

**Store.** `MachineStore` (`AnyObject`, main actor): `machines`, `images`, `offersSnapshots`, `defaults`,
`canStartAnother`, `failures`, `clearFailure`, and the actions, each `throws(MachineError)`: `versions`,
`addImage`, `deleteImage`, `setAccount`, `password(ofImage:)`, `startSetup`, `restartInRecovery`, `finishSetup`,
`stopSetup`, `createMachine`, `start`, `stop`, `pause`, `resume`, `updateMachine`, `deleteMachine`, `setDefaults`,
`shell`, `screen(_:)` (the framework's machine for the screen), `minimumDiskGB(ofImage:)`. `LiveMachineStore` maps
the host's files and runs to the window's values at each read, so the window follows the observable host.

**`MachinesModel`**: `macWidth = 900`, `store`, `machines` and `images` (read from the store), `selection`,
`sheet`, `alert`, `pendingDeletion`, `busy` (private set), `opensSelection`, the layout state. `perform(_:_:_:)` runs
an action with its item marked busy and turns a failure into an alert; `start`, `stop`, `pause`,
`confirmDeletion`, `showFailures`. `convenience init(focus:store:)` selects the focus, else the first machine.
`select(focus:)`, `content`, `content(of:)`, `resize(to:)`, `apply(_:)`, `isInspectorShown`, `toggleInspector()`,
`setInspectorShown(_:)`, `setSidebarShown(_:)`.

**Root view.** It measures itself with `adaptiveWindow` (minimum 390 × 420) and passes each new layout to
`model.apply`. `NavigationSplitView` (sidebar 220–320) or a `PhoneStack`. The inspector toggle uses
`withMotion(.panel)`. ⇧⌘N opens New Machine. A machine's project opens `.project(id)`. Routes reach it as
described under [ToolsScenes](#routehost-and-route-handling).

## Cross-cutting patterns

### Concurrency and isolation

- Swift 6 language mode everywhere: `SWIFT_VERSION = 6.0` in the app target, tools version 6.2 in the package.
- Every UI target of the package defaults to the main actor (`.defaultIsolation(MainActor.self)`); so does
  the app target (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The data targets have no default isolation:
  their values are `Sendable`, their shared state sits behind a `Mutex` (`OwnWrites`, `FolderLock`,
  `SystemProcessRunner`, the process waiters and pipe readers) or an `Atomic`, and `FileEventHub` is an actor.
  Blocking calls (`waitpid`, pipe reads) run on threads of their own, never on the cooperative pool.
- Plain data types are marked `nonisolated` and `Sendable`: all of ToolsFoundation's, and the value types a
  `Layout`, a `Table` sort or a background task touches (`RequestRow`, the Dashboard's grid types, the
  Contracts, Machines and Builds values).
- Environment and focused-value keys are `nonisolated private struct`s. Actions stored in environment values
  are `@MainActor @Sendable` closures wrapped in a struct with `callAsFunction`.
- In the windows, the only asynchronous work is the chat's reply: a `Task` in `ChatStore.send` that awaits the
  engine.

### Models, stores and views

- One `@Observable final class` model per window or panel: `ProjectsModel`, `ProjectPickerModel`,
  `DashboardModel`, `TicketsModel`, `ServiceMapModel`, `ContractsModel`, `BuildsModel`, `ChatWindowModel`,
  `ChatPanelModel`, `MachinesModel`. Shared observable stores: `ChatStore` and the Dashboard layout stores.
- A root view keeps its model in `@State private var model`, set once with `State(initialValue:)` in its
  initializer. A tab keeps its tool's model in a public tab state (`TicketsTabState`…), so the model outlives
  the view while another tab is in front; another project makes a new one.
- A model's dependencies are protocols (`…Store`, `ChatEngine`), held as `any …` and often
  `@ObservationIgnored`. The app uses the `Sample…Store`s; tests use `Mock…Store`s defined in the test files.
- Views render the model and forward actions. Navigation goes out as routes (`openRoute`), or as closures for
  actions a parent owns.
- Components come from AZDesign. A view's private parts stay `private struct`s in its file.

### Previews

- Every view has one `#Preview` per meaningful state, with a stable name: "Loaded", "Loaded, Dark", "Empty",
  "No Matches", "iPad", "iPhone", "Largest Text", and so on (185 previews). Each window page lists its own.
- Traits come from AZDesign: `.appChrome` (the tint), `.padLayout` with a width from 640 to the Mac width,
  `.phoneLayout` with a width below 640, `.largestText`. Sizes use `.fixedLayout(width:height:)` or
  `.sizeThatFitsLayout`; dark variants add `.preferredColorScheme(.dark)`.
- Previews build models with sample stores through the internal `init(model:)`.

### Accessibility identifiers

Every meaningful element has an `accessibilityIdentifier` shaped `screen.element[.qualifier]`. Each window
page lists its identifiers. The screens:

| Prefix | Where |
| --- | --- |
| `projects.` | Projects window |
| `launcher.` | Menu bar panel |
| `projectSwitcher.`, `toolbar.projectSwitcher` | Project switcher |
| `toolbar.chatPanel` | Chat panel button |
| `window.noProject` | A tool's tab whose project isn't loaded |
| `tabs`, `tabs.tab.`, `tabs.new` | The tab bar, a tab, New Tab |
| `chatPanel.noProject` | The chat panel without a project |
| `dashboard.` | Dashboard |
| `tickets.`, `ticket.`, `newTicket.` | Tickets: list and sidebar, a ticket's page, the New Ticket sheet |
| `serviceMap.` | Service Map |
| `contracts.` | Contracts |
| `builds.` | Builds |
| `chat.` | Chat window and chat panel |
| `settings.chat.` | Settings ▸ Chat |
| `machines.` | Virtual Machines |

Qualifiers are data ids (`tickets.row.ORD-142`), `DashboardSlot.identifier` for widgets, or
`ChatSuggestion.identifier(for:)` for suggestions. Components that take an `identifier` derive their parts'
identifiers from it (`chat.composer.field`, `chat.composer.send`).

### Localization

- English first. The package's `defaultLocalization` is `"en"`; the project's development region is `en`.
- **One String Catalog per target**: `Sources/<Target>/Localizable.xcstrings`, processed as the target's
  resource. Code looks strings up in its own bundle with `#bundle`: `Text("No Tickets", bundle: #bundle)`, or
  `String(localized: "New Ticket", bundle: #bundle)` for APIs that take a `String`. No view uses
  `LocalizedStringKey`, which would look in the app's catalog. Data is shown with `Text(verbatim:)`.
- **Whole sentences**, values interpolated: one case per status and priority in `TicketsReader.detail(of:)`,
  for example. Comments explain context where a string is ambiguous.
- **Counts** use automatic grammar agreement, `AttributedString(localized: "^[\(n) call](inflect: true)", …)`,
  and data inside such strings goes through `ServiceMapFormat.literal(_:)`. **Units** use Foundation formatters
  (`Duration.UnitsFormatStyle`, `Measurement`, `.percent`, `.number.notation(.compactName)`).
- Readers that tests check in English take a `locale` (`ContractsReader.read(_:project:store:locale:)`).
- **`scripts/sync-strings.sh [derived data]`** (zsh). Without an argument it builds the package into
  `HephaestusV3Kit/.build/strings` (`xcodebuild -quiet -scheme HephaestusV3Kit -destination 'platform=macOS'
  -derivedDataPath … build`); with one, it uses that DerivedData folder of HephaestusV3Kit or HephaestusV3.
  For each catalog it finds the target's `.stringsdata` files under
  `Build/Intermediates.noindex/**/(<Target>|<Target>-t).build/Objects-normal/*/`, runs
  `xcrun xcstringstool sync <catalog> --stringsdata <files>` (strings no longer used become stale), and prints
  the count. It exits with 2 when a target has no `.stringsdata`. Then it greps `Sources` for SwiftUI calls
  that take a string literal (`Text("`, `Button("`, `Label("`, `.help("`, `.navigationTitle("`,
  `String(localized: "`, `LocalizedStringResource("`, `LocalizedStringKey`, and the other APIs in its
  pattern) on lines without `bundle:`, skipping `#Preview(` lines, lines ending in `"""` and comment lines. It
  lists them and exits with 1 when there is one. Command-line builds don't fill catalogs; Xcode does as it
  builds in the IDE.

### Motion and code font

- Motion uses AZDesign presets only: `withMotion(.panel)` for the chat panel (`ChatPanelControl.toggle()`) and
  the Virtual Machines inspector, `.motionTransition(.panel, edge: .trailing)` for the chat panel's
  appearance, and `withMotion(.layout)` for the Dashboard's steps and removals. AZDesign turns each into a
  0.15-second fade under Reduce Motion. See [Foundations › Motion](ui/foundations.md#motion).
- Code views use AZDesignCode's `codeFont(_:)`: `.callout` for build logs (`BuildsRootView`), request URLs
  and bodies (`OperationView`) and the Linux console (`MachineDetailView`); `.caption` for the Service Map's
  log lines (`MapInspector`). Identifiers, paths and hashes in lists use the system's `.monospaced()`.

### Persistence

| What | Where | Key | Value |
| --- | --- | --- | --- |
| Chat panel offered | `UserDefaults.standard` (`@AppStorage`) | `chat.showsPanel` | `Bool`, default true |
| Settings' tab | same | `settings.pane` | `SettingsPane` raw value, default `general` |
| A chat window's chat | Window restoration | — | `ChatWindowValue` (`Codable`) |
| Claude's permissions | same | `chat.ticketChanges`, `chat.projectChanges`, `chat.apiCalls`, `chat.clusterChanges`, `chat.machineChanges` | `ChangePermission` raw value, default `askFirst` |
| Build starts permission | same | `chat.buildStarts` | `ChangePermission` raw value, default `never` |
| Chat panel shown | Scene storage of each window | `chatPanelShown` | `Bool`, default true |
| A window's tabs, each tab's focus and the selected tab | Window restoration | — | `WorkspaceValue` (`Codable`) |

Everything else lasts as long as the app runs: selections, filters, folded parents, drafts. Chats are files
of their projects ([Data › Chats](data.md#chats)). The Projects window's selection starts on `ORD` at each launch.

The files of [Data](data.md) (the project files, `registry.yml`, `current-environments.yml`) are read and
written by the data targets, which the windows reach through the app's live stores.

### Sample data

All data is sample data around `SampleClock`, 11 November 2026 at 14:00. Each kind lives beside the code that
uses it:

| Data | Where |
| --- | --- |
| Projects, environments, figures | `ToolsFoundation/SampleProjects.swift` |
| Activity events | `ProjectsKit/ActivityItem.swift` |
| Dashboard layouts of Orders and Shop | `DashboardsKit/DashboardSamples.swift` |
| Tickets and bundles | `TicketsKit/SampleTickets.swift` |
| The `shop` namespace per environment; pods | `ServiceMapKit/SampleServiceMap.swift`, `SamplePods.swift` |
| Contracts of Orders, Payments, Edge Gateway | `ContractsKit/SampleContracts.swift` |
| Runs, releases, logs | `BuildsKit/Builds.swift` |
| Conversations | `ChatKit/ChatSamples.swift` |
| Machines and images | `MachinesKit/Machines.swift` |

The samples agree with one another: a ticket's links, a chat's reads and the activity events name the same
runs, requests and services as the other tools' samples. Each window page's "Sample data" section describes
its data.

### Platform-specific code

The package targets macOS only. AppKit appears in four places: `NSWindow` and `NSApp` in `WindowDirectory`,
the rendering of `WindowCapture` (and `NSImage` and `NSWorkspace` icons in the feedback sheet),
`NSScroller` in `DashboardSpace.scrollBarWidth`, and an `NSView` that catches the right click in
`GraphCanvasView`. Builds and the Service Map use `VSplitView` and `HSplitView`. The iPad and iPhone layouts
are the Mac window's own layouts at those widths, through AZDesign's adaptive window.

## Building, testing and running

Sign only with team `USWJAJULN9`. Never pass another team in build settings or `xcodebuild` arguments. If
signing fails with it, stop and ask. The App Group needs a profile that names it: Xcode makes it when it
builds with automatic signing; from the command line, the first build after a capability change needs
`-allowProvisioningUpdates`. In a session with Claude, the `xcode` MCP server builds, runs tests and renders
previews; it can't sign this app, so signed builds use `xcodebuild`.

| Task | In Xcode | From the command line |
| --- | --- | --- |
| Build and run the app | Open `HephaestusV3.xcodeproj`, scheme `HephaestusV3`, My Mac, Run | `xcodebuild -project HephaestusV3.xcodeproj -scheme HephaestusV3 -destination 'platform=macOS' [-allowProvisioningUpdates] build` |
| Run the unit tests | Scheme `HephaestusV3Kit`, Test | `cd HephaestusV3Kit && xcodebuild -scheme HephaestusV3Kit -destination 'platform=macOS' test` |
| See a view's states | Open the view's file, the canvas shows its `#Preview`s | — |
| Fill the String Catalogs and check bundles | — | Build first, then `scripts/sync-strings.sh <derived data>` (or no argument to build into `HephaestusV3Kit/.build/strings`) |
| Check the project file after a hand edit | — | `xcrun xcprojformatter --update HephaestusV3.xcodeproj` |
| Release | Actions ▸ Release ▸ Run workflow on GitHub | `gh workflow run release.yml -f version=X.Y.Z`; locally, `scripts/build-release.sh --version X.Y.Z` builds the same `.dmg` ([Release](release.md)) |

At launch the app opens the Projects window and shows its menu bar item. Tool windows open from the Projects
window, the Window menu, the menu bar panel or links; macOS restores those open at the last quit.

**What the tests cover** (Swift Testing, `@Suite` and `@Test` with descriptive names; 562 tests, and 5 in the guest agent's package). Tests
use temporary folders only (`FileManager.default.temporaryDirectory`, a new UUID-named folder per test,
deleted afterwards): never the user's projects, data folder, Trash or shell, and no live Claude calls.

| Target | Suites | Covers |
| --- | --- | --- |
| FileStorageTests | YAML coding, Dates, Atomic writes, Own writes the folder lock and the Trash, File events | Kept keys written back in order and layout; read rules (UTF-8, root mapping, keys twice, YAML errors); BOM and CR LF; defaults and required keys; schema; dates read and written; quoting and literal blocks; atomic writes (modes, links, failures, leftovers); own writes; the lock; a test Trash; `YAMLFile`; batches by quiet and maximum delay; one real FSEvents stream in a temporary folder; flag kinds. |
| ExternalToolsTests | Child processes, The login shell's environment, Finding the tools, git ssh and kubectl | Output, status, input, folder, environment, signals, missing executables; the timeout ending a whole process group; `terminateAll`; `env -0` parsing and every capture outcome; `PATH` lookup and the git stub; the commands, arguments, parsing and failures of git, ssh and kubectl. Uses `FakeRunner`. |
| MCPKitTests | JSON values and schemas, JSON-RPC, HTTP, Server | Number kinds and sorted output; every validation message in order; the classification table; initialize, ping, unknown methods and the version header; tools/list and tools/call results, errors and validation; heads, chunked and sized bodies and their limits; bearer tokens; a real listener on a free port answering with the token and refusing the rest. A value of any type without `type`. |
| ProjectDataTests | Project file, Dashboard widgets, Registry and current environments, Data folder, Rules and GitHub, Loading, Outside changes, Creating opening and removing, Inherited settings, Current environment, GitHub page, Session | A complete project file written back byte for byte; every example round-tripping with all its keys; defaults; environments, base URLs and overrides; the Library type and the tint; read normalization and invalid files; the registry and current environments; the data folder's location, mode and lock; `.gitignore`; identifiers, paths, URLs and Kubernetes values; GitHub pages and remotes; tints; loading depth first with every issue; data folder files set aside; outside changes (changed, invalid, renamed identifier, deleted and returning files, the registry, own writes, relevance); create, open and remove with their refusals and sub projects; update with its write rules; inheritance on, off, nested and across types; the current environment chosen, renamed, removed and forgotten; GitHub pages from origins, aliases, typed pages and parents, `.git/config`; the session's start, lock, changes and a real outside change. Fixtures: example project files. Uses `FakeRunner`.; Dashboard widgets: keys of another kind kept, Recent Builds, unknown kinds and statuses refused, each write rule with its message, stored widgets written back as they are, repeated ids. |
| ClusterDataTests | Clusters, Service graph, Traces | kubectl's prefix, status and pods, restart, scale (and its failure message), logs, Argo CD in its namespace and sync, missing fields; the forwarding line; boxes, databases, buckets, arrows and source problems; go.mod and values files; OTLP spans; calls, figures, requests and their logs, the 3 s rule. A fake kubectl; nothing reaches a cluster. |
| ContractDataTests | Contracts | Operations in the order of `paths` and methods, parameters merged, `$ref` across files and outside the folder, schemes, the prefilled body; unreadable files; URLs, query, header order and replacements, the request; JSON in order, form bodies; stored values read, mode 0600, earlier keys left out. Temporary folders only; nothing is sent. |
| BuildDataTests | gh, Builds from gh | Repositories from GitHub pages; gh's environment and the failure messages; runs, a run's jobs and steps, logs by step (CR LF included), re-run and cancel after `--`; releases without drafts, the latest marked; a download's pattern, free name and temporary folder. A fake runner answers gh. |
| ChatDataTests | Chat files, Implement chats, CI chats, Transcripts, Stream mapping, Context usage, Managing chats, Chat settings and answers, Chats on the Claude CLI, Launching the CLI, Internal skills, Internal skill runs, Feedback chats, File tools, Message files, Messages with files, Result images, Questions, Questions in a chat, Picker requests, Picker requests in a chat | A complete chat file written back byte for byte, the `origin` key, the kinds' rules; replay (add, update, lines skipped), lines written by the app, the LF after a line cut short; captures of Claude Code 2.1.309 mapped to items and their ids, streamed text, the CLI's permission request, compaction lines, results after Stop; the CLI located in order, its version and models; a first message (arguments without prompt, hooks or the CLI's tools, the MCP configuration and its chat token, the attached line), a turn replayed to idle, the app's card and the CLI's request answered, Stop, an exit in error, a missing session started again, model and effort. A `FakeLauncher` replays the captures; nothing starts Claude. The internal skills: the list, set-ticket-title and notification-summary, the name format, `SKILL.md` written and read back in a temporary folder, a file without front matter. The probe's commands (with the chats' plugin) and a chat's answer giving its project's. Context usage: the CLI's answer and its rules, the file keeping it, a message asking it. Chat settings and answers: the launch's mode, Ultracode and window; Always Allow passing the suggestions back, Don't Allow's message, Allow All approving what waits. Managing chats: close now or after the turn, Stop cancelling it, reopen, delete to a stand-in Trash, `close_chat`, Resume calling `resume-chat`. Questions: a valid set reordered, each rule's message, V2's item read and written back, the Answers message, the answers' checks; a chat that asks, waits once its turn ends, refuses a second set, and sends the answers with the last one. Result images: mapped after their result and stored as `image-<n>` files. Messages with files: stored, kept on the message, images sent and paths after the text; files alone; a folder refused. Mentioned ids: a message's and a reply's ids (not a code block, a sub-agent's text or a result), and a session reading them from the files. Agents and workflows: V2's workflow capture with its folder (records, agents, transcripts, the agents file read back), its background agent (task id, transcript, end) and its stop capture (`stop_task`), and the `agentId` line. Background work: V2's `stream-background-bash.jsonl` replayed line by line (tasks, the owed turn, the idle timer) and its lines' mapping. Chat notifications: the summary's cleanup, a finished turn and a card waiting reported with their detail and input, nothing for a first state or a Stop, the fallback detail, the chats shown in the key window. Message files: a V2 message's files read and written back with their unknown keys, a stored file's attachment, the path rule (a link out of `.hephaestus/` refused), a 1.0.31 feedback message's files; the feedback message keeps its files. Internal skill runs: the CLI's arguments with and without a system prompt, the JSON answer and its failures (an error, a timeout, no JSON), a run on a session with a fake runner (the skill's values, the folder, the input on standard input) and none before the CLI is checked. File tools: the tools by setting, the answers inside and outside the project's folder, in `.hephaestus/`, through a symbolic link, and a running chat's requests answered at once or with a card. Picker requests: each kind's rules and messages in order, pairs of colors, V2's six items read and written back with their unknown keys, markers and the answer's message, the SF Symbol, sound and font catalogues on fixtures (`PickerCatalogs.Sources.fixtures`: plists, sound files and families in a temporary folder), a project's files walked; a chat that asks, waits once its turn ends, refuses a second request and questions, sends `Symbol: <answer>` once, a picker's notification input, and the App-only kinds. Implement chats: a ticket chat and a bundle chat, their files, titles and first messages, linked before the message, a failed link removing the chat; a bundle chat's orchestrated ticket chat, its settings, the git commands of its branch and worktree on a `GitRecorder` (an earlier worktree and branch removed, a failing command and no git refused), and with `/usr/bin/git` itself in a temporary repository; the working folder; a turn reported to the orchestrator without a Finished event; the report texts; questions blocked until the user writes, not by Resume; a chat's own items. `ChatWorld` takes a runner, a stand-in git in the tools' `PATH` and a GitHub page. CI chats: a ticket's and a bundle's, their files, titles, settings and first message with the project attached, linked first; each check's refusal and a failed link removing the chat; a turn reported to the orchestrator without a Finished event; a failure allowing one question set, used up by it, a pass taking it back; the report texts and the failure rule; full hashes; a ticket's and a bundle's chats in order. |
| TicketDataTests | Ticket and bundle files, Ticket library | A complete ticket and bundle written back byte for byte; defaults, the creation entry and unknown keys; numbers from the counters, skipping existing files; provisional titles and the title, description and status messages; Claude's descriptions taken as written; drafts; link rules 1–7 with their messages and inverse links; history entries in order and changes that write nothing; Claude's status limits; the Complete and Reopened rules, Claude's bundle limits and the Complete rule at load; deletion order and the Trash; comments and their files; attachment copies, names, limits and paths; outside changes, invalid files and removals. Fixtures: example ticket and bundle files. Uses a test Trash folder. The untitled handler (called for tickets created without a title, by the user or Claude, not for titled ones), the generated title (renamed as `automatic`, not over a title given since), titles from answers. Implement's rules: a done ticket or a draft refused, a chat linked once, a bundle's CI chat linked once; Implement All's chat and In Progress in one write, and its conflicts. |
| TextFormatsTests | Language detection, Token kinds, Word lists, Highlighter fixtures, Tokenizer edge cases, Markdown block model, Links, Heading anchors, Ticket and bundle ids, Linked ids, Soft line breaks, Markers, Notations | Every tokenizer against its fixtures and the word lists of [Text](text.md); the block model of every Markdown feature; links, images and path resolution read from [Text](text.md); ids. Fixtures: highlighting examples. Markers: each kind in Markdown, spaces included, a refused value as its source, code spans, code blocks and links, plain text with ids, linked ids. Notations: shortcuts and key caps, recorded keys, the standard shortcuts, font sizes and labels, animation expressions and their messages, system colors. |
| ToolsScenesTests | MCP documentation, Implementer, Tabs, Window directory, Feedback | docs/mcp.md's tools, descriptions and input schemas equal the registry's; chat windows found by their chat, never as workspaces, and their value's round trip; a window's tabs (the initial tab, the tab bar's visibility, adding, closing, moving, Next and Previous, kept tool states, reported items, one chat conversation per project, a project's tab, the restored value); routes over windows ordered far off screen (no macOS tabs, selecting the tab that shows a route with its focus, a new tab in the frontmost window or a window of its own, Merge All Windows); the feedback context line, a window's PNG, overlay placement, the feedback request's temporary folder. Windows are never shown, or ordered far off screen. The Implementer: unknown and malformed ids, the errors' mapping, the calls' rows and cards; `watch_ci`'s first refusals and its row. |
| ToolsFoundationTests | Routes, Strings, Inherited settings | Each `FocusRequest` is new; `ChatReference.route` and ids per environment; shared titles from the catalog; unique tool shortcuts; inherited environments. |
| ProjectsKitTests | Project lists, Projects window, Overview grids, Activity samples, Project picker, Projects from the app's data, New Project, Projects window on the app's data, Project Settings, Project tools | Tree and filtered sections; folding and revealing; focus selection; inherited environments and their note; figures and activity over the family, at most 40; column counts; event ids; highlight, arrow keys, skipping projects without the tool, reset, Return. Uses `MockProjectStore`.; the mapping of kinds, tints and environments; New Project's following fields, rules, type and parent from the folder, sub project folders and default location; the loading, empty and unavailable states; the selection after a removal and at load.; Project Settings' fields, rules and messages, environments added, renamed and removed, pending fields applied together, and inherited environments changed in the sub project's changes.; the five project tools through JSON-RPC on a real session, their refusals and `~/` expansion. |
| DashboardsKitTests | What the Dashboard shows, Edit mode, Steps of the keyboard and VoiceOver, Settings, The Dashboard on the project files, Widgets of unavailable tools | Sample, default and saved lists; hidden service widgets; toolbar environment and time window; a change in every window of a project; list order; titles; Done, remove, add, first save, drags; every step and its limits; title, checkbox and Number rules. The live store on a real session in a temporary folder: the default list whatever the identifier, stored widgets read and written back in their layout with Recent Chats and unknown keys kept, the first change storing the default ids, the time window, a failed change and its message, a change made elsewhere, the mapping. Widgets shown by available tool; hidden widgets keep their places. Uses `MockDashboardLayoutStore`. |
| TicketsKitTests | Implement, The store, The list, Selection and route focus, Comments, New Ticket, The reader, Changes, Tickets from the app's data, Ticket tools, Feedback link | Store queries and counts; grouping, filters, counts, bundles; default selection, focus, repeated routes, hidden and missing tickets, chat subject; comment drafts; the sheet's project, validation, creation and failure; reader sentences and suggestions; next step and status, comments with files, editing, links, deletion, bundles, the store's phases; the live store's mapping of statuses, priorities, links, blocking and activity; the ticket tools on real sessions in temporary folders (creation with a free description, comments with files, absolute paths, filters, Claude's status limits, bundles, deletion); the feedback ticket (the created draft and its description, the attachments in one request, the screenshot left out or missing, a blank title, failures of creation and of attachments, added files). Uses `MockTicketStore`, `RecordingTicketStore` and `SampleTicketStore`. Implement: when it applies, the dependencies alert in ascending number, Implement All's rule. |
| ServiceMapKitTests | Focus formats, Service Map model, Service Map reader, Service widgets, Formats | Focus parsing; opening environment and view; history, Back, Show All; taps; repeated routes; missing items; chat subject; summary; request order and sorting; graph contents; logs; reader per environment, details and suggestions; widget readings; durations, literals, stable layout. Uses `MockServiceMapStore`. |
| ContractsKitTests | Opening, Route focus, Filter, Request, Responses, Reader and chat, Sample contracts | Opening selection and environment; repeated routes, filters cleared, drafts kept; sections and matching; examples, URLs, draft keeping, Send; duration formats; reader sentences and suggestions; sample contracts. Uses `MockContractStore`. |
| BuildsKitTests | Focus, Model, Reader, Samples and logs, Recent Builds widget | Focus parsing; default selection, focus by mode, repeated routes, steps, mode selections, chat subject; reader text and owner repository; default steps, open jobs, log line kinds, sample releases; recent runs within 1–20. Uses `MockBuildStore`. |
| MachinesKitTests | Machines window: selection and routes, Machines window: layouts, Machines: states and sizes, Machines: actions | Opening and route selection, unknown machines, images; Mac width, layout by width, side columns per layout; actions per state, starting and shutting down; size and download formats; sample ids; start, pause, resume and stop through the store, the limit of 2 and its alert, deletions (an image's machines too), a failure shown once, the guest account, Finish Setup's condition. Uses a sample store (`MockMachineStore`). |
| MachineDataTests | Virtual machine files, Guest disks, macOS versions, Guest addresses, Guest agent protocol, Machine host | image.yml and vm.yml written byte for byte, earlier keys, lowercase ids, skipped folders and machines not started by the user; a machine's clone; disk growth (the recovery container moved, both tables, the MBR) and other layouts; ipsw.me's list and order; DHCP leases; frames and a connection over a socket pair; the host with a fake backend: an image's download, install and failures, the interrupted image, the setup and Finish Setup's SIP rule, the missing agent, New Machine's checks and the limit of 2, stop through the agent or at once, edits and the grown disk's container, a machine stopping by itself, deletions, the guest account, the defaults. |
| GuestAgentKitTests (GuestAgent package) | Guest agent | The hello and status, SIP's parsing, exec (outputs, timeout, truncation, params), the file methods, unknown methods (`setEnv` among them). Over a socket pair, `/bin/sh -c`, never as root. |
| ChatKitTests | Implement chats in ChatKit, Chat store, Sample engine, Chat panel, Chat window, Chat wording, System Prompts, Send Feedback, Skill completion, Questions card, Composer files, Context indicator, Drafts, Claude CLI line, Picker cards | Each chat's draft shared by its views and a new chat's kept apart; the panel's pop-up showing another chat with its draft; the CLI line's states and Settings' tab names. Starting and continuing conversations, empty messages, ordering, decisions; mentions and reads; attachments, sending, New Chat, the Chat window route, suggestions; window selection, grouping, new chat, sending; approval sentences, suggestion wording and identifiers, references, unique sample ids; the live store's turns from a transcript (users' items, calls worded by their tools, failed calls, cards and their channels, notices, streamed text); the gate's rules. Uses `MockChatEngine`, and a chat session without projects. System Prompts: opening, the delayed save, Save All, a failed save and its recovery. The file tools' rows and cards, their paths from the project's folder. A message's files from the project's `.hephaestus/`, and those a 1.0.31 feedback message names. Turns: CLI card previews, Always Allow and cancelled answers; the gate under each mode; thinking, the Done line, a sub-agent's call as a step, a call's details and inputs, a call that runs, captions, Find. Skill completion: the skills offered after `/`, their order, the CLI's own commands left out, the completion's text, the limit. Context indicator: tokens and tooltip. Composer files: added once, a folder refused; a paste of files, of an image (a PNG named for its time, cleaned after), of text. Questions card: the question shown first and next, Submit or Next; `ask_questions` refused to other tokens and to skills' runs, its rules before the chat. Picker cards: each card's answer (symbol, sound, a color or a pair and the switch, a recorded shortcut and its warnings, a font's weight and size, an animation's Custom expression), Submit's rules, a request as a block and in Find, the samples' answer. Implement: an implement chat's own items run without a card under Ask First, others still ask, Never and Plan Only refuse; `watch_ci` without a card, and `close_chat` on the chats a chat started; the Implement sheet's model. |

ToolsScenesTests check that docs/mcp.md lists exactly the registered tools, in order, with their
descriptions and input schemas (MCP documentation), a window's tabs (Tabs), routes over the windows' tabs
(Window directory), and the feedback (Feedback). Scenes, the tab bar's drawing, its drags and the menus are
checked by running the app.

## Open issues

Where the code doesn't yet meet the workspace's rules, or the architecture is knowingly incomplete:

- **Chat preferences in `UserDefaults`.** The chat panel switch and Claude's permissions live in
  `UserDefaults.standard`, not in the data folder's `settings.yml`.
- **Routes come only from inside the app.** No URL scheme, App Intents, Spotlight, widgets or Handoff lead
  into it yet. When they come, each becomes a `Route` handled by `RouteHost`. Nothing sends `.machine(id)` yet.
- **Sample only**: Linux machines, machine snapshots and the CPU figure of the Virtual Machines window
  ([Future improvements](future-improvements.md)).
- **ToolsScenes has one suite**, the MCP documentation's; its scenes, routes, `WindowDirectory` and menus are
  checked by running the app.
