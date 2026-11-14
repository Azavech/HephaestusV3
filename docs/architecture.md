# Hephaestus V3 — Architecture

How the app's code is put together: the Xcode project, the package and its targets, the data targets, the
shared vocabulary, the scenes and routes, each tool's models and stores, and the patterns every target follows. The owner's
rule is that everything can be rebuilt straight from the documentation. This page and the
[UI specification](ui/README.md) together are that documentation: the UI pages say what each window shows and
how it behaves, and this page says how the code that draws it is built. [Data](data.md) is the contract of the
files. It links to those pages instead of repeating them. AZDesign documents its own APIs in its `docs/` folder; this page only names the ones the app
uses and links to their pages.

It describes the code as it is in `HephaestusV3Kit/Sources` on 13 November 2026. Where the code doesn't yet
meet the workspace's rules (`~/Developer/Apple/CLAUDE.md`), [Open issues](#open-issues) lists it.

## Contents

1. [Overview](#overview)
2. [Repository layout](#repository-layout)
3. [The Xcode project](#the-xcode-project)
4. [The package](#the-package)
5. [The data targets](#the-data-targets): [FileStorage](#filestorage), [ExternalTools](#externaltools),
   [ProjectData](#projectdata)
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
   └─ ToolsFoundation            shared vocabulary; depends on AZDesign only
ProjectData                      the data folder, the import from V2, the projects (used by ProjectsKit, ToolsScenes)
├─ FileStorage                   YAML in V2's layout, atomic writes, the lock, the Trash, file events
│  └─ Yams                       YAML parsing and emitting (third party, approved by the owner)
└─ ExternalTools                 child processes, the login shell's environment, git, ssh, kubectl
AZDesign (package, by version)   colors, motion, components, styles, adaptive layout, preview traits
AZDesignCode (same package)      Fira Code for code views
```

The architecture rests on a few rules:

- **The app target is thin.** It holds only the entry point. All code lives in the local package
  `HephaestusV3Kit`.
- **One target per tool.** Tool targets depend on ToolsFoundation and AZDesign, never on one another. A tool
  reaches another tool's window by asking for a `Route` through the `openRoute` environment action.
- **One place knows every tool.** ToolsScenes imports every kit. It declares the scenes, opens routes,
  reuses open windows, builds the menus, reads items for the chat, and hands each Dashboard widget to the
  tool whose data it shows.
- **Claude is one more client of the tools.** The chat reads an item only through the tool's own read
  function (`ToolReader`), never by looking into a window.
- **Models and stores.** Each window keeps its state and logic in an `@Observable` model. A model gets its
  data from a store protocol. The app and the previews use sample stores; the tests use mocks.
- **Data without UI.** The data targets import no SwiftUI and are not isolated to the main actor. They read
  and write HephaestusV2's files ([Data](data.md)) and run the command-line tools. Each feature, as it comes
  over from V2, gets a live store built on them beside its sample store.

## Repository layout

```
HephaestusV3/                    the repository root (GitHub: Azavech, private)
├─ CLAUDE.md                     what applies to this repository only
├─ .gitignore                    .DS_Store, xcuserdata/, .build/, .swiftpm/, DerivedData/
├─ HephaestusV3.xcodeproj/       project.xcproj, in Xcode 27.2's JSON format; the app's Package.resolved
│                                in project.xcworkspace/xcshareddata/swiftpm/
├─ HephaestusV3/                 the app target's folder: HephaestusV3App.swift, HephaestusV3.entitlements
├─ HephaestusV3Kit/              the local package
│  ├─ Package.swift
│  ├─ Package.resolved           pins AZDesign's and Yams's versions for the package's own builds and tests
│  ├─ Sources/<Target>/          Swift files, and Localizable.xcstrings, for each target
│  └─ Tests/<Target>Tests/       Swift Testing suites, one folder per tested target; ProjectDataTests/Fixtures/
├─ docs/
│  ├─ architecture.md            this page
│  ├─ data.md                    the files: formats, rules, the data folder, the import from V2
│  ├─ decisions.md               the defaults chosen at design time while bringing V2 over
│  ├─ future-improvements.md     V2's features not brought over yet
│  └─ ui/                        the UI specification and its images/
└─ scripts/
   └─ sync-strings.sh            fills the String Catalogs and checks the bundles
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
| `packages` | one local package, path `HephaestusV3Kit` |
| `files` | the folder `HephaestusV3` (synchronized), a member of the target `HephaestusV3`; the group Products with `HephaestusV3.app` |
| `last-upgrade`, `last-swift-update` | 27.2 |

**Target `HephaestusV3`**: product type application, product `Products/HephaestusV3.app`, build phases
compile sources, frameworks and resources. The frameworks phase links the package product `ToolsScenes` of
`HephaestusV3Kit`. The resources phase is empty: the target has no asset catalog.

| Build setting | Value | Why it matters |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | `fr.azavech.hephaestusv3` | Workspace rule `fr.azavech.<app>`. |
| `INFOPLIST_KEY_CFBundleDisplayName` | `Hephaestus V3` | The name in Finder, the Dock and the menu bar. |
| `PRODUCT_NAME` | `$(TARGET_NAME)` | `HephaestusV3.app`. |
| `GENERATE_INFOPLIST_FILE` | `YES` | No Info.plist file. |
| `DEVELOPMENT_TEAM` | `USWJAJULN9` | The only team allowed (also set at project level). Never another. |
| `CODE_SIGN_STYLE` | `Automatic` | Xcode makes the development profile, which carries the App Group. |
| `CODE_SIGN_ENTITLEMENTS` | `HephaestusV3/HephaestusV3.entitlements` | The App Group. |
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

**Entitlements**, `HephaestusV3/HephaestusV3.entitlements`: only `com.apple.security.application-groups` with
the one group `group.fr.azavech.hephaestusv3`, whose container is the app's data folder ([Data › Data
folder](data.md#data-folder)). The signed app also carries what Xcode adds: the application identifier
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
| `dependencies` | `.package(url: "git@github.com:Azavech/AZDesign.git", from: "0.4.0")`: AZDesign by version, from its GitHub repo over SSH. `.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")`: Yams, the YAML library the owner approved. `Package.resolved` pins the exact versions (AZDesign 0.4.0, revision `b0db917`; Yams 6.2.2, revision `a27b21e`) |

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
| `FileStorage` | Files: YAML in V2's layout, atomic writes, own writes, the folder lock, the Trash, file events. | Yams | `.target(name:, dependencies: [yams])` |
| `ExternalTools` | Child processes: process groups and timeouts, the login shell's environment, the tools' lookup, git, ssh, kubectl. | — | `.target(name:)` |
| `ProjectData` | The data folder, the import from HephaestusV2, the project files and their rules. | FileStorage, ExternalTools | `.target(name:, dependencies:)` |
| `ToolsFoundation` | Shared vocabulary: projects, tools, routes, chat vocabulary, the Dashboard model, `ProjectIcon`. | AZDesign | `.target` |
| `ProjectsKit` | The project selector: the Projects window, the project switcher, the menu bar panel; New Project, Settings ▸ Projects; the mapping of the app's projects. | ToolsFoundation, AZDesign, AZDesignCode, ProjectData, ExternalTools | `toolTarget(_:data:)` |
| `DashboardsKit` | The Dashboard's grid, edit mode, settings and saving; the Project widget. | same | `toolTarget` |
| `TicketsKit` | Tickets; the Tickets widget; the tickets reader. | same | `toolTarget` |
| `ServiceMapKit` | The Service Map and its graph; the service widgets; the Service Map reader. | same | `toolTarget` |
| `ContractsKit` | Contracts and the request builder; the contracts reader. | same | `toolTarget` |
| `BuildsKit` | Builds; the Recent Builds widget; the builds reader. | same | `toolTarget` |
| `MachinesKit` | The Virtual Machines window. | same | `toolTarget` |
| `ChatKit` | The Chat window, the chat panel, Settings ▸ Chat, the shared chat store. | same | `toolTarget` |
| `ToolsScenes` | Scenes, menu commands, route handling, the app's data (`AppData`). The only target that knows every tool. | ToolsFoundation, ProjectData, ProjectsKit, DashboardsKit, TicketsKit, ServiceMapKit, ContractsKit, BuildsKit, MachinesKit, ChatKit, AZDesign | `.target` |

Every UI target has `Localizable.xcstrings` as its only resource; the data targets have none, since their
messages are technical details in English under a window's localized sentence. SwiftPM builds it into the bundle
`HephaestusV3Kit_<Target>.bundle`, which Foundation's `#bundle` macro resolves to in that target's code.

**Test targets**: `FileStorageTests`, `ExternalToolsTests`, `ProjectDataTests` (with the resource
`.copy("Fixtures")`), `ToolsFoundationTests`, `ProjectsKitTests`, `DashboardsKitTests`, `TicketsKitTests`,
`ServiceMapKitTests`, `ContractsKitTests`, `BuildsKitTests`, `MachinesKitTests`, `ChatKitTests`. Each depends
only on its target, uses Swift Testing and `@testable import`. ToolsScenes has no test target.

**Dependency rules**

- A tool target may depend on the data target of its own feature once the feature has come over from V2
  (ProjectsKit on ProjectData), never on another tool target.
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
release 0.4.0. Its reference pages (`docs/` in the AZDesign repo) document each API (the Docs column).

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
| Styles | `.badge(_:)`, `.tintedIcon(_:)` (label styles); `.detailRow`, `.detailRow(combinesChildren:)`, `.stacked` (labeled content styles); `.suggestion` (button style) | Most kits | `styles.md` |
| Modifiers | `foreground(_:onSelection:)`, `toolbarLabelPadding()` | Most kits | `styles.md` |
| Preview traits | `.appChrome`, `.padLayout`, `.phoneLayout`, `.largestText` | Every kit's previews | `layout.md` |

## The data targets

Three targets without UI hold the data code that V3 brings over from HephaestusV2. They import no SwiftUI,
have no default isolation, and keep shared state in `Mutex`es and actors. Today they are built and tested but
no window uses them yet: each feature wires them in as it comes over ([Open issues](#open-issues)).

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
- **`ISODate`** is V2's: proleptic Gregorian calendar arithmetic in UTC (days from and to the civil date, by
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

Running the command-line tools with the rules of HephaestusV2's child processes. Source files in
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
| `RegistryFile.swift` | `RegistryFile` (`loadableEntries`) |
| `CurrentEnvironmentsFile.swift` | `CurrentEnvironmentsFile` |
| `ProjectFolder.swift` | `ProjectFolder`: the `.hephaestus/` paths, `isProject`, `ensureGitignore(ownWrites:)`, `gitignoreLine` |
| `DataFolder.swift` | `DataFolder`: `resolve(environment:container:)`, `appGroup`, `overrideVariable`, `registryFile`, `currentEnvironmentsFile`, `invalidCopy(of:)`, `createIfNeeded()`, `lock()` |
| `V2Import.swift` | `V2Import`: `runIfNeeded(into:from:ownWrites:)`, `Result`, `defaultV2Folder(homeDirectory:)`, `v2ProjectIdentifier` |
| `ProjectRules.swift` | `ProjectRules`, `ProjectRuleError` |
| `GitHub.swift` | `GitHubPage`, `GitRemote` (`init?(remoteURL:)`, `isGitHubHost`, `gitHubPage(resolvedHostName:)`) |
| `ProjectSnapshot.swift` | `ProjectSnapshot` (`revision`, `projects`, `issues`, `project(_:)`, `project(atRoot:)`, `family(of:)`), `LoadedProject` (`root`, `file`, `parentID`, `depth`, `childIDs`, `resolved`, `fileIssue`), `ResolvedSettings`, `ProjectIssue` (`path`, `source`, `reason`) |
| `ProjectError.swift` | `ProjectError` |
| `ProjectLibrary.swift` | `ProjectLibrary` (`load()`, `handle(_:)`, `watchedFolders`, `setTools(_:)`, `refreshOrigins()`, `create(_:)`, `open(folder:)`, `update(_:_:)`, `remove(_:)`, `setCurrentEnvironment(_:to:)`), `NewProject`, `ProjectChange` |
| `ProjectSession.swift` | `ProjectSession` (`phase`, `snapshot`, `importResult`, `shell`, `tools`, `isLookingUpTools`, `kubectl`, `start()`, `lookUpTools()`, `stop()`, and the changes) |

- **File types.** Each is a `Codable`, `Sendable`, `Hashable` struct whose `init(from:)` reads with a
  `MappingReader` and whose `encode(to:)` writes with a `MappingWriter`, key by key in the order of its table
  in [Data](data.md), then its unknown keys. Single-line strings are trimmed with
  `ProjectRules.trimmedOrNil`.
- **`ProjectFile`** keeps V2's keys it doesn't use in `keptV2Keys`, read with `raw(_:)` and written with
  `encodeIfPresent` at their places: `webTabs`, `skills`, `chatDefaults` after `subprojects`;
  `dashboardWidgets`, `dashboardGraphWindow`, `deletedChats`, `commentAnswers` after `environmentOverrides`.
  `color`, `icon` and `githubPage` are left out when nil and `graphEnabled` while false.
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
  `failed(ProjectError)`), `snapshot`, `importResult`, `shell` and `tools`, and call its async throwing
  changes, which forward to the library and keep the snapshot they return (a snapshot is kept only when its
  revision is higher). `start()` runs the order of [Data › Loading](data.md#loading); it consumes the
  `FileEventHub`'s batches in a task, hands each to `handle(_:)`, and updates the watched folders after each
  change. `lookUpTools()` captures the shell, looks the tools up, gives them to the library and reads the
  origins. `stop()` stops the streams, ends the running tools and releases the lock. `kubectl` is the
  tools' kubectl for the settings' suggestions. Tests give it a temporary data folder, a fake runner and a
  hub with short delays.

## ToolsFoundation

The vocabulary every target speaks. Its data types are `nonisolated public` value types, `Hashable` and
`Sendable`, so that windows can carry them as `WindowGroup` values and focused values even though the target
defaults to the main actor.

| File | Contents |
| --- | --- |
| `Project.swift` | `Project`, `ProjectTint`, `DeploymentEnvironment`, `ProjectActivity`, `SampleClock`, `ProjectTree` |
| `SampleProjects.swift` | `Project.samples`, `Project.tree`, `Project.sample(_:)`, `deploymentEnvironments` |
| `Vocabulary.swift` | `TicketStatus`, `TimeWindow` |
| `Routing.swift` | `ToolKind`, `ToolWindowValue`, `Route` (with `.projectSettings(id)`), `OpenRouteAction`, `FocusRequest`, `onFocusRequest(_:)`, the `activeProject` focused value |
| `ProjectDirectory.swift` | `ProjectDirectory` (`state`, `tree`, `projects`, `unavailable`, `project(_:)`, `update(projects:state:unavailable:)`, `samples()`), `ProjectDirectory.State`, `ProjectDirectory.Unavailable`, the `projectDirectory` and `availableTools` environment values |
| `NewItemCommand.swift` | `NewItemCommand`, the `newItem` focused value, `newItemCommand(_:action:)` |
| `ChatVocabulary.swift` | `ChatReference`, `ToolReading`, `ToolReader`, `ReportChatSubjectAction`, `ChatPanelControl`, `ChatPanelToolbarItem` |
| `Dashboard.swift` | `DashboardWidget`, `DashboardCells`, `DashboardGrid`, `DashboardWidgetKind`, `DashboardProjectField`, `DashboardContext` |
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
| `environments` | `[DeploymentEnvironment]` | Where a service runs. Empty for apps and libraries. Default `[]`. For the app's projects, as they apply (`environmentsAreResolved`). |
| `activity` | `ProjectActivity?` | The figures the Projects window shows; nil for the app's projects until their tools report them. |
| `parentID` | `Project.ID?` | The project whose folder holds this one; nil at the top level. Default nil. |
| `usesParentSettings` | `Bool` | For a sub project: takes its parent's settings, environments included. Default `true`. |
| `environmentsAreResolved` | `Bool` | True for the app's projects: `environments` already apply inheritance, and `ProjectTree.environments(of:)` returns them as they are. Default `false`. |
| `githubPage`, `currentEnvironment`, `fileIssue` | `String?` | The resolved GitHub page, the environment the user works in, and why the project's file is invalid now. Default nil. |

`tools: [ToolKind]` decides which tools apply, in menu order:

| Kind | Tools |
| --- | --- |
| Service with `activity.contractVersion` | dashboard, tickets, serviceMap, contracts, builds, chat |
| Service without one | dashboard, tickets, serviceMap, builds, chat |
| App, library | dashboard, tickets, builds, chat |

`DeploymentEnvironment: Identifiable` has `name` (its `id`), `cluster: String?`, `namespace: String?`,
`url: String?` (the base URL), `health: Health?` (`.healthy`, `.degraded`, `.down`; nil until the Service
Map reads it), `deployment`, `jaeger`, `argoCDApplication`, `kubeconfig` (all `String?`),
`allowsInvalidCertificates: Bool` and `inheritedFrom: Project.ID?`. Appearance adds `healthTitle` (Unknown
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
| `settingsSource(of:)` | The project whose settings apply: itself, or for a sub project with `usesParentSettings`, its parent's source, up the tree. |
| `environments(of:)` | The environments of the settings source. |
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

`ToolKind: String, CaseIterable, Identifiable, Codable, Sendable` names the tools that have a window per
project. `windowID` is its raw value, the id of its `WindowGroup`.

| Case | `title` | `symbol` | `shortcut` (with ⌘) |
| --- | --- | --- | --- |
| `dashboard` | Dashboard | `square.grid.2x2` | 1 |
| `tickets` | Tickets | `checklist` | 2 |
| `serviceMap` | Service Map | `point.3.connected.trianglepath.dotted` | 3 |
| `contracts` | Contracts | `curlybraces.square` | 4 |
| `builds` | Builds | `hammer` | 5 |
| `chat` | Chat | `bubble.left.and.text.bubble.right` | 6 |

The Projects and Virtual Machines windows aren't tools: they have no `ToolKind`.

### Windows and routes

| Type | Definition |
| --- | --- |
| `ToolWindowValue` | `Codable, Hashable`: `projectID: Project.ID`, `focus: String?`, `instance: UUID?`. The value of a tool's `WindowGroup`. `instance` is set only by File ▸ New *Tool* Window, so that SwiftUI opens a new window instead of bringing forward one with an equal value. |
| `Route` | `.project(Project.ID)`, `.projectWindow(Project.ID)`, `.tool(ToolKind, project: Project.ID, focus: String? = nil)`, `.machine(String? = nil)`. `Hashable, Sendable`. |
| `OpenRouteAction` | Wraps `@MainActor @Sendable (Route) -> Void`; called as `openRoute(route)`. |
| `EnvironmentValues.openRoute` | The action. Its default does nothing, so previews open nothing. |
| `FocusedValues.activeProject` | `Project?`: the key window's project, for the menu commands. |
| `FocusRequest` | `Equatable, Sendable`: `focus: String` plus a private `UUID`, so every request is a new value, even for the same item. |
| `EnvironmentValues.focusRequest` | `FocusRequest?`: the latest route's request for this window. Default nil. |
| `View.onFocusRequest(_ select: @escaping (String) -> Void)` | Runs `select(request.focus)` on each change of `focusRequest` (through a private `FocusRequestModifier`). |

A route's focus reaches a tool in one of two ways:

1. **A window that opens** gets the focus in its `ToolWindowValue`. The tool's root view passes it to its
   model's initializer, which selects it.
2. **A window already open** gets a new `FocusRequest` in its environment. The root view applies
   `onFocusRequest { model.select(focus: $0) }`, which selects the item without starting afresh: filters,
   modes and scroll positions stay.

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
them and tools can't import DashboardsKit. The grid and its placement rule are HephaestusV2's code
unchanged. The rules themselves are specified in [Dashboard › Grid, Placement, Lists without
positions](ui/dashboard.md#grid).

**`DashboardWidget`** (`Codable, Sendable, Hashable, Identifiable`):

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
- `init(from:)` decodes leniently: a missing setting takes its default, so older saved lists still read.
- `cells: DashboardCells?` gets the four position values, brought inside the grid by `DashboardGrid.clamped`,
  or nil when any is missing; setting it writes all four.
- `defaultList(for:)`: Project, Tickets, Recent Builds, plus Service Graph when `hasServiceMap(project)`.
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
| `hasServiceMap(_:)` | The project has the Service Map tool and at least one environment. |
| `addable(for:)` | The Add Widget menu's kinds: `instances` only for a service, graph kinds only with `hasServiceMap`. |

**`DashboardProjectField`**: `name`, `identifier`, `type`, `folder`.

**`DashboardContext`**: `project`, `environment: DeploymentEnvironment?`, `window: TimeWindow`, `editing: Bool`
(in edit mode a widget's content takes no click). Every widget view takes `(DashboardWidget, DashboardContext)`.

### Components

`ProjectIcon(_ project:)`: the project's symbol in its tint, hidden from VoiceOver. Every other shared
component comes from AZDesign.

## ToolsScenes

Two files: `ToolsScenes.swift` (scenes, `RouteHost`, `ToolWindowRoot`, commands, the tool reader, the widget
mapping, Mac widths) and `WindowDirectory.swift` (window reuse). Its only public type is
`public struct ToolsScenes: Scene` with `public init()`.

### Scenes

`SceneID.projects = "projects"`, `SceneID.machines = "machines"`. Every scene's content is wrapped in
`RouteHost`.

| Scene | Type | Id | Content | Default size | At launch |
| --- | --- | --- | --- | --- | --- |
| Projects | `Window(Text("Projects", bundle: #bundle), id:)` | `projects` | `ProjectsRootView(directory: appData.directory, session: appData.session, selection: $selectedProjectID)`, with `focusedSceneValue(\.activeProject, …)` and `registersWindow(.projects, projectID: selectedProjectID)` | 1040 × 680 | Opens |
| Dashboard, Tickets, Service Map, Contracts, Builds, Chat | `WindowGroup(Text(tool.title), id: tool.windowID, for: ToolWindowValue.self)` | the tool's `windowID` | `ToolWindowRoot(tool:value:)` | 1240 × 820, 1180 × 760, 1320 × 840, 1120 × 740, 1180 × 720, 1180 × 780 | `.defaultLaunchBehavior(.suppressed)` |
| Virtual Machines | `Window(Text("Virtual Machines", bundle: #bundle), id:)` | `machines` | `MachinesRootView(focus: machineFocus)`, with `.environment(\.focusRequest, machineFocusRequest)` and `registersWindow(.machines, projectID: nil)` | 1100 × 760 | Suppressed |
| Menu bar | `MenuBarExtra(String(localized: "Open Project"), systemImage: "wrench.and.screwdriver")`, `.menuBarExtraStyle(.window)` | — | `ProjectLauncher(projects: appData.directory.projects)` | 360 × 460 (the panel's own) | Always present |
| Settings | `Settings` | — | `TabView`: `ProjectsSettingsPane(session: appData.session)` labeled Projects (`folder`), then `ChatSettingsView()` labeled with Chat's title and symbol while Chat is available; `.frame(width: 520, height: 440)`, `.tint(.accent)` | 520 × 440 | — |

**`AppData`** (`AppData.swift`, `@MainActor @Observable`) is the app's data, created once as ToolsScenes'
`@State`: `session = ProjectSession(dataFolder: DataFolder.resolve())` and `directory =
ProjectDirectory(projects: [], state: .loading)`. `start()` runs once, from the first `RouteHost`'s `.task`:
it starts following the session (`withObservationTracking { directory.update(from: session) }`, registered
again after each change), adds an observer of `NSApplication.willTerminateNotification` that calls
`SystemProcessRunner.shared.terminateAll()`, and awaits `session.start()`. `AppData.availableTools` (empty
today) and `AppData.machinesAvailable` (false) say which tools and windows have come over from V2
([Navigation › Available tools](ui/navigation.md#available-tools)): the Window menu lists only those, and
`RouteHost` gives every view `\.availableTools` and `\.projectDirectory`. The tool windows read their project
from the directory (`directory.project(value.projectID)`, `directory.tree.path(of:)`, the switcher's
`directory.projects`). The File menu gains **Add Existing Folder…** (⌘O, `AddFolderMenuItem`), which calls
the `addFolder` focused value the Projects window publishes. `.projectSettings(id)` opens the Projects
window on the project until Project Settings has its window.

The Projects window carries `.commands { NewItemCommands(); ToolCommands(); ChatPanelCommands() }`, which
apply to the whole app. macOS restores the tool windows open at quit, with their `ToolWindowValue`.

`ToolsScenes` keeps three `@State` values that every `RouteHost` gets as bindings:

| State | Initial | Role |
| --- | --- | --- |
| `selectedProjectID: Project.ID?` | `Project.samples.first?.id` (`ORD`) | The Projects window's selection; routes set it. |
| `machineFocus: String?` | nil | The machine the Virtual Machines window opens on. |
| `machineFocusRequest: FocusRequest?` | nil | A route's request for the open Virtual Machines window. |

### RouteHost and route handling

`private struct RouteHost<Content: View>` reads `@Environment(\.openWindow)` and gives its content three
things: `.environment(\.openRoute, …)`, `.environment(\.toolReader, appToolReader)` and `.tint(.accent)`.
Its `OpenRouteAction` is the one place where routes are opened:

| Route | Handling |
| --- | --- |
| `.project(id)` | Sets `selectedProjectID = id`. Brings forward the Projects window (`bringForward(role: .projects, projectID: nil)`); if none is open, `openWindow(id: "projects")` and `WindowDirectory.activate()`. |
| `.projectWindow(id)` | `bringForward(role: nil, projectID: id)`: the frontmost window of the project, whatever its role. If none, as `.project(id)`. |
| `.tool(tool, project, focus)` | `bringForward(role: .tool(tool), projectID: project, focus: focus)`. If none, `openWindow(id: tool.windowID, value: ToolWindowValue(projectID: project, focus: focus))` and `activate()`. |
| `.machine(id)` | Sets `machineFocus = id`. If `bringForward(role: .machines, projectID: nil)` succeeds and `id` isn't nil, sets `machineFocusRequest = FocusRequest(id)`. Otherwise `openWindow(id: "machines")` and `activate()`. |

Behavior is specified in [Navigation › Routes and Window reuse](ui/navigation.md#routes).

### The tool reader

`private let appToolReader = ToolReader { reference in … }` finds the sample project of
`reference.projectID` (nil if none), then dispatches on `reference.tool`:

| Tool | Read function |
| --- | --- |
| `.tickets` | `TicketsReader.read(reference.focus)` |
| `.serviceMap` | `ServiceMapReader.read(reference.focus, environment: reference.environment, project: project)` |
| `.contracts` | `ContractsReader.read(reference.focus, project: project)` |
| `.builds` | `BuildsReader.read(reference.focus, project: project)` |
| `.dashboard`, `.chat` | nil |

### WindowDirectory

`final class WindowDirectory`, a singleton (`static let shared`), keeps every window with what it shows, so
that a route brings forward a window instead of opening a second one.

- `enum Role: Hashable { case projects, machines, tool(ToolKind) }`.
- Entries are keyed by `ObjectIdentifier(window)`: a `weak var window: NSWindow?`, the `role`, the
  `projectID: Project.ID?` and an optional `select: ((String) -> Void)?`.
- `register(_:role:projectID:select:)` adds or replaces a window's entry.
- `bringForward(role: Role?, projectID: Project.ID?, focus: String? = nil) -> Bool` drops entries whose window
  is gone, keeps those that are visible or minimized and match (`role` nil matches any role; `projectID` nil
  matches any project), and picks the frontmost by its index in `NSApp.orderedWindows` (minimized windows
  last). It calls `select(focus)` when there is a focus, then `show(_:)`. False when nothing matches.
- `static func show(_:)` deminiaturizes the window if needed, calls `makeKeyAndOrderFront(nil)` and
  `NSApp.activate()`.
- `static func activate()` calls `NSApp.activate()`, for windows SwiftUI opens from the menu bar while
  another app is in front.

`WindowReader: NSViewRepresentable` reports its `NSWindow` from `viewDidMoveToWindow()` and from every
`updateNSView`. `View.registersWindow(_ role:projectID:select:)` puts a zero-size, accessibility-hidden
`WindowReader` in the view's background that calls `WindowDirectory.shared.register`. Because it reports on
every update, a window that switches project registers again with its new project.

### ToolWindowRoot

`private struct ToolWindowRoot: View` is every tool window. It takes `tool: ToolKind` and
`@Binding value: ToolWindowValue?`.

| State | Type | Role |
| --- | --- | --- |
| `@SceneStorage("chatPanelShown") chatPanelShown` | `Bool`, false | Whether this window shows the chat panel; per window, across launches. |
| `@AppStorage(ChatPreferences.showsPanelKey) chatPanelEnabled` | `Bool`, true | Settings ▸ Chat: whether tool windows offer the panel. |
| `@State chatSubject` | `ChatReference?` | The item the tool reports, for the panel. |
| `@State chatPanelModel` | `ChatPanelModel()` | The panel's conversation and draft, kept while it is hidden. |
| `@State focusRequest` | `FocusRequest?` | A route's request for this open window. |
| `@State adaptiveWindow` | `AdaptiveWindowState()` | The window's measured size and size classes. |

Constants: `panelWidth = 341` (the panel with its divider), `titleWidth = 760`, `minimumWidth = 390`; the
minimum height is 420.

Derived values:

- `offersChatPanel = chatPanelEnabled && tool != .chat`; `showsChatPanel = offersChatPanel && chatPanelShown`.
- `chatPanelControl = ChatPanelControl(isShown: $chatPanelShown)`.
- `layout = adaptiveWindow.layout(macWidth: tool.macLayoutWidth, sidePanelWidth: showsChatPanel ? 341 : 0)`.

The body, when `value` names a sample project:

1. A `ZStack(alignment: .trailing)` holds the tool's content and, when `showsChatPanel`, the panel.
   - The content is `content(for: project, focus: value.focus)` with `.id(value.projectID)`, so a new
     project rebuilds the tool and its `@State` model. It gets `.environment(\.focusRequest, focusRequest)`
     and a `ReportChatSubjectAction` that writes `chatSubject`. It fills the window, with a trailing padding
     of 341 when the panel shows in the `.mac` layout.
   - The panel is an `HStack` of a `Divider` (except in `.phone`) and
     `ChatPanel(project:origin: tool, subject: chatSubject, model: chatPanelModel) { chatPanelControl.toggle() }`,
     341 wide (the window's width in `.phone`), full height, on `.canvas`, with a shadow of radius 14 in
     `.pad`, and `.motionTransition(.panel, edge: .trailing)`.
2. `.adaptiveWindow($adaptiveWindow, layout: layout)` measures the window and hands the layout, size classes
   and `collapsedFromRegularWidth` to everything inside, the panel included.
3. `.frame(minWidth: 390, minHeight: 420)`; `.environment(\.chatPanel, offersChatPanel ? chatPanelControl : nil)`.
4. `.navigationTitle(Text(tool.title))`, `.navigationSubtitle(Text(verbatim: Project.tree.path(of: project.id)))`,
   and `.toolbar(removing: .title)` while the window is narrower than 760.
5. A `.navigation` toolbar item: `ProjectSwitcher(projects: Project.samples, selection: projectBinding, tool: tool)`.
   Each tool adds its own items and puts `ChatPanelToolbarItem()` last.
6. `focusedSceneValue(\.activeProject, project)`, `focusedSceneValue(\.activeTool, tool)` and
   `focusedSceneValue(\.chatPanel, offersChatPanel ? chatPanelControl : nil)`.

Around it, `registersWindow(.tool(tool), projectID: value?.projectID)` lists the window. Its `select` closure
sets `focusRequest = FocusRequest(focus)` and `value?.focus = focus`, so a restored window reopens on the last
routed item. The tool's initializer runs again with the new focus, but its `@State` model keeps its first
value: the request does the selecting.

`projectBinding` reads `value?.projectID ?? ""`. Setting a different project replaces the value with
`ToolWindowValue(projectID:)`, without focus or instance; the same project changes nothing.
`.onChange(of: value?.projectID)` then replaces `chatPanelModel` with a new one and clears `chatSubject`.

Without a value or with an unknown project, the window shows `ContentUnavailableView` "No Project", "Open
this window from the Projects window.", identifier `window.noProject`, at least 600 × 400, on `.canvas`.

`content(for:focus:)` builds each tool's root view:

| Tool | Root view |
| --- | --- |
| `.dashboard` | `DashboardRootView(project:) { widget, context in DashboardWidgetView(widget:context:) }` |
| `.tickets` | `TicketsRootView(project:focus:)` |
| `.serviceMap` | `ServiceMapRootView(project:focus:)` |
| `.contracts` | `ContractsRootView(project:focus:)` |
| `.builds` | `BuildsRootView(project:focus:)` |
| `.chat` | `ChatRootView(project:focus:)` |

The panel's behavior in each layout is specified in [Chat › Chat panel](ui/chat.md).

### Menu commands and focused values

| Command group | Placement | Items |
| --- | --- | --- |
| `NewItemCommands` | `CommandGroup(replacing: .newItem)` (File) | `NewWindowMenuItem`, then `NewItemMenuItem`. They replace SwiftUI's items, which would open a tool window without a project. |
| `ToolCommands` | `CommandGroup(before: .windowList)` (Window) | `ToolMenuItems`: Projects (⌘0), one item per `ToolKind` (`tool.shortcut`), Virtual Machines (⌘7), a divider. |
| `ChatPanelCommands` | `CommandGroup(after: .sidebar)` (View) | `ChatPanelMenuItem`: Show Chat Panel / Hide Chat Panel, ⌃⌘C. |

- **`NewWindowMenuItem`** reads `activeTool` and `activeProject`. It calls
  `openWindow(id: tool.windowID, value: ToolWindowValue(projectID: project.id, instance: UUID()))`, ⌘N. Its
  title is "New Dashboard Window", "New Tickets Window", "New Service Map Window", "New Contracts Window",
  "New Builds Window", "New Chat Window", or "New Window" without a tool, when it is disabled.
- **`NewItemMenuItem`** reads `newItem`: its title (or "New Item", disabled, without one), ⇧⌘N, calls
  `newItem?()`.
- **`ToolMenuItems`**: Projects brings the Projects window forward or opens it. Each tool item brings forward
  the window of that tool and the key window's project, or opens one; it is disabled unless
  `project?.tools.contains(tool)`. Virtual Machines brings its window forward or opens it.
- **`ChatPanelMenuItem`** reads `FocusedValues.chatPanel`, calls `toggle()`, and is disabled when nil.

| Focused value | Declared in | Set by |
| --- | --- | --- |
| `activeProject: Project?` | ToolsFoundation (public) | The Projects window (its selection) and every tool window (its project). |
| `newItem: NewItemCommand?` | ToolsFoundation (public) | Views that call `newItemCommand(_:action:)`. |
| `activeTool: ToolKind?` | ToolsScenes (internal) | Tool windows. |
| `chatPanel: ChatPanelControl?` | ToolsScenes (internal, `ChatPanelFocusKey`) | Tool windows that offer the panel. |

All are set with `focusedSceneValue`. The menus are specified in [Navigation › Menus and
shortcuts](ui/navigation.md#menus-and-shortcuts).

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
the chat panel open, a tool window needs 341 more. `ToolKind.macLayoutWidth` is an internal extension in
ToolsScenes; the two other windows keep their own.

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
| DashboardsKit | `DashboardRootView`, `DashboardProjectWidget` | `DashboardModel` | `DashboardLayoutStore` → `UserDefaultsDashboardLayoutStore.shared` (app), `SampleDashboardLayoutStore` (previews) | — | none | Project | — | — |
| TicketsKit | `TicketsRootView` | `TicketsModel` | `TicketStore` → `SampleTicketStore` | `TicketsReader` | ticket id | Tickets | New Ticket… | selected ticket |
| ServiceMapKit | `ServiceMapRootView` | `ServiceMapModel` | `ServiceMapStore` → `SampleServiceMapStore` | `ServiceMapReader` | `service:<name>`, `request:<id>` | Instances and the four service widgets | — | inspected service or request |
| ContractsKit | `ContractsRootView` | `ContractsModel` | `ContractStore` → `SampleContractStore` | `ContractsReader` | operation id | — | — | selected operation |
| BuildsKit | `BuildsRootView` | `BuildsModel` | `BuildStore` → `SampleBuildStore` | `BuildsReader` | run number, `release:<tag>` | Recent Builds | — | selected run or release |
| ChatKit | `ChatRootView`, `ChatPanel`, `ChatSettingsView` | `ChatWindowModel`, `ChatPanelModel`, `ChatStore` | `ChatEngine` → `SampleChatEngine` | — | conversation id | — | New Chat | — |
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
- `ProjectsSettingsPane(session:)`; `AddFolderCommand` and the `addFolder` focused value; the mapping of
  `ProjectMapping.swift`.
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
`folderName` the folder name while they aren't edited), `identifier`, `setIdentifier(_:)`, `pickedKind`,
`pickedParent: Project.ID??`, `pickParent(_:)` (moves `location` to the parent's folder), `folderMode`
(`newFolder`, `existingFolder`), `location`, `folderName`, `setFolderName(_:)`, `existingFolder`;
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

The Dashboard's grid, edit mode, settings and saving. The widgets' content comes from the tools. Spec:
[Dashboard](ui/dashboard.md). The grid code is HephaestusV2's (`DashboardView.swift`,
`DashboardGridLayout.swift`), kept as it was except for imports, AZDesign's color, its strings and `nonisolated`.

| File | Contents |
| --- | --- |
| `DashboardModel.swift` | `DashboardModel`, `DashboardGridState`, `DashboardItem` |
| `DashboardLayoutStore.swift` | `DashboardLayout`, `DashboardLayoutStore`, `UserDefaultsDashboardLayoutStore`, `SampleDashboardLayoutStore` |
| `DashboardEdits.swift` | `DashboardContent`, `DashboardSlot`, `DashboardArrangement`, `DashboardStep`, `DashboardEdits` |
| `DashboardGridLayout.swift` | `DashboardSmallestSize`, `DashboardGridMetrics`, `DashboardFrame`, `DashboardGridLayout`, `DashboardDrag`, `DashboardAutoScroll`, `DashboardResizeHandle`, `DashboardOverflow`, `DashboardOverflowLayout`, `DashboardWidgetScroll` |
| `DashboardRootView.swift` | `DashboardSpace`, `DashboardRootView`, the list, the grid, `DashboardScroll`, `DashboardWidgetMenu`, `DashboardWidgetCard`, `DashboardWidgetTitleRow`, `DashboardWidgetSettings`, `DashboardProjectWidget` |
| `DashboardSamples.swift` | `DashboardWidget.sample(for:)` |

**Public API**

- `DashboardRootView<WidgetContent: View>(project: Project, @ViewBuilder widgetContent: @escaping (DashboardWidget, DashboardContext) -> WidgetContent)`.
  It uses `UserDefaultsDashboardLayoutStore.shared`.
- `DashboardProjectWidget(widget: DashboardWidget, context: DashboardContext)`: the Project widget's fields.

**Store and saving.**

- `DashboardLayout: Codable, Equatable`: `widgets: [DashboardWidget]?`, `window: TimeWindow?`,
  `environment: String?`; nil means the user never changed it.
- `protocol DashboardLayoutStore: AnyObject { func layout(of: Project.ID) -> DashboardLayout?; func setLayout(_:of:) }`.
  A store is a shared `@Observable` reference, so a change in one Dashboard window shows at once in every
  other window of the project.
- `UserDefaultsDashboardLayoutStore.shared` uses `UserDefaults.standard`. At init it reads the entries of
  `Project.samples` (an entry that doesn't decode counts as nothing). `setLayout` writes JSON (`JSONEncoder`)
  under `key(_:)`, `"dashboard.<project id>"`, only when the value changed.
- `SampleDashboardLayoutStore(_ layouts: [Project.ID: DashboardLayout] = [:])` keeps everything in memory.

**`DashboardModel`**, `init(project:store:editing: = false)`:

| Group | Members |
| --- | --- |
| State | `project`, `editing` (private set), `settingsSlot: DashboardSlot?`, `drag: DashboardDrag?` (private set), `areaWidth` (0 until laid out), `neededHeights: [DashboardSlot: CGFloat]`, `smallestSizes: [DashboardSlot: CGSize]` |
| What it shows | `widgets` (stored list, else `DashboardWidget.sample(for:)`, else `defaultList(for:)`), `widget(_:)`, `graphEnabled`, `showsTimeWindow`, `showsEnvironment`, `showsNoWidgets`, `addableKinds`, `environment` (the one saved, else the first not healthy of `deploymentEnvironments`, else the first), `window` (saved, else `.hour`), `setEnvironment(_:)`, `setWindow(_:)`, `context` |
| Arrangement | `metrics`, `arrangement(_:)`, `cells(of:)`, `listOrder` (shown widgets by row then column), `grid(metrics:) -> DashboardGridState` (items, the floating widget and the placeholder during a drag) |
| Edit mode | `startEditing()`, `endEditing()` (closes settings, ends a drag), `add(_:rows:)`, `remove(_:)`, `update(_:_:)`, `canStep(_:_:)`, `steps(of:)`, `step(_:_:)` |
| Drag | `dragChanged(_:_:start:location:scrollOffset:)`, `dragEnded(_:_:location:)`, `scrolled(to:)` |
| Measures | `measured(_:height:)`, `measuredSmallest(_:size:)`, `keep(_:)` (forgets widgets that left) |
| Saving | Private `change(_:)` applies an edit to the newest list and saves it only if it changed; private `save(_:)` reads, changes and writes the project's `DashboardLayout`. |

The view reports what only its layout knows: the widget area's width, each widget's needed height and its
title row's size.

**Edits.** `DashboardSlot` (`id: UUID`, `occurrence: Int`) names a widget even when a hand-edited list
repeats an id; `identifier` is the uuid, or `"<uuid>-<n>"` from the second occurrence.
`DashboardArrangement` (`graphEnabled`, `rows: [DashboardSlot: Int]`) gives `cells(of:)` and `storing(_:in:)`.
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

Spec: [Tickets](ui/tickets.md).

| File | Contents |
| --- | --- |
| `Ticket.swift` | `TicketPriority`, `TicketLink`, `TicketEvent`, `Ticket`, `TicketBundle` |
| `TicketStore.swift` | `TicketStore` and its `count` extension, `SampleTicketStore` |
| `TicketsModel.swift` | `TicketFilter`, `TicketFilterSection`, `TicketGroup`, `NewTicketDraft`, `TicketsModel` |
| `TicketsReader.swift` | `TicketsReader` |
| `TicketsRootView.swift` | `TicketsRootView`, `TicketSidebar`, `TicketFilterMenu` |
| `TicketListView.swift` | `TicketListState`, `TicketListView`, `TicketFilterBar`, `TicketRow` |
| `TicketDetailView.swift` | `TicketDetailView`, `TicketProperties`, `LinkRow`, `EventRow`, `TicketNotFoundView` |
| `TicketActions.swift` | `TicketActions: ToolbarContent` |
| `NewTicketView.swift` | `NewTicketView` |
| `TicketAppearance.swift` | `TicketWords`; symbols, colors, shortcuts and next steps of statuses, priorities, links and events |
| `TicketsDashboardWidget.swift` | `TicketsDashboardWidget` |
| `SampleTickets.swift` | `Ticket.samples` (18 tickets), `TicketBundle.samples` |

**Public API**: `TicketsRootView(project: Project, focus: String? = nil)`,
`TicketsReader.read(_ focus: String) -> ToolReading?`, `TicketsDashboardWidget(widget:context:)`.

**Types.** `Ticket`: `id`, `projectID`, `title`, `details`, `status: TicketStatus`, `priority`
(`low`, `medium`, `high`, `urgent`), `labels`, `reporter`, `createdAt`, `updatedAt`, `links: [TicketLink]`,
`events: [TicketEvent]`. `TicketLink`: `id`, `kind` (`service`, `request`, `contract`, `build`), `title`,
`target`; `route(in:)` opens the Service Map (`service:<target>`, `request:<target>`), Contracts or Builds.
`TicketEvent`: `id: Int`, `kind` (`drafted`, `statusChanged`, `commented`), `text`, `date`, `comment: String?`.
`TicketBundle`: `id`, `projectID`, `title`, `ticketIDs`.

**Store.** `protocol TicketStore { tickets(of: Set<Project.ID>); bundles(of: Set<Project.ID>); ticket(_:) }`,
with `count(of:in:includingSubprojects:)` in an extension (the family from `Project.tree`).
`SampleTicketStore` filters `Ticket.samples` and `TicketBundle.samples`.

**`TicketsModel`**, `init(project:focus:filter: = .all, store:)`:

| Group | Members |
| --- | --- |
| Data | `project`, `family` (`Project.tree.family`), `tickets` (the family's), `bundles` (the project's own), private `familyBundles`, `opensSelection` (`focus != nil`) |
| State | `filter: TicketFilter?` (`.all`, `.status`, `.bundle`, `.project`), `selection: Ticket.ID?` (the focus, else the first visible ticket), `isComposing`, `draft: NewTicketDraft`, `commentDrafts` (private set) |
| List | `isGrouped` (family of more than one), `filterSections`, `isFiltered`, `visibleTickets`, `groups`, `listState: TicketListState`, `lets(_:through:)`, `count(_:)`, `doneCount(of:)`, `showAllTickets()`, `title(of:)`, `symbol(of:)` |
| Selection | `selectedTicket`, `missingSelection` (an id a route named that isn't here), `select(focus:)` (selects; a filter that hides it gives way to All Tickets), `bundle(of:)`, `chatSubject` |
| Comments | `commentDraft(for:)`, `setCommentDraft(_:for:)` |
| New Ticket | `newTicketProjects`, `defaultNewTicketProjectID`, `startNewTicket()`, `cancelNewTicket()`, `createNewTicket()` (closes the sheet; saves nothing yet) |

`TicketListState`: `loading`, `empty`, `noMatch(String)`, `failed(message:)`, `loaded([Ticket])`,
`grouped([TicketGroup])`. The model produces `empty`, `noMatch`, `loaded` and `grouped`; previews show the others.

**Reader.** `TicketsReader.read(_:)` reads from `SampleTicketStore`. `read(_:store:)`, `reference(_:)`
(`ChatReference(tool: .tickets, projectID:, focus: id, title: id)`), `detail(of:)` (one sentence per status
and priority, 20 in all) and `suggestions(for:)` (the question the status raises, then "Summarize <id>").

**Widget.** `TicketsDashboardWidget` counts each checked status with `store.count(…)`, including sub projects
when `includeSubprojects` is on.

**Root view.** `NavigationSplitView` with sidebar (190–280), list (300–480) and detail in `.mac` and `.pad`
(`.doubleColumn` in `.pad`), or a `PhoneStack` in `.phone`. The list column sets `chatPanel` to nil, since the
detail column's toolbar holds `ChatPanelToolbarItem(pushesToTrailingEdge: true)`. It reports
`model.chatSubject` on each change of the selection, applies `onFocusRequest`, and makes ⇧⌘N "New Ticket…".
`TicketActions` (status menu, ⌃⌘1–⌃⌘5; next step, ⇧⌘Return) has empty actions.

### ServiceMapKit

Spec: [Service Map](ui/service-map.md), and the service widgets in [Dashboard](ui/dashboard.md#widgets). The
graph is HephaestusV2's code (`GraphLayout.swift`, `GraphMapView.swift`, `GraphColorScale.swift`,
`GraphCanvasView.swift`): keep its algorithm, geometry and X-Ray look.

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
`worker`, `database`, `queue`, `external`, `client`; `isService` for the first three), `requestsPerSecond`,
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

### ContractsKit

Spec: [Contracts](ui/contracts.md).

| File | Contents |
| --- | --- |
| `Contract.swift` | `Contract`, `HTTPMethod`, `Operation`, `Parameter`, `DocumentedResponse`, `SampleResponse`, `RequestDraft` |
| `ContractsModel.swift` | `OperationSection`, `ContractsModel` |
| `ContractsReader.swift` | `ContractsReader` |
| `ContractsRootView.swift` | `ContractsRootView`, `OperationList`, `OperationRow` |
| `OperationView.swift` | `OperationView`, `ParameterList`, `DocumentedResponseRow`, `ResponseView`, `MethodBadge`, `HTTPMethod` colors, `statusColor(_:)` |
| `SampleContracts.swift` | `ContractStore`, `SampleContractStore`, `Contract.sample(for:)` |

**Public API**: `ContractsRootView(project: Project, focus: String? = nil)`,
`ContractsReader.read(_ focus: String, project: Project) -> ToolReading?`.

**Types.** `Contract` (`title`, `version`, `operations`; `tags` in first-appearance order; `operation(_:)`).
`Operation` (`id` = `operationId`, `method: HTTPMethod`, `path`, `summary`, `tag`, `parameters`,
`requestBody: String?`, `responses: [DocumentedResponse]`, `lastResponse: SampleResponse`). `Parameter`
(`name`, `location` `path`/`query`/`header`, `type`, `isRequired`, `example`; `id` `"<location>.<name>"`).
`SampleResponse` (`status`, `duration: Duration`, `bytes`, `body`; `isError` from 400; `durationStyle`:
milliseconds below a second, else seconds with one decimal). `RequestDraft` (`operation`, `values` by
parameter id, `body`; starts from the examples; `subscript(parameter:)`; `url(on:)` fills path parameters and
appends query parameters that have a value; headers don't show).

**Store.** `protocol ContractStore { func contract(of: Project.ID) -> Contract? }`. `SampleContractStore` returns
`Contract.sample(for:)`: Orders API 1.4.0 (`ORD`), Payments (`PAY`) and Edge Gateway (`GW`); nil otherwise.

**`ContractsModel`**, `init(project:focus:store:)`: `project`, `contract`, `opensSelection` (the focus names an
operation), `query`, `environmentName` (Staging when there is one, else the first). `selection` (computed:
selecting another operation starts its request from the examples), `selectedOperation`, `operation(_:)`,
`select(focus:)` (clears a filter that hides it; an unknown id changes nothing), `filterText`, `sections`,
`hasNoMatches`, `matches(_:)` (path, summary or id), `environments`, `environment`, `draft(for:)`,
`update(_:)` (kept only for the selected operation), `canSend`, `send()` (not wired), `chatSubject`.

**Reader.** `ContractsReader.read(_:project:store:locale:)` writes one sentence with the operation's summary,
method, path, contract and last response; `suggestions(for:locale:)` asks why a failed call failed first;
`reference(_:in:)` uses the operation id as focus and title.

**Root view.** `NavigationSplitView` (operations 260–380; `.detailOnly` in `.pad`) or a `PhoneStack`. Toolbar:
environment menu, Send (⌘Return, `.borderedProminent`), `ChatPanelToolbarItem()`. It reports the selected
operation and applies `onFocusRequest`. Without a contract it shows "No Contract".

### BuildsKit

Spec: [Builds](ui/builds.md).

| File | Contents |
| --- | --- |
| `Builds.swift` | `RunStatus`, `WorkflowRun`, `Job`, `Step`, `Release`, `StepReference`, their appearance, `elapsedText(_:)`, `LogLineKind`, the samples and logs |
| `BuildsModel.swift` | `BuildStore`, `SampleBuildStore`, `BuildsFocus`, `BuildsModel` |
| `BuildsReader.swift` | `BuildsReader` |
| `BuildsRootView.swift` | `BuildsRootView` and its rows, tables, inspectors, `LogPane`, `ReleaseNotes` |
| `BuildsDashboardWidget.swift` | `BuildsDashboardWidget` |

**Public API**: `BuildsRootView(project: Project, focus: String? = nil)`,
`BuildsReader.read(_ focus: String, project: Project) -> ToolReading?`, `BuildsDashboardWidget(widget:context:)`.

**Types.** `RunStatus`: `success`, `failure`, `running`, `queued`, `cancelled`. `WorkflowRun` (`id` = run
number, `title`, `workflow`, `branch`, `commit`, `status`, `startedAt`, `duration` in seconds, `jobs`;
`defaultStep`: the failed step, else the running one, else the last that passed; `step(_:)`). `Job` and `Step`
(`name` as id, `status`, `duration`). `Release` (`tag` as id, `title`, `publishedAt`, `assets`, `isPrerelease`,
`isLatest`, `notes`). `StepReference` (`job`, `step`). `LogLineKind(_ line:)`: `error`, `detail`, `quiet`,
`plain`, by how the line starts.

**Focus.** `BuildsFocus`: `.run(Int)` or `.release(String)`; `releasePrefix = "release:"`. `init?(_:)` accepts
ASCII digits for a run, or `release:` and a non-empty tag; `focus` writes it back.

**Store.** `protocol BuildStore { runs(of: Project) -> [WorkflowRun]; releases(of: Project) -> [Release] }`,
newest first. `SampleBuildStore` reads `WorkflowRun.samples(for:)` and `Release.samples(for:)` of the
repository's owner: the first sample project with the same `repository`, so ToolsKit shows Tools' builds.

**`BuildsModel`**, `init(project:focus:store:)`: `Mode` (`runs`, `releases`), `project`, `runs`, `releases`,
`mode`, `selectedRunID` (setting another run shows its `defaultStep`), `selectedReleaseID`, `selectedStep`,
`pageOnOpen: Mode?` (the mode a focus picked, which starts on its page at iPhone width), `currentRun`,
`currentRelease`, `currentStep`, `select(focus:)` (switches mode; a focus that names nothing changes nothing),
`chatSubject` (the run in Runs, the release in Releases).

**Reader.** `BuildsReader.read` reads the repository owner's runs and releases. `reference(_ run:in:)` titles
it "Run <n>"; `reference(_ release:in:)` "Release <tag>" with focus `release:<tag>`.

**Widget.** `BuildsDashboardWidget.recentRuns(of:count:store:)` lists the newest runs within 1–20; a row opens
`.tool(.builds, project:, focus: "<number>")`, except in edit mode.

**Root view.** One body per `WindowLayout`: `.mac` is a `VSplitView` of the table over the log or notes with an
always-open `.inspector` (280–440); `.pad` is a `VSplitView` of the table over an `HSplitView` of the log or
notes and the details; `.phone` is one `PhoneStack` per mode. The mode picker is segmented in the principal
placement, or a menu in `.phone`. Refresh has an empty action. It reports `chatSubject` and applies
`onFocusRequest`.

### ChatKit

Spec: [Chat](ui/chat.md): the Chat window, the chat panel, Settings ▸ Chat.

| File | Contents |
| --- | --- |
| `ChatModel.swift` | `ChatConversation`, `ChatTurn`, `ChatBlock`, `ChatApproval`, `ChangePermission`, `ChatPreferences` |
| `ChatStore.swift` | `ChatStore` |
| `ChatEngine.swift` | `ChatEngine`, `SampleChatEngine` |
| `ChatSuggestion.swift` | `ChatSuggestion` |
| `ChatWindowModel.swift` | `ChatWindowModel` |
| `ChatPanel.swift` | `ChatPanel`, `ChatPanelModel` |
| `ChatRootView.swift` | `ChatRootView`, `ChatList`, `NewChatPrompt`, `ChatInspector` |
| `ChatTranscript.swift` | `ChatTranscript`, `ChatAuthorRow`, `ChatTurnView`, `ToolCallRow`, `ApprovalCard`, `ContextChip`, `ProjectChip`, `SuggestionList` |
| `ChatSettingsView.swift` | `ChatSettingsView`, `ChatPermissionsSection`, `ModelRow` |
| `ChatSamples.swift` | `ChatConversation.samples` |

**Public API**

- `ChatRootView(project: Project, focus: String? = nil, store: ChatStore = .shared)`.
- `ChatPanel(project: Project, origin: ToolKind, subject: ChatReference?, model: ChatPanelModel, hide: @escaping () -> Void)`.
- `ChatPanelModel(store: ChatStore = .shared)`: `@Observable public final class`.
- `ChatSettingsView()`.
- `ChatStore`: `@Observable public final class`, `static let shared`, `static func transient()` (a fresh store with the samples, for previews).
- `ChatPreferences.showsPanelKey` (`"chat.showsPanel"`).

**Model.** `ChatConversation`: `id`, `projectID`, `title`, `origin: ToolKind?` (the tool whose panel started
it; nil from the Chat window), `createdAt`, `turns`; `updatedAt`; `references` (every item attached or read,
once, in order). `ChatTurn`: `id` (`"<conversation>.<n>"` in the samples, a UUID otherwise), `author`
(`user`, `claude`), `date`, `attachments: [ChatReference]`, `blocks`, `isSample`. `ChatBlock`: `id: UUID`,
`content` `.text(String)`, `.toolCall(ChatReference, ToolReading)` or `.approval(ChatApproval)`.
`ChatApproval`: `id`, `change` (`.comment`), `reference`, `preview`, `decision` (`allowed`, `declined`, nil
while waiting); `request` is a whole sentence. `ChangePermission`: `never`, `askFirst`, `always`.

**Store.** `ChatStore(conversations: = ChatConversation.samples, engine: = SampleChatEngine())` holds every
conversation of the app, shared by the Chat windows and every panel, for as long as the app runs.

| Member | Role |
| --- | --- |
| `conversations` (private set), `responding: Set<ID>` (private set) | All conversations; those waiting for a reply. |
| `conversation(_:)`, `conversations(of: Set<Project.ID>)` (latest first), `isResponding(_:)` | Reading. |
| `send(_:to:project:origin:attachments:reader:) -> ID?` | Trims the text (nil if empty); appends to the conversation, or starts one titled with the first 80 characters; appends the user's turn; starts a `Task` that awaits `engine.reply` and appends Claude's turn with `isSample = engine.repliesAreSamples`. |
| `repliesArrived()` | Awaits every reply on its way (for tests). |
| `decide(_:in:allow:)` | Records the decision on the approval it names. |

**Engine.** `protocol ChatEngine { var repliesAreSamples: Bool { get }; func reply(to:attachments:project:reader:) async -> [ChatBlock] }`.
An engine reaches the tools only through `reader`. `SampleChatEngine` (`delay = .milliseconds(700)`) reads
`references(for:attachments:project:)`: the attachments, then the items the message names, each once. Its
`mentions(in:project:)` finds ticket ids `\b([A-Z]{2,5})-\d+\b` whose prefix is a sample project, requests
`\breq-[0-9a-f]{4}\b` and runs `(?i)\brun\s+#?(\d+)\b`. It returns a `.toolCall` block per item its tool can
read, then a text that says no model is connected.

**`ChatWindowModel`**, `init(project:focus:store:)`: `project`, `selection` (the focus, else the latest
conversation of the family), `draft`, `opensSelection`, `newChatID = "chat-new"` (the iPhone's new-chat page),
`family`, `isGrouped`, `sections` (one per family member with conversations), `hasNoConversations`,
`conversation`, `isResponding`, `references`, `suggestions` (`ChatSuggestion.project`), `select(focus:)`,
`startNewChat(asPage:)`, `sendDraft(reader:)`, `send(_:reader:)` (no attachments, `origin: nil`), `decide(_:allow:)`.

**`ChatPanelModel`**: `conversationID`, `draft`, `leftOut: ChatReference.ID?` (the subject the user took off);
`conversation`, `isResponding`, `canStartNewChat`, `attachment(for:)`, `leaveOut(_:)`, `attach()`,
`subjectChanged()`, `suggestions(for:reader:)`, `sendDraft(project:origin:subject:reader:)`,
`send(_:project:origin:subject:reader:)`, `decide(_:allow:)`, `startNewChat()`, and `chatWindowRoute(for:)`,
which is `.tool(.chat, project:, focus: conversationID)`. Each tool window owns one, so hiding the panel keeps
its conversation and draft until New Chat or a project switch.

**Suggestions.** `ChatSuggestion.project` (two questions about the project), `about(_:reader:)` (the tool's
suggestions for the item, else `general(about:)`), and `identifier(for:)`:
`chat.suggestion.<the question's words, lowercased, joined with ->`.

**Data flow of the panel.** The tool reports its selection with `reportChatSubject` →
`ToolWindowRoot.chatSubject` → `ChatPanel(subject:)` → `ChatPanelModel.attachment(for:)` →
`ChatStore.send(…, attachments:, reader: toolReader)` → `ChatEngine.reply` → `appToolReader` →
`<Tool>Reader.read` → a `.toolCall` block. A tool-call row opens `reference.route`.

**Preferences.** `ChatSettingsView` binds `@AppStorage` to `chat.showsPanel` (default true),
`chat.ticketChanges` (`ChangePermission`, default `askFirst`) and `chat.buildStarts` (default `never`; offers
Never and Ask First). The Chat window's inspector binds the same two permissions. Nothing else reads them yet.

**Root view.** `NavigationSplitView` (list 220–340) with an `.inspector` (260–400) in `.mac` and `.pad` (on an
iPad, one side column at a time), or a `PhoneStack` with the inspector as a sheet in `.phone`. Toolbar: New Chat
and the inspector toggle. ⇧⌘N is "New Chat". It applies `onFocusRequest`. The composer is AZDesign's
`MessageComposer` with identifier `chat.composer`. The Chat window has no chat panel.

### MachinesKit

Spec: [Virtual Machines](ui/virtual-machines.md). Not a tool: one window for the Mac, not tied to a project.

| File | Contents |
| --- | --- |
| `Machines.swift` | `VirtualMachine`, `MachineSnapshot`, `MachineImage`, `MachineStartAction`, their appearance, `StorageSize`, the samples |
| `MachinesModel.swift` | `MachineStore`, `SampleMachineStore`, `MachineSelection`, `MachineDetailContent`, `MachinesModel` |
| `MachinesRootView.swift` | `MachinesRootView`, `MachineList`, `MachineRow`, `ImageRow`, `pageName(_:layout:)` |
| `MachineDetailView.swift` | `MachineDetail`, `MachineInfo`, `SnapshotRow`, `MachineScreen`, `DesktopStandIn`, `ConsoleStandIn` |
| `ImageDetailView.swift` | `ImageDetail` |

**Public API**: `MachinesRootView(focus: String? = nil)`.

**Types.** `VirtualMachine`: `id`, `name`, `system` (`macOS`, `linux`), `systemVersion`, `state` (`running`,
`paused`, `stopped`), `cores`, `memoryGB`, `diskGB`, `address: String?`, `projectID: Project.ID?`, `cpuUsage`
(0–1), `snapshots`. `MachineImage`: `id`, `name`, `system`, `sizeGB`, `state` (`ready`,
`downloading(progress:)`). `StorageSize.formatted(gigabytes:fractionDigits:locale:)` uses a unit formatter.
Samples: four machines (`orders-sandbox` first) and the images.

**Store.** `protocol MachineStore { func machines() -> [VirtualMachine]; func images() -> [MachineImage] }`;
`SampleMachineStore(machines: = VirtualMachine.samples, images: = MachineImage.samples)`.

**`MachinesModel`**: `macWidth = 900`, `machines`, `images`, `selection: MachineSelection?` (`.machine(id)`,
`.image(id)`), `opensSelection`, `layout` (private set, `.mac` until measured), `showsSidebar`,
`showsInspector` (private set), `showsInspectorSheet`. `convenience init(focus:store:)` selects the focus,
else the first machine. `select(focus:)`, `content` and `content(of:) -> MachineDetailContent` (`.machine`,
`.image`, `.machineNotFound(id)`, `.nothing`), `resize(to:)`, `apply(_:)` (a new layout shows its panes
afresh), `isInspectorShown`, `toggleInspector()`, `setInspectorShown(_:)` and `setSidebarShown(_:)` (an iPad's
shows one side column at a time).

**Root view.** It measures itself with `adaptiveWindow` (minimum 390 × 420) and passes each new layout to
`model.apply`. `NavigationSplitView` (sidebar 220–320) or a `PhoneStack`. The inspector toggle uses
`withMotion(.panel)`. ⇧⌘N is "New Machine…", with an empty action. A machine's project opens `.project(id)`.
Routes reach it as described under [ToolsScenes](#routehost-and-route-handling): the initial `focus`, then
`FocusRequest` values through `onFocusRequest`.

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
  initializer. In a tool window, `.id(projectID)` gives it a new identity when the project changes.
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
| `window.noProject` | A tool window without a project |
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
| A project's Dashboard | `UserDefaults.standard` | `dashboard.<project id>` | JSON of `DashboardLayout` |
| Chat panel offered | `UserDefaults.standard` (`@AppStorage`) | `chat.showsPanel` | `Bool`, default true |
| Ticket changes permission | same | `chat.ticketChanges` | `ChangePermission` raw value, default `askFirst` |
| Build starts permission | same | `chat.buildStarts` | `ChangePermission` raw value, default `never` |
| Chat panel shown | Scene storage of each tool window | `chatPanelShown` | `Bool`, default false |
| A tool window's project and focus | Window restoration | — | `ToolWindowValue` (`Codable`) |

Everything else lasts as long as the app runs: conversations (`ChatStore.shared`), selections, filters,
folded parents, drafts. The Projects window's selection starts on `ORD` at each launch.

The files of [Data](data.md) (the project files, `registry.yml`, `current-environments.yml`) are read and
written by the data targets, which no window uses yet. As each feature comes over from V2, its data moves from
the table above into those files.

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

The package targets macOS only. AppKit appears in three places: `NSWindow` and `NSApp` in `WindowDirectory`,
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

At launch the app opens the Projects window and shows its menu bar item. Tool windows open from the Projects
window, the Window menu, the menu bar panel or links; macOS restores those open at the last quit.

**What the tests cover** (Swift Testing, `@Suite` and `@Test` with descriptive names; 352 tests). Tests
use temporary folders only (`FileManager.default.temporaryDirectory`, a new UUID-named folder per test,
deleted afterwards): never the user's projects, data folder, Trash or shell, and no live Claude calls.

| Target | Suites | Covers |
| --- | --- | --- |
| FileStorageTests | YAML coding, Dates, Atomic writes, Own writes the folder lock and the Trash, File events | Kept keys written back in order and layout; read rules (UTF-8, root mapping, keys twice, YAML errors); BOM and CR LF; defaults and required keys; schema; dates read and written; quoting and literal blocks; atomic writes (modes, links, failures, leftovers); own writes; the lock; a test Trash; `YAMLFile`; batches by quiet and maximum delay; one real FSEvents stream in a temporary folder; flag kinds. |
| ExternalToolsTests | Child processes, The login shell's environment, Finding the tools, git ssh and kubectl | Output, status, input, folder, environment, signals, missing executables; the timeout ending a whole process group; `terminateAll`; `env -0` parsing and every capture outcome; `PATH` lookup and the git stub; the commands, arguments, parsing and failures of git, ssh and kubectl. Uses `FakeRunner`. |
| ProjectDataTests | Project file, Registry and current environments, Data folder, Import from HephaestusV2, Rules and GitHub, Loading, Outside changes, Creating opening and removing, Inherited settings, Current environment, GitHub page, Session | V2's complete project file written back byte for byte; every V2 example round-tripping with all its keys; defaults; environments, base URLs and overrides; V3's additions; read normalization and invalid files; the registry and current environments; the data folder's location, mode and lock; `.gitignore`; the import's list, skips, choices, single run and missing V2; identifiers, paths, URLs and Kubernetes values; GitHub pages and remotes; tints; loading depth first with every issue; data folder files set aside; outside changes (changed, invalid, renamed identifier, deleted and returning files, the registry, own writes, relevance); create, open and remove with their refusals and sub projects; update with its write rules; inheritance on, off, nested and across types; the current environment chosen, renamed, removed and forgotten; GitHub pages from origins, aliases, typed pages and parents, `.git/config`; the session's start, lock, changes and a real outside change. Fixtures: V2's examples. Uses `FakeRunner`. |
| ToolsFoundationTests | Routes, Strings, Inherited settings | Each `FocusRequest` is new; `ChatReference.route` and ids per environment; shared titles from the catalog; unique tool shortcuts; inherited environments. |
| ProjectsKitTests | Project lists, Projects window, Overview grids, Activity samples, Project picker, Projects from the app's data, New Project, Projects window on the app's data | Tree and filtered sections; folding and revealing; focus selection; inherited environments and their note; figures and activity over the family, at most 40; column counts; event ids; highlight, arrow keys, skipping projects without the tool, reset, Return. Uses `MockProjectStore`.; the mapping of kinds, tints and environments; New Project's following fields, rules, type and parent from the folder, sub project folders and default location; the loading, empty and unavailable states; the selection after a removal and at load. |
| DashboardsKitTests | What the Dashboard shows, Edit mode, Steps of the keyboard and VoiceOver, Settings, Saving | Sample, default and saved lists; hidden service widgets; toolbar environment and time window; a change in every window of a project; list order; titles; Done, remove, add, first save, drags; every step and its limits; title, checkbox and Number rules; lenient decoding; keys. Uses `MockDashboardLayoutStore`. |
| TicketsKitTests | The store, The list, Selection and route focus, Comments, New Ticket, The reader | Store queries and counts; grouping, filters, counts, bundles; default selection, focus, repeated routes, hidden and missing tickets, chat subject; comment drafts; the sheet's project and validation; reader sentences and suggestions. Uses `MockTicketStore`. |
| ServiceMapKitTests | Focus formats, Service Map model, Service Map reader, Service widgets, Formats | Focus parsing; opening environment and view; history, Back, Show All; taps; repeated routes; missing items; chat subject; summary; request order and sorting; graph contents; logs; reader per environment, details and suggestions; widget readings; durations, literals, stable layout. Uses `MockServiceMapStore`. |
| ContractsKitTests | Opening, Route focus, Filter, Request, Responses, Reader and chat, Sample contracts | Opening selection and environment; repeated routes, filters cleared, drafts kept; sections and matching; examples, URLs, draft keeping, Send; duration formats; reader sentences and suggestions; sample contracts. Uses `MockContractStore`. |
| BuildsKitTests | Focus, Model, Reader, Samples and logs, Recent Builds widget | Focus parsing; default selection, focus by mode, repeated routes, steps, mode selections, chat subject; reader text and owner repository; default steps, open jobs, log line kinds, sample releases; recent runs within 1–20. Uses `MockBuildStore`. |
| MachinesKitTests | Machines window: selection and routes, Machines window: layouts, Machines: states and sizes | Opening and route selection, unknown machines, images; Mac width, layout by width, side columns per layout; actions per state; size and download formats; sample ids. Uses `MockMachineStore`. |
| ChatKitTests | Chat store, Sample engine, Chat panel, Chat window, Chat wording | Starting and continuing conversations, empty messages, ordering, decisions; mentions and reads; attachments, sending, New Chat, the Chat window route, suggestions; window selection, grouping, new chat, sending; approval sentences, suggestion wording and identifiers, references, unique sample ids. Uses `MockChatEngine`. |

ToolsScenes has no tests: scenes, routes, `WindowDirectory` and the menus are checked by running the app.

## Open issues

Where the code doesn't yet meet the workspace's rules, or the architecture is knowingly incomplete:

- **Data in `UserDefaults`.** The Dashboard and the chat preferences still live in `UserDefaults.standard`;
  they move into the files of [Data](data.md) with their features (the Dashboard into `project.yml`).
- **Most tools are hidden.** The Projects window, Settings ▸ Projects and the menu bar panel run on the app's
  data; the other tools still run on sample stores, hidden until their features come over
  ([Navigation › Available tools](ui/navigation.md#available-tools)). Project Settings isn't built yet.
- **No asset catalog.** The app target has no app icon.
- **Routes come only from inside the app.** No URL scheme, App Intents, Spotlight, widgets or Handoff lead
  into it yet. When they come, each becomes a `Route` handled by `RouteHost`. Nothing sends `.machine(id)` yet.
- **Sample stores are hard-wired in the hidden tools.** Their root views' public initializers build sample
  stores, and the readers read sample stores directly.
- **Not wired yet**: New Project, New Sub Project, Add Existing Folder, New Machine, ticket status changes,
  next step, Comment, New Ticket's Create (closes the sheet only), Contracts' Send, Builds' Refresh, the
  Service Map's time window and Live. The chat's permissions are stored but no engine reads them. Each
  window page lists its own.
- **ToolsScenes is untested** by unit tests.
