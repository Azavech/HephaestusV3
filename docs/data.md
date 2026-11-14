# Data

Hephaestus V3 keeps its data in plain files: each project's `.hephaestus/` folder, committed with the
project, and the app's data folder, which belongs to this Mac.

This page is the contract for the files, precise enough to rebuild their code from: where each file lives,
its keys in order, its types, defaults and rules, and how files are read and written. The code is in the data
targets of `HephaestusV3Kit` ([Architecture › The data targets](architecture.md#the-data-targets)):
`FileStorage` reads and writes, `ProjectData` knows the files.

A file arrives on this page with the feature that reads it ([Future improvements](future-improvements.md)
lists the features that come later); until then V3 never opens it, and a project's other files stay as they
are.

## Files at a glance

| File | Path | Swift type | Since |
| --- | --- | --- | --- |
| Project file | `<project>/.hephaestus/project.yml` | `ProjectFile` | Foundation |
| Git ignore file | `<project>/.hephaestus/.gitignore` | — (text) | Foundation |
| Registry file | `<data folder>/registry.yml` | `RegistryFile` | Foundation |
| Current environments file | `<data folder>/current-environments.yml` | `CurrentEnvironmentsFile` | Foundation |
| Settings file | `<data folder>/settings.yml` | `SettingsFile` | MCP server |
| Secrets file | `<data folder>/secrets.json` | — (JSON object) | MCP server |
| Ticket file | `<project>/.hephaestus/ticket/<TICKET-ID>.yml` | `TicketFile` | Tickets |
| Bundle file | `<project>/.hephaestus/bundle/<BUNDLE-ID>.yml` | `BundleFile` | Tickets |
| Attachments | `<project>/.hephaestus/attachments/<TICKET-ID>/<id>-<name>` | — (any file) | Tickets |
| Chat file | `<project>/.hephaestus/chats/<CHAT-ID>.yml` | `ChatFile` | Chat |
| Builds | — (read from GitHub with gh, never stored) | — | Builds |
| Contract | `<project>/openapi/contract.yaml` (read only) | `OpenAPIContract` | Contracts |
| Stored request values | `<data folder>/openapi-requests.json` | `StoredContract` | Contracts |
| Chat transcript | `<project>/.hephaestus/chats/<CHAT-ID>.jsonl` | `ChatItem` on each line | Chat |
| Chat MCP configuration | `<data folder>/Runtime/mcp/<CHAT-ID>.json` | — (JSON) | Chat |
| Chat log | `<data folder>/Logs/claude-<CHAT-ID>.log` | — (text) | Chat |
| Image file | `<data folder>/VirtualMachines/Images/<IMAGE-ID>/image.yml` | `ImageFile` | Virtual Machines |
| Machine file | `<data folder>/VirtualMachines/Machines/<VM-ID>/vm.yml` | `MachineFile` | Virtual Machines |

`<data folder>` is `~/Library/Application Support/HephaestusV3/`, or the folder `HEPHAESTUS_DATA_DIR` names ([Data
folder](#data-folder)).

## Conventions

### Encoding

- Files are UTF-8 without a byte order mark, with LF line endings. Readers skip a leading byte order mark and
  accept CR LF. A file that isn't valid UTF-8 is invalid.
- A YAML file holds exactly one YAML document whose root is a mapping.

### Keys and values

- Keys are camelCase.
- Every YAML file has the key `schema` with the value `1`, its first key. An absent `schema` reads as `1`. Any
  other value makes the file invalid: above 1 with the reason `schema <n> was written by a newer version`,
  otherwise `schema must be 1, not <n>`.
- A key that is absent or `null` takes the Default of its table. A required key that is absent or `null`
  makes the file invalid (`<key>: the required key is missing or null`).
- **Writing.** V3 writes every key of a type's table, in the table's order, `null` for an absent optional
  value, except the keys a table says are left out, then the kept keys and the unknown keys
  ([Unknown keys](#unknown-keys)). `[]` and `{}` stand for empty collections. The layout is the one libyaml
  writes through Yams with these options: block style, indent 2, unlimited line width, Unicode kept, LF line
  breaks. A nested mapping is indented by two spaces under its key; a sequence that is the value of a key is
  not indented: its `- ` items start at the key's column. A string with a line break uses a literal block
  (`|`, or `|-` when it doesn't end with a line break). A string YAML would read as another type, such as
  `true`, `null`, `12`, `1.5`, `2026-10-31` or `NO`, is quoted with single quotes, and so is a string that
  can't be plain, such as one starting with `#`. With these rules, a file in this layout is written back byte
  for byte.
- **Reading.** Any YAML style is accepted, flow or block, quoted or plain. A key of type `String` accepts any
  scalar, so an unquoted `NO` reads as the string `NO`. Booleans are `true` and `false`, and YAML 1.1's
  `yes`, `no`, `on` and `off`. A mapping with a key twice makes the file invalid (`the key "<key>" appears
  twice in one mapping`).

### Dates

- Swift type `Date`. Written `yyyy-MM-dd'T'HH:mm:ss'Z'`, in UTC with whole seconds, unquoted: for example
  `2026-10-31T14:03:00Z`.
- Read: `YYYY-MM-DDTHH:MM:SS`, an optional fraction of a second, which is dropped, then `Z` or a numeric offset
  `±HH:MM`, which is converted to UTC. Any other form makes the file invalid
  (`<key>: "<text>" is not a date of the form 2026-10-31T14:03:00Z`).
- Times V3 records are truncated to whole seconds, so a value is unchanged by any number of reads and writes.

### Text

- Single-line values (names) are trimmed of leading and trailing white space and may not contain line breaks.
- Lengths count characters (Swift `Character`s).

### Paths

- Project files store only relative paths: `/` separators, no leading or trailing `/`, no empty, `.` or `..`
  component. A project folder can be moved, renamed or cloned without editing its files.
- Data folder files store absolute paths: a leading `/`, no trailing `/`, no empty, `.` or `..` component;
  symbolic links are not resolved.

### Ids

| Id | Format | Example | Chosen by |
| --- | --- | --- | --- |
| Project identifier | `^[A-Z]{2,8}$` | `ORD` | the user, when creating the project |
| Ticket id | `^[A-Z]{2,8}-[1-9][0-9]*$` | `ORD-142` | V3, from the project's `nextTicketNumber` ([Ticket rules](#ticket-rules)) |
| Bundle id | `^[A-Z]{2,8}-B[1-9][0-9]*$` | `ORD-B3` | V3, from the project's `nextBundleNumber` |
| Attachment and comment id | uppercase UUID | `5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B` | V3, at random |

The identifier is unique among the projects of this Mac, sub projects included. It prefixes the project's
tickets (`ORD-142`). A name suggests one from its ASCII letters, accents removed
(`ProjectRules.suggestedIdentifier(fromName:)`): a name that starts with a capital and has two capitals or more
gives its capitals, at most eight (`AntiBeeCycle` → `ABC`, `YeenCloud` → `YC`, `Orders API` → `OAPI`); any other
name its first four letters, uppercased (`orders` → `ORDE`, `Orders` → `ORDE`); nothing when that gives fewer than
two letters.

## Data folder

The files that belong to this Mac rather than to a project.

- **Location**: `~/Library/Application Support/HephaestusV3/` (`DataFolder.resolve()`). The environment
  variable `HEPHAESTUS_DATA_DIR`, set to an absolute path, names another folder for development; a relative value
  is ignored. Until 14 November 2026 the folder was the App Group container
  (`~/Library/Group Containers/group.fr.azavech.hephaestusv3/`), as the workspace rule wants. The owner moved it:
  macOS lets only a copy whose signature comes with a provisioning profile granting the group use that container,
  and the releases are signed ad-hoc ([Release](release.md)).
- **Copy from the App Group**: at launch, before anything reads the folder, when it doesn't exist yet and the App
  Group container can be read and holds something besides the system's `Library`, its items are copied (APFS
  clones them) into a sibling folder that then takes the folder's name (`DataFolder.migrateFromAppGroup`). The
  container is left as it was. A release copy can't read it, so the copy is made by a development build, signed
  with the team's profile. The app keeps the App Group entitlement for that copy only.
- **Creation**: the folder is created with its missing parents, mode 0700.
- **Lock**: the app holds an exclusive, non-blocking `flock(2)` on the folder while it runs, so that a second
  copy of the app, from another build for example, never writes the same files. The system releases it when
  the app quits or crashes. A folder whose lock another process holds is `in use by another process`.
- **Invalid files**: a data folder file that is invalid when the app starts is renamed `<file>.invalid`,
  replacing an older one, and the app starts from its defaults. (Applied by the loading of the projects.)

| File | Content |
| --- | --- |
| `registry.yml` | The top-level projects ([Registry file](#registry-file)). |
| `current-environments.yml` | The environment chosen for each service ([Current environments file](#current-environments-file)); absent until a first choice. |
| `settings.yml`, `secrets.json` | The app's settings and the MCP server's token ([Settings file](#settings-file), [Secrets file](#secrets-file)). |
| `Runtime/mcp/<CHAT-ID>.json` | A running chat's MCP configuration, mode 0600, deleted when its process ends ([Chat processes](#chat-processes)). |
| `Runtime/claude-cwd/` | The empty folder the CLI's model probe runs in. |
| `Runtime/downloads/<UUID>/` | A release file gh downloads, before it moves into the Downloads folder; removed afterwards ([Builds › Downloads](#downloads)). |
| `VirtualMachines/` | The images and machines ([Virtual machines › Storage](#storage)). |
| `Runtime/guest/` | The guest agent and its install script, shared with a setup machine ([Virtual machines › Setup](#setup)). |
| `Logs/claude-<CHAT-ID>.log` | A chat's CLI log: a line per launch, then the CLI's standard error; emptied at a launch once over 10 MB. |

## Project folder

```
<project>/
  .hephaestus/
    project.yml                       ProjectFile
    .gitignore                        the line "chats/"
    ticket/<TICKET-ID>.yml            TicketFile
    bundle/<BUNDLE-ID>.yml            BundleFile
    attachments/<TICKET-ID>/          the files of a ticket and its comments
    chats/                            chats: their files and transcripts (git-ignored)
```

- A folder is a project when it holds `.hephaestus/project.yml`. The project file doesn't store the folder's
  path: the registry gives it for a top-level project, the parent's `subprojects` for a sub project.
- Every project, sub projects included, has its own `.hephaestus/` folder.
- `.hephaestus/.gitignore` holds the line `chats/`, so chats stay out of git while the rest is committed. When
  V3 creates or adds a project, it writes the file, or adds the line to a file that lacks it, after a line
  break when the file doesn't end with one (`ProjectFolder.ensureGitignore`).
- Other files and folders in `.hephaestus/` are left untouched.

## Project file

`.hephaestus/project.yml`: the project's identity, type, color, icon, counters, documentation folder, GitHub
page, sub projects and environments. Swift type `ProjectFile`. The keys marked **kept** are keys V3 doesn't
use, kept as read at their place in the table's order ([Unknown keys](#unknown-keys)): `webTabs`, `skills`,
`chatDefaults`, `deletedChats`, `commentAnswers`.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | [Keys and values](#keys-and-values). |
| id | `id` | `String` | yes | — | The project identifier ([Ids](#ids)). Set at creation, never changed. Read rule: `id: "<id>" is not a valid project identifier`. |
| name | `name` | `String` | yes | — | One line, 1–100 characters. Names need not be unique. |
| created | `created` | `Date` | yes | — | When the project was created. Never changed. |
| type | `type` | `ProjectKind` | no | `none` | [Project kind](#project-kind). |
| color | `color` | `String?` | no | `null` | `#` and six hex digits, uppercased when read, or the name of a tint ([Project color](#project-color)). Any other value makes the file invalid (`color: "<text>" is not a color of the form #RRGGBB, nor a tint`). Left out of the file when there is none. |
| icon | `icon` | `String?` | no | `null` | An SF Symbol name, such as `hammer`. Read trimmed, an empty value being none. Left out of the file when there is none. |
| nextTicketNumber | `nextTicketNumber` | `Int` | no | `1` | The first number tried for the next ticket. |
| nextBundleNumber | `nextBundleNumber` | `Int` | no | `1` | The first number tried for the next bundle. |
| docsPath | `docsPath` | `String` | no | `docs` | Relative path of the documentation folder, which may be missing. |
| githubPage | `githubPage` | `String?` | no | `null` | The page typed in the GitHub page field, `https://github.com/<owner>/<name>`: read trimmed and without a trailing `/`; any other value makes the file invalid ([GitHub page](#github-page)). Left out of the file when there is none. |
| — | `useParentSettings` | kept | no | absent | V2's switch for a sub project to use its parent's settings. No effect in V3, where a sub project takes every value it leaves empty from its parent ([Resolution](#resolution)); kept as read, never added. |
| subprojects | `subprojects` | `[String]` | no | `[]` | Relative paths of the direct sub projects, in the order they were added, each once. Each names a folder inside this project's folder that holds `.hephaestus/project.yml`. An entry whose folder or file is missing or invalid is kept. |
| — | `webTabs` | kept | no | absent | Web tabs; not used. |
| — | `skills` | kept | no | absent | Enabled skills; not used. |
| — | `chatDefaults` | kept | no | absent | Settings of new chats; not used. |
| graphEnabled | `graphEnabled` | `Bool?` | no | `null` | Whether the graph is enabled; `null` takes the parent's value, `false` for a top-level project ([Resolution](#resolution)). V3 writes `false` too, while set; left out of the file while `null`. |
| environments | `environments` | `[EnvironmentEntry]` | no | `[]` | The project's own environments, whatever its type, in the order they were added; names unique, letter case included ([Project environment](#project-environment)). |
| environmentOverrides | `environmentOverrides` | `[String: EnvironmentOverride]` | no | `{}` | A sub project's changes to the environments it inherits, by environment name, written in Unicode code point order ([Environment override](#environment-override)). A change for a name no inherited environment has is kept and ignored. |
| dashboardWidgets | `dashboardWidgets` | `[DashboardWidgetEntry]?` | no | `null` | The widgets of the project's [Dashboard](ui/dashboard.md), in their order ([Dashboard widget](#dashboard-widget)). `null` shows the default list and `[]` no widget. Left out of the file while the project has no stored list. |
| dashboardGraphWindow | `dashboardGraphWindow` | `DashboardGraphWindow?` | no | `null` | The time window of the Dashboard's service widgets: `fiveMinutes`, `hour`, `day` or `week`; `null` is `hour`. Any other value makes the file invalid. Left out of the file while `null`. V3 has no `week` window yet: a stored `week` is kept, and the Dashboard shows the last hour. |
| — | `deletedChats` | kept | no | absent | Costs of deleted chats; not used. |
| — | `commentAnswers` | kept | no | absent | Costs of comment answers; not used. |
| keptKeys | — | `YAMLMapping` | — | empty | The kept keys present in the file, as read. |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

A `commands` key is an unknown key, not a kept one.

### Project kind

Swift type `ProjectKind`, key `type`: a string enumeration. Any other value makes the file invalid.

| Value | Name |
| --- | --- |
| `none` | Other |
| `goService` | Service |
| `swiftApplication` | App |
| `library` | Library |

### Project color

A project's color is one of AZDesign's semantic colors, a tint (ToolsFoundation's `ProjectTint`), stored by
its name, or a `#RRGGBB` value. The names are
`ProjectColor.tintNames`: `accent`, `accentSecondary`, `info`, `success`, `warning`, compared letter case
included. `ProjectColor.normalized(_:)` returns a tint name as is, `#RRGGBB` uppercased, and nil for anything
else. Defaults chosen at design time.

### GitHub page

`GitHubPage.normalized(_:)`: the text trimmed, one trailing `/` removed; valid when it is
`https://github.com/<owner>/<name>`, `<owner>` of ASCII letters, digits, `-` and `_`, `<name>` of ASCII
letters, digits, `.`, `-` and `_`, and neither `.` nor `..`. A remote of the project's git repository gives a
page too (`GitRemote`), in the forms git writes:

- `[<user>@]<host>:<owner>/<name>` (the scp-like form; the part before the first `:` holds no `/`);
- `ssh://[<user>@]<host>[:<port>]/<owner>/<name>`;
- `https://[<user>@]<host>[:<port>]/<owner>/<name>`;

each with or without a final `.git`. The remote's page is `https://github.com/<owner>/<name>` when its host is
`github.com` in any letter case, or, for the two SSH forms, when the host is an alias whose real host name,
the `hostname` line of `ssh -G <alias>`, is `github.com`.

### Dashboard widget

Swift type `DashboardWidgetEntry`, one element of `dashboardWidgets`: a widget of the project's Dashboard with
its position and size on the Dashboard's grid and its settings ([UI › Dashboard](ui/dashboard.md)). The
Dashboard changes the list through [Update](#changes) and `ProjectChange.dashboardWidgets`.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| id | `id` | `UUID` | yes | — | Unique within the list. |
| kind | `kind` | `Kind` | yes | — | `project`, `tickets`, `recentChats`, `cost`, `instances`, `serviceGraph`, `busiestCalls`, `failedRequests`, `requestsPerMinute` or `recentBuilds`. Any other value makes the file invalid. |
| title | `title` | `String` | no | `""` | The Title setting: one line, at most 100 characters, trimmed; empty means the title of the kind. |
| column | `column` | `Int?` | no | `null` | The first column the widget covers, 0–23. |
| row | `row` | `Int?` | no | `null` | The first row it covers, from 0. |
| width | `width` | `Int?` | no | `null` | The columns it covers, 1–24; `column` + `width` is at most 24. |
| height | `height` | `Int?` | no | `null` | The rows it covers, from 1. |
| fields | `fields` | `[Field]` | no | all four | `project`: the fields shown, among `name`, `identifier`, `type` and `folder`. At least one, each once. |
| statuses | `statuses` | `[Status]` | no | the first four | `tickets`: the counts shown, among `todo`, `in_progress`, `review`, `done` and `draft`. At least one, each once. The default is the first four; a widget V3 adds starts with all five, written in the file. |
| includeSubprojects | `includeSubprojects` | `Bool` | no | `true` | `tickets` and `cost`: whether the counts or the total cover the loaded sub projects. |
| chatCount | `chatCount` | `Int` | no | `5` | `recentChats`: the most chats listed, 1–20. |
| chatKinds | `chatKinds` | `[ChatKind]` | no | all four | `recentChats`: `project`, `ticket`, `bundle`, `feedback`. At least one, each once. |
| count | `count` | `Int` | no | `5` | `busiestCalls`, `failedRequests` and `recentBuilds`: the most rows listed, 1–20. |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

- A widget has the keys `id`, `kind` and `title`, then the four position keys while it has a stored position,
  then the keys of its kind only, in the order of the table: `fields` for `project`; `statuses` and
  `includeSubprojects` for `tickets`; `chatCount` and `chatKinds` for `recentChats`; `includeSubprojects` for
  `cost`; `count` for `busiestCalls`, `failedRequests` and `recentBuilds`; none for `instances`,
  `serviceGraph` and `requestsPerMinute`. A key of another kind is an unknown key of the widget, kept after its
  own keys.
- The position keys are written together, by the Dashboard, when the user moves, resizes, adds or removes a
  widget. A file edited by hand that holds only some of them, or values outside the rules, still loads: the
  Dashboard brings them inside the grid and counts a widget with only some of them as one without position.
- **Write rules**, checked on each widget the list adds or changes, in order
  (`DashboardWidgetEntry.checked`); a widget equal to a stored one is written back as it is, as many times as the
  stored list holds it, and a further copy is a widget the list adds:
  - title: `dashboardWidgets[<n>]: use a title of at most 100 characters on one line.`;
  - only some position keys: `dashboardWidgets[<n>]: give the column, row, width and height together.`;
  - outside the columns: `dashboardWidgets[<n>]: use a column and a width inside the 24 columns.`;
  - a row below 0 or a height below 1: `dashboardWidgets[<n>]: use a row from 0 and a height of at least 1.`;
  - fields, statuses or chat kinds empty or repeated: `dashboardWidgets[<n>]: use at least one <field | status | chat kind>, each once.`;
  - `count` outside 1–20: `dashboardWidgets[<n>]: use a number of rows from 1 to 20.`;
  - `chatCount` outside 1–20: `dashboardWidgets[<n>]: use a number of chats from 1 to 20.`;
  - then an id another widget of the list has: `Widget <ID> is listed more than once.`
- The ids of the default list are `00000000-0000-0000-0000-00000000000<n>` for its n-th widget
  (`DashboardWidgetEntry.defaultID`); the list is in [UI › Dashboard › Default list](ui/dashboard.md#default-list-and-sample-layouts).
- V3 keeps `recentChats` and `cost` widgets, with their settings, and never shows them.

### Project environment

Swift type `EnvironmentEntry`, one element of `environments`: a place where a service runs, with the
Kubernetes resources it runs on.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| name | `name` | `String` | yes | — | One line, 1–100 characters, trimmed. Unique within the project, letter case included. |
| url | `url` | `String?` | no | `null` | The address of the environment's API: an absolute `http` or `https` URL with a host. |
| port | `port` | `Int?` | no | `null` | 1–65535. Replaces the URL's port in the base URL. |
| allowInvalidCertificates | `allowInvalidCertificates` | `Bool` | no | `false` | Requests to the environment accept an invalid server certificate. |
| namespace | `namespace` | `String?` | no | `null` | The Kubernetes namespace of the deployment; `null` uses the current context's. |
| deployment | `deployment` | `String?` | no | `null` | The Kubernetes Deployment that runs the service. |
| jaeger | `jaeger` | `String?` | no | `null` | The Kubernetes Service of the environment's Jaeger, `<namespace>/<name>`: one `/`, parts not empty, no white space. |
| argoCDApplication | `argoCDApplication` | `String?` | no | `null` | The Argo CD Application: `<name>`, in the namespace `argocd`, or `<namespace>/<name>`; one `/` at most, parts not empty, no white space. |
| kubeconfig | `kubeconfig` | `String?` | no | `null` | The kubeconfig file: an absolute path or one starting with `~/`; `null` uses kubectl's default (`KUBECONFIG` of the login shell, else `~/.kube/config`). |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). A `context` key is one: kubectl always uses the kubeconfig file's current context. |

- `url` and the five Kubernetes keys are single lines, read and written trimmed, an empty value being `null`.
- The **base URL** is `url` with its port replaced by `port` when set, without a trailing `/`; none without
  `url` (`EnvironmentEntry.baseURL`).

### Environment override

Swift type `EnvironmentOverride`, one value of `environmentOverrides`, under the name of the environment it
changes. A key with a value replaces the parent's; `null` keeps the parent's, so a change can't remove a
parent's value. Every field of the environment but its name can change: V3 adds `namespace` and
`kubeconfig` to V2's six keys.

| Swift name | Key | Type | Default | Rules |
| --- | --- | --- | --- | --- |
| url | `url` | `String?` | `null` | As `EnvironmentEntry.url`. |
| port | `port` | `Int?` | `null` | 1–65535. |
| allowInvalidCertificates | `allowInvalidCertificates` | `Bool?` | `null` | Stored only while it differs from the parent's. |
| namespace | `namespace` | `String?` | `null` | V3's addition. One line. Left out of the file while `null`. |
| deployment | `deployment` | `String?` | `null` | |
| jaeger | `jaeger` | `String?` | `null` | `<namespace>/<name>`. |
| argoCDApplication | `argoCDApplication` | `String?` | `null` | `<name>` or `<namespace>/<name>`. |
| kubeconfig | `kubeconfig` | `String?` | `null` | V3's addition. As `EnvironmentEntry.kubeconfig`. Left out of the file while `null`. |
| unknownKeys | — | `YAMLMapping` | empty | [Unknown keys](#unknown-keys). |

V2's six keys are written in this order, `null` included; V3's two only when set. The string keys are read
and written trimmed, an empty value being `null`. Names are compared with the
inherited environments' exactly, letter case included. `applied(to:)` gives the parent's environment with the
values the change sets; `isEmpty` is true when it sets none.

### Examples

The test fixtures `HephaestusV3Kit/Tests/ProjectDataTests/Fixtures/project-*.yml` are four examples. The
complete one (`project-complete.yml`), which V3 writes back byte for byte:

```yaml
schema: 1
id: HEPH
name: Hephaestus Tools
created: 2026-10-31T12:00:00Z
type: swiftApplication
color: '#34C759'
icon: hammer
nextTicketNumber: 15
nextBundleNumber: 3
docsPath: docs
githubPage: https://github.com/example/hephaestus
useParentSettings: true
subprojects:
- backend
- apps/ios
webTabs:
- id: 0F8E2A3B-5C4D-4E6F-8A7B-9C0D1E2F3A4B
  title: example/hephaestus
  url: https://github.com/example/hephaestus
  locked: true
  originalURL: https://github.com/example/hephaestus
  githubTab: page
skills:
- release-notes
chatDefaults:
  model: opus
  effort: high
  permissionMode: manual
  ultracode: false
  contextWindow: auto
environments: []
environmentOverrides: {}
deletedChats: []
commentAnswers: []
```

(Shortened here: the fixture has four web tabs, four Dashboard widgets, a deleted chat and a comment answer.)
A minimal file, every other key taking its default; V3 writes it back with its known keys and none of the
kept ones:

```yaml
schema: 1
id: WEB
name: Website
created: 2026-10-31T09:30:00Z
```

```yaml
schema: 1
id: WEB
name: Website
created: 2026-10-31T09:30:00Z
type: none
nextTicketNumber: 1
nextBundleNumber: 1
docsPath: docs
subprojects: []
environments: []
environmentOverrides: {}
```

A Go service with two environments (`project-service.yml`), and a sub project of it that changes the
inherited `local` and `staging` and adds `replay` (`project-subproject.yml`); its `useParentSettings`, V2's, is
kept and has no effect:

```yaml
schema: 1
id: WRK
name: Orders worker
created: 2026-10-31T11:00:00Z
type: goService
useParentSettings: true
environments:
- name: replay
  url: http://127.0.0.1
  port: 9090
  allowInvalidCertificates: false
  namespace: null
  deployment: null
  jaeger: null
  argoCDApplication: null
  kubeconfig: null
environmentOverrides:
  local:
    url: null
    port: 8081
    allowInvalidCertificates: null
    deployment: null
    jaeger: null
    argoCDApplication: null
  staging:
    url: https://worker.staging.example.com
    port: null
    allowInvalidCertificates: false
    deployment: orders-worker
    jaeger: null
    argoCDApplication: argocd/orders-worker-staging
```

## Registry file

`<data folder>/registry.yml`: the top-level projects of this Mac. Sub projects aren't listed: their parent's
`subprojects` lists them. Swift type `RegistryFile`.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | |
| projects | `projects` | `[String]` | no | `[]` | Absolute paths of the projects' folders ([Paths](#paths)), in the order they were added, each once. An entry that isn't an absolute path is skipped when loading (`loadableEntries`). |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

```yaml
schema: 1
projects:
- /Users/example/Developer/Tools
- /Users/example/Developer/Website
```

## Current environments file

`<data folder>/current-environments.yml`: the environment the user works in, chosen for each service, kept
out of `project.yml` so that choosing one changes no committed file. The file doesn't exist before the first
choice. Swift type `CurrentEnvironmentsFile`.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | |
| projects | `projects` | `[String: String]` | no | `{}` | The chosen environment's name, by project identifier, written in Unicode code point order of the identifiers. A project without an entry, or whose entry names none of its environments, works in its first environment. |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

```yaml
schema: 1
projects:
  DEMO: staging
  DEMOAPI: local
```

## Loading

When the app starts (`ProjectSession.start`, [Architecture › ProjectData](architecture.md#projectdata)):

1. The data folder is created when missing, and its lock taken.
2. `registry.yml` is read; a missing one is created empty, an invalid one set aside as `registry.yml.invalid`
   and recreated empty. `current-environments.yml` is read; a missing one gives no choice, an invalid one is
   set aside and gives no choice.
3. The projects load: the registry's entries in order, each followed by its sub projects, depth first, in
   `subprojects` order. Temporary files a crash left in a `.hephaestus/` folder are deleted. An entry is
   skipped, and reported with its reason (`ProjectIssue`), when:

   | Reason | When |
   | --- | --- |
   | `invalidEntry` | A registry entry isn't an absolute path, or a `subprojects` entry isn't a relative path. |
   | `folderMissing` | The folder doesn't exist. |
   | `fileMissing` | The folder has no `.hephaestus/project.yml`. |
   | `invalidFile(reason:)` | The project file breaks a read rule ([Validation](#validation)). |
   | `identifierInUse(identifier:by:)` | A project loaded before it has its identifier. It loads once that project is removed. |

   The entry stays where it is: the project loads as soon as its folder and file are fine. A folder reached
   twice (through a symbolic link) loads once.
4. The files are watched ([Outside changes](#outside-changes)).
5. Then, without holding the windows: the login shell's environment is captured, the tools are looked up,
   and the `origin` of each loaded folder is read ([GitHub page](#github-page)).

Invalid project files are never renamed or rewritten at load: they belong to the project's repository.

## Changes

Every change goes through `ProjectLibrary`, one at a time, and gives a new snapshot. Files are written with
[Atomic writes](#atomic-writes), a referenced file before the file that refers to it.

| Change | Rules | Order of the writes |
| --- | --- | --- |
| **Create** (`NewProject`) | Name: one line, 1–100 characters, trimmed. Identifier: uppercased, 2–8 letters A–Z, used by no loaded project. With a parent: the folder is strictly inside the parent's folder (`Choose a folder inside “<parent name>”.`), checked before anything is written. The folder is created when missing and `createsFolder` is set; otherwise it must exist. A folder that already holds a project is refused: open it instead. The new file has `created` = now, the name, the identifier and the type; every other key takes its default. | 1. the project file and `.gitignore` 2. the parent's `subprojects` (the given parent, else the innermost loaded project whose folder holds it), or the registry |
| **Open** (a folder) | A folder already loaded gives its project. Otherwise it must hold a valid project file whose identifier no loaded project uses. Registry entries that its file lists as its descendants, at any depth, leave the registry: they load under it. | 1. `.gitignore` 2. the innermost loaded project's `subprojects`, or the registry |
| **Update** (`ProjectChange`) | Only the values the change sets: name; type; color (a tint, or `#RRGGBB` uppercased, or none); icon (trimmed, none when empty); docs folder (a relative path, not `.hephaestus` or inside it); GitHub page (validated, none when empty); graph (on, off or none, which takes the parent's); the whole list of the project's own environments; all its changes to inherited environments; the whole list of Dashboard widgets ([Dashboard widget](#dashboard-widget) › Write rules); the Dashboard's time window. An environment or a change equal to a stored one is written back as it is, even when a hand edit made it break a rule (each stored environment keeps at most one equal environment: a copy is checked); any other is checked ([Validation](#validation)), its names trimmed, a change that sets nothing dropped. An own environment can't take a name another environment has, inherited ones included. | the project file, then `current-environments.yml` when a choice follows a rename or is forgotten |
| **Remove** | The project and its loaded sub projects leave the app: its entry leaves the parent's `subprojects` or the registry, and their chosen environments are forgotten. No file of theirs changes. | 1. the parent's project file, or the registry 2. `current-environments.yml` |
| **Choose the current environment** | One of the project's environments as they apply. | `current-environments.yml` |

## Resolution

What a project's settings are once inheritance applies (`ResolvedSettings`). A sub project takes every value
it leaves empty from its parent, field by field, whatever the two projects' types; a value it sets replaces
the parent's. V2's `useParentSettings` switch has no effect. The type only decides which tools a project has
([Architecture › Project](architecture.md#toolsfoundation)).

- **Environments.** A sub project first has its parent's environments, as the parent resolves them (so also
  those the parent inherits), each with the sub project's change of its name applied: every value the change
  sets replaces the parent's; the name stays the parent's. Then come its own environments, in order, except
  those whose name an inherited environment has: they stay in the file, left out. A change for a name no
  inherited environment has is kept and ignored. A top-level project has only its own.
  `inheritedEnvironments` are the parent's, without the changes.
- **Current environment.** The environment chosen in `current-environments.yml` while the project has it;
  otherwise the first; none without environments. After a change, a chosen environment that the change
  renamed (an environment of the list whose name changed at the same place, the list keeping its length)
  stays chosen under its new name, in the project and in the sub projects that inherit it; one a project no
  longer has is forgotten, so that a later environment of that name doesn't become current again. A rename
  made in `project.yml` outside the app counts as a removal.
- **GitHub page.** The typed `githubPage`; otherwise `defaultGithubPage`, the page an empty field gives and
  its greyed placeholder: the typed page of the nearest ancestor that has one; otherwise the page of the
  `origin` remote ([GitHub page](#github-page)) of the project, else of its nearest ancestor that has one.
  The origin is read with `git config --get remote.origin.url` in the project's folder, and for an SSH host
  alias with `ssh -G <alias>`. Until the origins are read, and without git, there is no origin page; without
  ssh, an alias stays unresolved.
- **Graph.** The project's `graphEnabled`; otherwise its parent's, as the parent resolves it
  (`inheritedGraphEnabled`, false for a top-level project).

## Tickets and bundles

A project's tickets and bundles live in its `.hephaestus/` folder, one YAML file each, committed with the
project. `TicketData` reads and writes them ([Architecture › TicketData](architecture.md#ticketdata)): the
`TicketLibrary` actor applies every rule below, for the windows and for Claude alike.

### Ticket file

`.hephaestus/ticket/<TICKET-ID>.yml`, Swift type `TicketFile`. Keys in this order:

| Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- |
| `schema` | `Int` | no | `1` | [Keys and values](#keys-and-values). |
| `id` | ticket id | yes | — | Equals the file name without `.yml`; its identifier part is the project's `id`. A file whose `id` differs is invalid. |
| `title` | `String` | yes | — | One line, 1–200 characters once trimmed. |
| `status` | `TicketFileStatus` | no | `todo` | `draft`, `todo`, `in_progress`, `review`, `done` ([Ticket rules](#ticket-rules)). |
| `created` | date | yes | — | Never changed. |
| `updated` | date | no | `created` | Set to now by every write of the file by V3. |
| `createdBy` | `user` or `claude` | no | `user` | Who created the ticket. |
| `description` | `String` | no | `""` | Markdown, line breaks LF. |
| `attachments` | `[AttachmentEntry]` | no | `[]` | The ticket's own files, in the order added ([Attachments](#attachments)). |
| `comments` | `[CommentEntry]` | no | `[]` | Oldest first; ids unique within the ticket. |
| `chats` | `[String]` | no | `[]` | The chats linked to the ticket, uppercase UUIDs; kept as read. |
| `links` | `[TicketLinkEntry]` | no | `[]` | The links this ticket declares, in the order given ([Link rules](#link-rules)). |
| `history` | `[HistoryEntry]` | no | one creation entry | Oldest first, only appended to. A file without history reads with one `created` entry made from `created` and `createdBy`, `to: todo`, without device or chat. |
| `priority` | `low`, `medium`, `high`, `urgent` | no | none | Written after `history` only when set. |
| `labels` | `[String]` | no | `[]` | Written after `history` (and `priority`) only when not empty; trimmed, empty ones dropped, each once. |

The runtime-only keys `inverseLinks` (on a ticket) and `answer` (on a comment) are ignored when read and never
written. Every other unknown key is kept ([Unknown keys](#unknown-keys)).

**Comment** (`CommentEntry`): `id` (UUID, required), `author` (`user` or `claude`, required), `created` (date,
required), `updated` (date or `null`, when the text was last edited), `text` (Markdown, default `""`),
`attachments` (`[AttachmentEntry]`), `model` and `effort` (strings or `null`, kept as read). A comment has text
that isn't empty once trimmed, at least one attachment, or both.

**Ticket link** (`TicketLinkEntry`): `kind` (`dependsOn` or `related`) and `ticket` (a ticket id of the same
project). The other ticket shows the inverse, computed at each snapshot and never written:
`blocks` for `dependsOn`, `related` for `related` (`LoadedTicket.inverseLinks`, in ascending number of the
declaring ticket).

**History entry** (`HistoryEntry`):

| Key | Rules |
| --- | --- |
| `kind` | `created`, `status`, `title`, `linkAdded`, `linkRemoved`, `description`. |
| `date` | When the change was made. |
| `from` | The previous status (`status`) or title (`title`); required for those two, `null` for the others. |
| `to` | The new status (`created`: the status it was created with), the new title, or the link as `<kind> <ticket id>`; not written for `description`. |
| `author` | `user`, `claude` or `automatic`; V3 writes `user` and `claude` only. |
| `device` | For `user`: the Mac's computer name at the time (`TicketSession.computerName()`). |
| `chat` | For `claude`: the chat's id, or `external` for a terminal session. |

A file breaking these rules (a `status` entry without two statuses, a link entry not shaped `<kind> <id>`) is
invalid.

### Bundle file

`.hephaestus/bundle/<BUNDLE-ID>.yml`, Swift type `BundleFile`: `schema`, `id` (bundle id, equal to the file
name), `title` (one line, 1–200 characters), `status` (`todo`, `in_progress` or `done`; default `todo`),
`created`, `updated` (default `created`), `tickets` (ticket ids of the project, in implementation order, each
once; default `[]`), `chats` (kept as read; default `[]`), then unknown keys. A ticket may belong to several
bundles.

### Attachments

- Ticket and comment files are stored at `.hephaestus/attachments/<TICKET-ID>/<attachment id>-<name>`;
  `path` is relative to `.hephaestus/`. `AttachmentEntry`: `id` (uppercase UUID), `name`, `path`,
  `contentType` (default `application/octet-stream`), `size` (bytes, default `0`).
- Adding a file copies it under a new id; the original stays. It must be a readable regular file of at most
  20 MiB (`<name> is larger than 20 MB.`), and the files of one change at most 20 MiB together (`The
  attachments of one request exceed 20 MB.`); otherwise `<path> is not a readable file.`
- `name` is the file's name with `/`, `:` and control characters (U+0000–U+001F, U+007F) replaced by `_`, `file`
  when empty, and the part before the extension shortened by whole characters until `<id>-<name>` fits in 213
  UTF-8 bytes, so that the atomic write's temporary name stays within 255 (`TicketRules.attachmentName`).
- `contentType` is the MIME type of the name's extension (`UTType(filenameExtension:)?.preferredMIMEType`),
  else `application/octet-stream`. Images, shown as thumbnails: `image/png`, `jpeg`, `gif`, `heic`, `heif`,
  `tiff`, `bmp`, `webp`.
- A file is written once and never changed. Removing a ticket attachment, or deleting a comment, moves its
  files to the Trash; deleting a ticket moves its whole `attachments/<TICKET-ID>/` folder. A comment's file goes
  only with its comment.
- V3 opens an attachment only when its `path` is `attachments/<TICKET-ID>/<one component>` and its real path,
  symbolic links resolved, lies inside the project's `.hephaestus/` (`The path is outside the attachments
  folder.`, else `Attachment file <path> not found.`): a ticket file can't point outside the project.

### Ticket rules

**Ids.** A ticket's number comes from the project file's `nextTicketNumber`, a bundle's from
`nextBundleNumber` (`ProjectLibrary.allocateNumber`): the counter's value, at least 1, raised past any
`ticket/<ID>-<n>.yml` (or `bundle/<ID>-B<n>.yml`) that already exists, then the counter is written as the
next number, before the ticket or bundle file. A number is never reused, even when the creation fails after.

**Titles.** Trimmed, 1–200 characters on one line, else `Title must be 1 to 200 characters on one line.` A
title equal to the stored one changes nothing. A ticket created without a title takes its provisional
title: the description's first line that isn't empty and isn't a heading (a line starting with `#`), trimmed,
cut to 60 characters and trimmed again; `Untitled Ticket` without one.
Without a title the description must not be empty (`The description must not be empty.`). A bundle created
without a title takes its tickets' titles joined with `, `, cut to 60 characters and trimmed. The
provisional title stays until the user or Claude changes it.

**Descriptions.** Free Markdown, from the user and from Claude alike, with no template ([Decisions › What
Claude reads](decisions.md#what-claude-reads)).

**Status.** Statuses in order: Draft, To Do, In Progress, In Review, Done. A ticket starts
To Do, or as a draft when the user creates it so; Claude's start To Do. The user may set any status at any
time. Claude may set To Do, In Progress, In Review and Done, but never changes a done ticket (`<ID> is done;
only the user can change its status.`), never changes a draft (`<ID> is a draft; only the user can change its
status.`) and never makes one (`Only the user can make <ID> a draft.`). Setting the current status again
writes nothing and adds no entry.

**Bundle status.** The user may set any status. Claude may set To Do and In Progress, never Done (`Only the
user can set <ID> to done.`), and never changes a done bundle (`<ID> is done; only the user can change its
status.`). Two automatic rules keep a bundle in step with its tickets, whoever makes the change:

- *Complete*: a bundle listing at least one ticket, all done, becomes `done`. A listed id without a ticket,
  or whose file never loaded, isn't done.
- *Reopened*: a `done` bundle listing a ticket that isn't done becomes `in_progress`.
- A bundle without tickets keeps its status.

They apply when a listed ticket changes status (in V3 or outside), and when the bundle's set of tickets
changes (a creation, a change of its list other than a reorder, a deletion of a listed ticket, its file added
or changed outside); at each load of a project, the Complete rule alone applies to every bundle.

### Link rules

A change gives the whole list of the links a ticket declares. Each link the ticket doesn't already declare
with the same kind is checked, in the list's order, with these rules in order; the first broken one fails the
change. A link it already declares is kept as it is, even when its ticket is missing.

1. The id has the ticket format: `"<value>" is not a valid ticket id.`
2. It belongs to the same project: `<other ID> does not belong to project <IDENT>.`
3. It isn't the ticket itself: `<ID> cannot be linked to itself.`
4. The list names it once: `<other ID> is listed more than once.`
5. The ticket exists: `Ticket <other ID> not found.`
6. One link per pair: the other ticket declares no link to this one: `<ID> is already linked to <other ID>.`
7. A Depends on link makes no cycle: `<ID> cannot depend on <other ID>, which depends on <ID>.`

Ids are accepted in any letter case and stored in uppercase. At creation the ticket has no id yet, so rules
3, 6 and 7 can't fail.

### Ticket changes

Each change is made by an actor (`TicketActor`): the user on this Mac (`.user(device:)`) or Claude
(`.claude(chat:)`). Every change runs on the `TicketLibrary` actor, one at a time, writes with [Atomic
writes](#atomic-writes) and returns a new snapshot.

| Change | Rules | Order of the writes |
| --- | --- | --- |
| **Create a ticket** (`NewTicket`) | The project is loaded (`Project <ID> not found.`). Title, description, status (`todo` or `draft`: `A new ticket is To Do or a draft.`), files and links are checked before a number is taken. `created` and `updated` now, `createdBy` the actor, the history one `created` entry. | 1. project file (counter) 2. attachment files 3. ticket file; when 2 or 3 fails, the copied files are removed |
| **Change a ticket** (`TicketChange`) | Title, description, priority, labels, the whole list of links. History entries in this order: rename, description edit, one `linkRemoved` per link no longer declared (in the old order), one `linkAdded` per new link (in the given order); a link whose kind changes is removed, then added. Priority and labels add no entry. A change that changes nothing writes nothing. | ticket file |
| **Set a ticket's status** | [Ticket rules › Status](#ticket-rules); one `status` entry. | 1. ticket file 2. each bundle file the automatic rules change, in bundle number order |
| **Delete tickets** | Their ids leave every bundle (the automatic rules apply in the same write), and every link to them leaves the other tickets of the project, with no history entry. | 1. each bundle file listing them 2. each ticket file linking to them 3. the ticket files and their `attachments/<ID>/` folders, moved to the Trash |
| **Add a comment** | Text or files; the comment's author is the actor. | 1. attachment files 2. ticket file |
| **Edit a comment** | Its text, with the same rule; sets the comment's `updated`. Its files can't change. Anyone may edit any comment. | ticket file |
| **Delete a comment** | `Comment <id> not found.` for an unknown one. | 1. ticket file 2. its files, moved to the Trash |
| **Add attachments** | To the ticket's own files. | 1. attachment files 2. ticket file |
| **Remove an attachment** | A ticket attachment only (`Attachment <id> not found.`). | 1. ticket file 2. the file, moved to the Trash |
| **Create a bundle** | At least one ticket (`A bundle needs at least one ticket.`), each of the project (`<ID> does not belong to project <IDENT>.`), existing (`Ticket <ID> not found.`), once (`<ID> is listed more than once.`). Starts `done` when they all are. | 1. project file (counter) 2. bundle file |
| **Change a bundle** | Title; the whole list of tickets, which may be empty, where an id the bundle already lists may name a missing ticket. | bundle file |
| **Set a bundle's status** | [Ticket rules › Bundle status](#ticket-rules). | bundle file |
| **Delete a bundle** | Its tickets stay. | the bundle file, moved to the Trash |

A ticket or bundle id that isn't well formed fails with `"<value>" is not a valid ticket id.` (or `bundle
id`); an unknown one with `Ticket <ID> not found.` (or `Bundle <ID> not found.`). A file that can't be moved to
the Trash fails with `<path> cannot be moved to the Trash: <reason>.`; the writes made before stay.

### Ticket loading and outside changes

- `TicketSession.start`, once the projects are ready, loads the tickets and bundles of every loaded project;
  a project loaded later (created, added, its folder back) loads then, and a removed one is dropped. Each load
  deletes the temporary files a crash left in `ticket/` and `bundle/`, then applies the Complete rule.
- A file that can't be read, or whose `id` differs from its name, is listed in the snapshot's `invalidFiles`
  with its reason; a ticket or bundle loaded before keeps its last valid version, which the next change V3
  makes writes over it.
- After each batch of file events ([Outside changes](#outside-changes)), each ticket and bundle file the batch
  names is read again (the whole project when events were dropped): a missing file is a deletion, a file
  equal to the one in memory changes nothing. Then the automatic rules apply to each bundle that lists a ticket
  whose status changed (or that appeared or went), and to each bundle whose set of tickets changed, in bundle
  number order. A status changed outside V3 adds no history entry.

## Chats

A chat is one Claude Code session, run by the Claude CLI in the project's folder ([UI › Chat](ui/chat.md)). Its
files are the metadata file and the transcript, in the project's `.hephaestus/chats/`, which
`.hephaestus/.gitignore` keeps out of git (the first chat of a project adds the line `chats/` when it is
missing). V3 reads chats of every kind ([Chat kinds](#chat-kinds)). `<CHAT-ID>` is an uppercase UUID, also the
CLI's session id. Names in `chats/` that aren't `<CHAT-ID>.yml` or `<CHAT-ID>.jsonl` are ignored: per-chat
folders (attachments, agents) stay as they are.

### Chat file

`.hephaestus/chats/<CHAT-ID>.yml`, Swift type `ChatFile`, keys in this order:

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | |
| id | `id` | `String` | yes | — | An uppercase UUID (`ChatIDs.isChatID`), equal to the file's name. |
| title | `title` | `String` | no | `New Chat` | One line. V3 titles a new chat with the first line of its first message that isn't empty, at most 80 characters; a rename takes 1 to 100 characters on one line. |
| kind | `kind` | `ChatFile.Kind` | yes | — | `project`, `ticket`, `bundle`, `feedback`, `ci` or `setup` ([Chat kinds](#chat-kinds)). V3 makes `project` chats only. |
| ticketID | `ticket` | `String?` | no | `null` | Always written, `null` when absent. |
| bundleID | `bundle` | `String?` | no | `null` | Always written, `null` when absent. |
| orchestratorChatID | `orchestrator` | `String?` | no | absent | A `ticket` or `ci` chat's orchestrator, kept as read ([Chat kinds](#chat-kinds)). Written only when set. |
| imageID | `image` | `String?` | no | absent | A `setup` chat's image, kept as read ([Chat kinds](#chat-kinds)). Written only when set. |
| created | `created` | `Date` | yes | — | Never changed. |
| updated | `updated` | `Date` | no | `created` | Set by a message sent, a turn's end, a rename, a settings change. The Chat window lists chats by it, the latest first. |
| settings | `settings` | `ChatSettings` | no | defaults | [Chat settings](#chat-settings). |
| sessionStarted | `sessionStarted` | `Bool` | no | `false` | True once the CLI has started the session (its first `system/init`): later launches resume it. |
| closed | `closed` | `Bool` | no | `false` | Whether the chat is closed. A message sent sets it back to `false`. |
| questionsBlocked | `questionsBlocked` | `Bool` | no | `false` | `ticket` chats only, kept as read ([Chat kinds](#chat-kinds)). Written only when `true`. |
| origin | `origin` | `String?` | no | absent | The tool whose chat panel started the chat, a `ToolKind` value such as `tickets`; absent for a chat of the Chat window. Written only when set. |
| unknownKeys | — | `YAMLMapping` | — | empty | Kept and written after the known keys, `contextUsage` among them ([Unknown keys](#unknown-keys)). The runtime keys `projectID`, `state`, `backgroundWork`, `compactingSince`, `costUSD` and `mentionedIDs` are ignored when read and never written. |

A chat file is written back byte for byte. Example, a chat started from the Tickets window's panel:

```yaml
schema: 1
id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
title: Why did the checkout fail?
kind: project
ticket: null
bundle: null
created: 2026-11-14T10:00:00Z
updated: 2026-11-14T10:00:41Z
settings:
  model: default
  effort: high
  permissionMode: manual
  ultracode: false
  contextWindow: auto
sessionStarted: true
closed: false
origin: tickets
```

### Chat kinds

A file that breaks these rules is invalid and isn't listed:

| Kind | `ticket` | `bundle` | Other |
| --- | --- | --- | --- |
| `project` | `null` | `null` | |
| `ticket` | required | `null` | may have an `orchestrator` |
| `bundle` | `null` | required | |
| `feedback` | `null`, or the first ticket it made | `null` | |
| `ci` | exactly one of `ticket` and `bundle` | | `orchestrator` required |
| `setup` | `null` | `null` | `image` required |

Only `ticket` and `ci` chats have an `orchestrator`, only `setup` chats an `image`, only `ticket` chats
`questionsBlocked`.

### Chat settings

Swift type `ChatSettings`, keys in this order: `model` (`String`, default `default`: a CLI model value, not
empty, no white space), `effort` (`low`, `medium`, `high`, `xhigh` or `max`, default `high`), then
`permissionMode` (default `manual`), `ultracode` (default `false`) and `contextWindow` (default `auto`), kept as
read and not used by V3, then unknown keys. A new chat takes the model and effort of [Settings
file](#settings-file) › `chatModel` and `chatEffort`.

### Chat transcript file

`.hephaestus/chats/<CHAT-ID>.jsonl`: JSON Lines, one `{"op": "add" | "update", "item": <ChatItem>}` per line,
appended and never rewritten.

- **Writes.** Each item added or replaced appends one line: compact JSON, keys sorted, slashes not escaped, then
  LF, in one `write(2)` with `O_APPEND`, the file created mode 0644 by the first. The first append to a
  transcript since the app started adds an LF first when the file doesn't end with one, so a line a crash cut
  short stays apart. Streamed text is never written; only finished items are.
- **Replay.** Lines in order: `add` appends the item, or replaces the one with its `id` in place; `update`
  replaces it, or appends it. A line that isn't JSON, has another `op`, an item type V3 doesn't read or lacks a
  required key is skipped.
- **Reading.** A transcript is read when its chat opens in a window, off the main thread; the app keeps at most
  12 in memory besides those of running chats, the oldest read dropped first. A request still waiting in a
  transcript read while the chat has no process is cancelled: an `update` line with `decision` `deny` and
  `decidedBy` `null`.

### Chat items

Every item has `type`, `id` (unique in the transcript) and `created` (ISO 8601, UTC, seconds). The other keys,
with `null` written for an absent optional:

| `type` | Keys | Id |
| --- | --- | --- |
| `user` | `text` (the message as written, without what V3 adds for Claude), `attachments` (kept as read), `sender` (the Mac's name), `linkedItems` (kept as read), `references` (`[{tool, project, focus, title, environment}]`, the item the message's chip carried; `tool` is a `ToolKind` value or `project`) | a new uppercase UUID, also the message's `uuid` for the CLI |
| `assistant` | `text`, `messageID`, `parentToolUseID`, `model` (the CLI's model id), `effort` | `<message id>#<block index>` |
| `thinking` | `text`, `parentToolUseID` (kept; not shown) | `<message id>#<block index>` |
| `toolUse` | `toolUseID`, `name` (without `mcp__<server>__`), `server` (`hephaestus` for the app's tools, `null` for the CLI's), `input`, `parentToolUseID` | `<message id>#<block index>` |
| `toolResult` | `toolUseID`, `text`, `isError`, `images` (kept as read) | `<tool use id>#result` |
| `permissionRequest` | `requestID`, `toolName` (the CLI's name, `mcp__hephaestus__add_comment`), `input`, `reason`, `decision` (`allow`, `allowAlways`, `deny`; `null` while it waits), `decidedBy` (the Mac whose user answered; `null` while it waits and when the app cancelled it) | `perm-<request id>` |
| `system` | `text` (in English), `level` (`info`, `warning`, `error`) | a new uppercase UUID |
| `result` | `durationMs`, `costUSD` (kept; not shown), `isError`, `summary` | a new uppercase UUID |

The items `questions`, `symbol`, `color`, `sound`, `shortcut`, `font`, `animation` and `images` are skipped
when a transcript is read, and stay in the file. A string
longer than 100,000 characters in a call's input or a result's text is cut, followed by `… [truncated <n>
characters]`.

The `system` lines V3 writes:

| When | Level | Text |
| --- | --- | --- |
| The CLI can't be started | error | `Claude failed to start: <reason>` |
| No `system/init` within 60 s | error | `Claude did not start within 60 seconds.` |
| The CLI exits during a turn, not ended by the app | error | `Claude exited with code <n>: <last line of its standard error>`, or `Claude exited with code <n>.`, or `Claude was terminated by signal <n>.` |
| The first `system/init` lists no usable `hephaestus` server | warning | `The Hephaestus tools aren't available in this session: the app's MCP server is <failed, needs-auth, disabled or missing>.` |
| A resumed session the CLI doesn't find | warning | `Claude's session for this chat was not found. A new session started: Claude doesn't remember this chat's earlier messages.` |
| The CLI refuses a model or effort change | warning | `Claude did not accept the new <model or effort> now: <reason>. It applies the next time Claude starts.` |
| Stop | info | `Stopped by the user.` |
| The app quits during a turn | warning | `Stopped because Hephaestus quit.` |
| A compaction | info | `Conversation compacted (<automatic or manual>, <tokens> tokens before)`, tokens as `24.6K`, `967K`, `1.2M` |

### Stream mapping

`StreamMapper` turns each line the CLI writes (stream-json, checked against captures of Claude Code
2.1.309 in `ChatDataTests/Fixtures`) into items and events. A line that isn't a JSON object is
skipped.

| Line | Result |
| --- | --- |
| `system` `init` | A CLI turn opens. The first of a process sets `sessionStarted` and checks `mcp_servers` for `hephaestus`. |
| `system` `status` | `compacting` starts a compaction; the next `status` ends it. |
| `system` `compact_boundary` | The compaction line, from `compact_metadata.trigger` and `pre_tokens`. |
| `stream_event` | `message_start` records the message's id and model; `content_block_start` opens block `index`; a `text_delta` (main conversation) streams text into the chat; `thinking_delta` accumulates. Others are ignored. A line's message is its `api_message_id`, else the latest `message_start` of its `parent_tool_use_id`. |
| `assistant` | One item per block of `message.content`: `text` → `assistant` (none when empty), `thinking` → `thinking` (none when empty), `tool_use` → `toolUse`. A block takes the index of the first open block of its message with its type and no item yet, else the next index of the message. |
| `user` with `tool_result` blocks | One `toolResult` each: `content` as a string, or its `text` parts joined with LF, then one line of compact JSON per part that is neither text nor image. |
| `control_request` `can_use_tool` | A `permissionRequest` item: the CLI asks ([Chat processes › Permissions](#permissions)). Another subtype is refused at once: `Unsupported control request: <subtype>`. |
| `control_response` | Matched to the app's request by `request_id`. |
| `control_cancel_request` | The request is cancelled: `decision` `deny`, `decidedBy` `null`. |
| `result` | Open text and thinking blocks with text become items, open calls are dropped; then a `result` item: `durationMs` = `duration_ms`, `costUSD` = `total_cost_usd`, `isError` = `is_error`, `summary` null without error, else `Stopped by the user.` for the first result after Stop, else `result` for subtype `success`, else the `errors` joined with LF, else the `subtype`. The CLI turn closes. |
| `command_lifecycle` | The state of the message whose `uuid` is `command_uuid`. |
| Others (`rate_limit_event`, `keep_alive`…) | Ignored. |

### Chat processes

How a chat's CLI runs (`ChatSession`, [Architecture › ChatData](architecture.md#chatdata)).

#### The CLI

The first that applies: Settings ▸ Chat's path (`claudePath`); `HEPHAESTUS_CLAUDE_PATH`; `~/.local/bin/claude`,
`/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, the first that is an executable file; `claude` in the login
shell's `PATH`. A path set in Settings or the variable that isn't an executable file is an error, and nothing
else is tried. Then `<path> --version` (30 s): the version is its output's first `[0-9]+(\.[0-9]+)+`.

| Outcome | Status |
| --- | --- |
| Not found | `Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat.` |
| Set but not executable | `<path> is not an executable file.` |
| `--version` fails | `<path> --version failed: <reason>.`: `timeout`, the first line of its standard error without final periods, or `exit code <n>` |
| A version | Available. |

The check runs once the projects and tools are loaded, and again after the path changes or **Look Again**. Then
the model probe reads the CLI's models: `<path> -p --input-format stream-json --output-format stream-json
--verbose --no-session-persistence --tools "" --strict-mcp-config --mcp-config {"mcpServers":{}}` in
`Runtime/claude-cwd/`, writes `initialize`, takes `response.models` from its answer (30 s at most), closes stdin,
then SIGTERM and SIGKILL 2 s later. No message is sent: the probe makes no model request. Each model entry gives
`value`, `displayName` (default `value`), `description`, `supportedEffortLevels`, `resolvedModel`; an entry without
`value` is skipped. Until an answer, the list is the fallback: Default, Opus, Fable, Sonnet, Haiku. Every chat
process's `initialize` answer replaces the list too. A model id's name is the `displayName` of the first model
other than `default` that resolves to it, else of the model whose value it is, else the id.

#### Launch

A message to a chat without a live process starts one, in the project's folder, with the login shell's
environment (no `HEPHAESTUS_*`) plus `MCP_TOOL_TIMEOUT=1800000`, its standard error appended to the chat's log.
The arguments, one element each, no shell:

```
<cli> -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
  --session-id <CHAT-ID>          (or --resume <CHAT-ID> once sessionStarted)
  --model <settings.model> --effort <settings.effort>
  --permission-mode manual --permission-prompt-tool stdio
  --tools ""
  --strict-mcp-config --mcp-config <data folder>/Runtime/mcp/<CHAT-ID>.json
  --allowedTools mcp__hephaestus__<tool>,mcp__hephaestus__<tool>,…
```

- `--tools ""` leaves Claude none of the CLI's own tools (shell, files, web, agents); `--strict-mcp-config`
  leaves it the app's server alone. Claude reads and changes only through the app's tools, as the user does.
- `--allowedTools` lists every tool of the app's server: the CLI runs them without asking, and the app's server
  asks the user before a change, as Settings ▸ Chat says ([MCP › Permissions](mcp.md#permissions)).
- No system prompt, no hook, no skill, no plugin: V3 sends Claude nothing written for it besides its tools'
  descriptions and the line of a message's item ([Decisions › What Claude reads](decisions.md#what-claude-reads)).
- The MCP configuration, mode 0600: `{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <token>"}}}}`, the token a new chat token
  ([MCP › Authentication](mcp.md#authentication)), revoked with the file when the process ends.

Then the app writes `{"type":"control_request","request_id":"hephaestus-1","request":{"subtype":"initialize"}}`
and the message. Control request ids are `hephaestus-<n>`, counting from 1 per process.

#### Messages

Each message is one line: `{"type":"user","message":{"role":"user","content":[{"type":"text","text":<text>}]},"uuid":<user item id>}`.
`<text>` is the message, then, for the item its chip carried, a blank line and one line V3 writes:

| Item | Line |
| --- | --- |
| The project | `Attached: project ORD` |
| A ticket | `Attached: ticket ORD-142 of project ORD` |
| A service, a request | `Attached: service payments-api of project ORD, as seen in Staging`; `Attached: request req-8f3a of project ORD, as seen in Staging` |
| A run, a release | `Attached: run 1288 of project ORD`; `Attached: release v1.4.0 of project ORD` |
| An operation | `Attached: operation createOrder of project ORD` |

#### Turns

A turn runs from a message written (or a CLI turn the CLI begins) until no message written is outstanding and
no CLI turn is open. Each message written is outstanding; `command_lifecycle` records its `state`, and a state
other than `queued` and `started` finishes it; a `result` closes the CLI turn and finishes the messages
`started`, or the oldest without a state. A message sent during a turn is written at once: the CLI runs it
after its current CLI turn. The turn's end writes `updated`.

| State | When |
| --- | --- |
| `starting` | A process was started; its first `system/init` hasn't come. |
| `running` | A turn runs. |
| `waitingPermission` | A card waits: the CLI's request, or the app's. |
| `error` | The CLI couldn't start, didn't start in 60 s, or exited during a turn on its own. Until the next message. |
| `idle` | Otherwise. |

#### Permissions

- **The app's cards.** Before a change by a chat's Claude that Settings ▸ Chat sets to Ask First, the server's
  gate calls `ChatSession.requestApproval`: a `permissionRequest` item with a new lowercase UUID as request id
  and `mcp__hephaestus__<tool>` as `toolName`; the call waits for the answer.
- **The CLI's requests.** A `can_use_tool` request (one the CLI makes on its own, such as for a tool the user's
  Claude Code settings deny) becomes a card too. Allow writes
  `{"type":"control_response","response":{"subtype":"success","request_id":<id>,"response":{"behavior":"allow","updatedInput":<input>}}}`;
  Don't Allow writes `"behavior":"deny","message":"Permission denied by the user."`.
- An answer records `decision` and `decidedBy`, this Mac's name.

#### Stop, end and quit

| Event | What happens |
| --- | --- |
| Stop | Each card waiting is refused (the CLI's with `The user stopped Claude.`), recorded with this Mac's name; the line `Stopped by the user.`; the `interrupt` control request. Without a `result` 5 s later, SIGINT, then SIGTERM, then SIGKILL, 5 s apart, to the process group. |
| No turn for 20 min | stdin closed, then SIGTERM and SIGKILL, 5 s apart. The next message starts a process with `--resume`. |
| No `system/init` in 60 s | SIGTERM, SIGKILL 5 s later; the error line. |
| The app quits | A turn in progress gets its line and its cards are cancelled; SIGTERM, SIGKILL after 3 s. |
| A resumed process exits before its `system/init`, its standard error saying `No conversation found with session ID` | `sessionStarted` false, the warning line, and one launch again with `--session-id`, writing the same messages. |
| Any exit | Open blocks finish as items; the cards still waiting are cancelled; the token and the MCP configuration go. |
| `set_model`, `apply_flag_settings` | A model or effort change of a chat whose process runs: `{"subtype":"set_model","model":<model>}`, `{"subtype":"apply_flag_settings","settings":{"effortLevel":<effort>}}`. |

### Chat loading and outside changes

`ChatSession.start`, once the projects and tools are loaded, reads the chat files of every loaded project (names
`<CHAT-ID>.yml` only; an invalid file, or one whose `id` differs from its name, is skipped), and again when the
projects change or a batch of file events names a `chats/` folder. Transcripts aren't followed: a transcript
changed outside the app shows when its chat is read again.

## Builds

Builds reads the workflow runs and releases of a project's GitHub repository with the GitHub CLI, `gh`, and keeps
nothing: no file holds a run or a release ([UI › Builds](ui/builds.md)).
The repository is the project's GitHub page as it resolves, `https://github.com/<owner>/<name>` (a sub project
on its parent's settings has its parent's); a project without one has no runs: `Project <ID> has no GitHub
page.`

### gh calls

`<repo>` is `github.com/<owner>/<name>`, so that a `GH_HOST` of the user's never sends a call elsewhere. Each
option and its value are one argument; a run's id and a tag come after `--`.

| Call | Command | Timeout |
| --- | --- | --- |
| Runs | `gh run list --repo=<repo> --limit=50 --json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,number,startedAt,status,updatedAt,workflowName` | 30 s |
| A run | `gh run view --repo=<repo> --json=<the same>,jobs -- <run id>` | 30 s |
| A job's log | `gh run view --repo=<repo> --log --job=<job id>` | 60 s |
| Re-run | `gh run rerun --repo=<repo> [--failed] -- <run id>` | 30 s |
| Cancel | `gh run cancel --repo=<repo> -- <run id>` | 30 s |
| Releases | `gh api repos/<owner>/<name>/releases?per_page=50`, then `gh release list --repo=<repo> --limit=50 --exclude-drafts --json=tagName,isLatest` for the latest | 30 s each |
| A file | `gh release download --repo=<repo> --pattern=<asset> --dir=<folder> -- <tag>` | 30 min |

- **gh** is the one the projects' tool lookup found in the login shell's `PATH` ([Loading](#loading)); it runs
  with the login shell's environment without `HEPHAESTUS_*`, `CLICOLOR_FORCE`, `GH_FORCE_TTY`, `GH_DEBUG` and
  `DEBUG`, plus `GH_PROMPT_DISABLED=1` and `GH_NO_UPDATE_NOTIFIER=1`, standard input empty; after its timeout,
  SIGTERM to its process group, then SIGKILL 2 s later.
- **Runs** are named by GitHub's id (`databaseId`); their `number` is the one GitHub shows (`#641`). A date gh
  writes as `0001-01-01T00:00:00Z` is none, and so is an empty conclusion. A completed run lasts from its start
  (`startedAt`, else `createdAt`) to `updatedAt`; another, to now. A job or step lasts from `startedAt` to
  `completedAt`, or to now.
- **Statuses**: `success` passed; `failure`, `timed_out`, `startup_failure` failed; `in_progress` running;
  `queued`, `requested`, `waiting`, `pending` queued; any other completed run cancelled.
- **Logs**: each line of gh's output is `<job>\t<step>\t<time> <text>`; the time is dropped and the lines are kept
  by step name. gh gives a job's log once the job has completed.
- **Releases**: GitHub's REST answer gives each release's `tag_name`, `name`, `body` (the notes), `draft`,
  `prerelease`, `created_at`, `published_at` and `assets` (`name`, `size`); drafts are left out; the release
  `gh release list` marks `isLatest` is the latest.

### Failures

| Case | Message |
| --- | --- |
| No GitHub page | `Project <ID> has no GitHub page.` |
| No gh | `Install the GitHub CLI (gh) to see runs and releases.` |
| gh exits with 4 (no login) | `Run gh auth login in Terminal to see runs and releases.` |
| gh fails otherwise | `gh <command> failed: <reason>.`, the reason `timeout`, the first line of its standard error without final periods, or `exit code <n>` |
| Output not as expected | `gh <command> returned unexpected output: <reason>.` |

### Downloads

A release file goes through a new folder of `<data folder>/Runtime/downloads/`, then moves into the Downloads
folder: `/` and `:` replaced by `_`, the name trimmed, and ` (1)`, ` (2)`… before the extension when the name is
taken. It gets the quarantine of a web download, with the file's URL
(`https://github.com/<owner>/<name>/releases/download/<tag>/<asset>`) and the release's page, so that
Gatekeeper checks it when it opens. The temporary folder is removed, also after a failure. `<asset>` in the
pattern has `\` before each `\`, `*`, `?` and `[`.

## Clusters

The Service Map and Claude's cluster tools read where a service runs: each environment's `kubeconfig`,
`namespace`, `deployment`, `argoCDApplication` and `jaeger` ([Project environment](#project-environment)),
with kubectl from the login shell's `PATH`. Nothing is stored: every read asks the cluster again.

### kubectl calls

Every command starts with `--kubeconfig=<file>` (`~/` expanded) and `--namespace=<namespace>`, each only when the
environment sets it, runs in the project's folder with the login shell's environment, and ends after 60 s (SIGTERM,
then SIGKILL). The Argo CD commands use the Application's namespace: `<namespace>` of `<namespace>/<name>`, else
`argocd`.

| Call | Command |
| --- | --- |
| Deployments | `get deployments -o json` |
| A Deployment's status | `get deployment/<deployment> -o json`, then `get pods --selector=<its matchLabels> -o json` |
| Logs | `logs <pod or deployment/<deployment>> --tail=<n> --timestamps` (`--all-containers` for the Deployment; `--container`, `--since=<n>s`, `--previous`) |
| Events | `get events -o json`, those whose object is the Deployment or named after it |
| Restart | `rollout restart deployment/<deployment>` |
| Scale | `scale deployment/<deployment> --replicas=<0–100>` |
| Argo CD status | `get applications.argoproj.io/<name> -o json`: `status.sync.status`, `status.health.status`, the revision, `status.operationState.phase` |
| Argo CD sync | `patch applications.argoproj.io/<name> --type=merge --patch={"operation":{"initiatedBy":{"username":"Hephaestus"},"sync":{"syncStrategy":{"hook":{}}}}}`, refused while an operation runs |
| Port forward | `port-forward <target> --address=127.0.0.1 <local>:<remote>`, waiting at most 30 s for `Forwarding from 127.0.0.1:<port> -> <remote>` |

Failures: `<command> exited with code <n>: <standard error>` (or `.` without it), `<command> did not finish
within 60 seconds.`, `Unexpected output from <command>.`, `kubectl was not found in the PATH of the login shell.`,
`Environment “<name>” has no deployment.`, `Environment “<name>” has no Argo CD application.` `<command>` is kubectl
and its arguments, an argument with other characters than letters, digits and `-_./:=,@+%` in single quotes.

**Port forwards.** Jaeger's forward is shared by the reads of every window, one per kubeconfig and Service, and
ends 60 s after its last use or when kubectl exits. The forwards Claude opens (`k8s_port_forward`) last until it
stops them or the app quits.

### Service map

The owner's rules:

- **Services**: each Deployment whose first container image of the form `ghcr.io/<owner>/<repository>:sha-<commit>`
  (7 to 40 hexadecimal digits) names a repository other than `yc-shared`. Its health: Down when no pod is ready,
  Degraded when some aren't, else Healthy.
- **Sources**: the service's `go.mod` and `deployment/values-prod.yml` at the deployed commit, with
  `gh api --header=Accept: application/vnd.github.raw repos/<owner>/<repository>/contents/<path>?ref=<commit>`; a
  file the commit hasn't (HTTP 404) is empty; the files read are kept until the app quits; a failed read gives
  `The sources of <deployment> cannot be read: <reason>.` and is tried again at the next read.
- **Databases**: a service has `<service>-postgres` when `postgres.enabled` of its values file is `true`, `yes` or
  `on` (any case), or its `go.mod` requires `…/yc-shared/gormpg` (or a major version). **Buckets**:
  `<service>-bucket`, an external node, from `s3.enabled` or `…/yc-shared/s3store`.
- **Arrows**: a service calls another when its `go.mod` requires the other's repository module, or one below it;
  it calls its database and its bucket. Services first, by name, then the databases and buckets.

### Jaeger

The environment's `jaeger`, `<namespace>/<name>` (without a namespace, the environment's), is reached on port
16686 through the shared port forward of `service/<name>`. The v3 API in OTLP JSON:
`GET /api/v3/traces?query.service_name=<service>&query.start_time_min=<start>&query.start_time_max=<end>&query.search_depth=10000`
for each service of the map (a full answer is read again in halves), and `GET /api/v3/traces/<id>` for one
request. A 404 gives no trace. Without Jaeger, or when it can't be reached, the map shows its nodes and grey
arrows, and `Jaeger cannot be reached: <reason>`.

### Calls and requests

Of the spans that started in the time window:

- A **client** span of a service is a call: `db.system.name` `postgresql` of its database, `rpc.system` `aws-api` with
  `rpc.service` `S3` of its bucket, else of the service named by the first label of `server.address`; only the map's
  arrows count. A failed span (status `ERROR`, `error` `true`, or a status of 500 or more) is an error.
- A **server** span is a request of its service: requests per second, p95 duration, error rate, and the requests of
  30 equal parts of the window for the chart.
- A **request** is a trace whose first span (no parent in the trace, the earliest) is a server span of a service,
  at least 3 s old: its id is the trace id, its method `http.request.method`, its route `http.route` (else
  `url.path`, else the span's name), its status `http.response.status_code` (else `http.status_code`), its spans in
  start order. Span events with `log.level` are its log lines (`error`, `fatal`, `panic` are errors; `warning`,
  `warn` warnings).

## Contracts

A project's contract is its `openapi/contract.yaml`: an OpenAPI 3.0 or 3.1 document, YAML or JSON, which V3
reads and never writes ([UI › Contracts](ui/contracts.md)). A project whose folder holds the file, when the
projects are read, offers Contracts; the window reads the file when it shows, and again after a file event
under `openapi/`.

### Reading

- **Parsing.** Yams reads the text, JSON included, keeping each mapping's order. The text can't be read when it
  isn't YAML or JSON (the parser's message), when its root isn't a mapping (`The root is not a mapping.`), or
  when it has no `openapi` value starting with `3` (`The root has no openapi value starting with 3.`; Swagger
  2.0 included).
- **Operations** follow `paths`, and in a path `get`, `put`, `post`, `delete`, `options`, `head`, `patch`,
  `trace`; a path item reached through `$ref` is resolved first. An operation's parameter replaces the path
  item's with the same `name` and `in`. Its key is `<METHOD> <path>`; the window names it by `operationId`, or
  by its key without one. Its tag is its first, else `default`.
- **`$ref`**: split at the first `#`; the fragment is a JSON pointer (`~1` is `/`, `~0` is `~`,
  percent-decoded); an empty file part is the same file; another is relative to the file holding the ref,
  `.` and `..` removed. A ref can't be resolved when its file part has a scheme, starts with `/`, leaves the
  project's folder, can't be read or parsed, or its pointer names nothing. Refs are followed at most 32 in a row.
- **Security schemes** V3 sends: `apiKey` (in a header, the query or a cookie), `http` `basic`, `http` `bearer`;
  the others are left out. An operation's schemes are those its `security` names, else the root's; without
  either, every scheme.

### Prefilled bodies

A request body starts with its first media type's `example`, else the `value` of the first of its `examples`,
else a sample of its schema, else nothing. A sample: an unresolved or circular ref gives none (a property is
left out); then `example`, the first `examples`, `default`, `const`, the first `enum`; `allOf` merges its
objects; `oneOf`/`anyOf` take the first; an object takes each property not `readOnly`; an array one sample of
`items`; a string by `format` (`2024-01-01`, `2024-01-01T00:00:00Z`, `00:00:00`, `user@example.com`, a UUID,
`https://example.com`, `example.com`, `192.0.2.1`, `2001:db8::1`), else `string`; a number its `minimum`, else
`0`; a boolean `true`. JSON media types (`application/json`, `+json`) are written with two-space indentation,
in the contract's order; a form (`application/x-www-form-urlencoded`) as `name=value&…`, percent-encoded;
another as text.

### Sending a request

1. **Base URL**: the environment's URL with its port, without a final `/` ([Project environment](#project-environment)).
2. **Path**: each `{name}` replaced by the path parameter's value, every byte but the RFC 3986 unreserved
   characters percent-encoded.
3. **Query**: the query parameters with a value, then the API keys sent in the query, `name=value` joined with
   `&`, after `?` (or `&`).
4. **Headers**, in order: header parameters with a value; `Cookie` (cookie parameters and API keys); API keys in
   headers; `Authorization: Basic …` when a username or password is set; `Authorization: Bearer …` when a
   token is; `Content-Type` when a body is sent; then the added headers, each replacing one of the same name.
5. **Body**: the body's UTF-8 bytes, when the operation takes one and it isn't empty.
6. **Client**: `URLSession` with an ephemeral configuration, no cookies, cache or credential storage;
   redirects followed. An environment with `allowInvalidCertificates` uses a session of its own that accepts
   any server certificate. The duration runs from the start to the last byte.

The answer: its status, its headers (`<name>: <value>`, sorted), its body (pretty JSON when it is JSON, else the
text; `Binary body (<size>)` otherwise). A request without answer gives the error's description.

### Stored values

`<data folder>/openapi-requests.json`, mode 0600: `{"contracts": [{"projectID", "path", "credentials",
"headers", "operations", "deviceID"}]}`. V3 keeps per contract (`path` is `openapi/contract.yaml`) the
credentials of each scheme (`value` for an API key, `username` and `password`, `token`) and the added headers,
set in the window's **Credentials and Headers** sheet; it keeps `operations` and `deviceID` as read, and leaves
out any other key (`environment`, `server`…). A missing or invalid file is empty. Claude's `api_call` uses the stored credentials and headers and
never sees them.

## Virtual machines

macOS virtual machines on this Mac, run by the Virtualization framework inside the app's process
(`MachineData`: `MachineHost`, `MachineLibrary`). Apple silicon only: elsewhere every start, install and setup
fails with `Virtual machines need a Mac with Apple silicon.` The app carries the entitlement
`com.apple.security.virtualization` ([Architecture › Entitlements](architecture.md#entitlements)).

### Storage

```
<data folder>/VirtualMachines/
  Images/<IMAGE-ID>/        an image: an uppercase UUID
    image.yml               its metadata file, mode 0600 (it holds the guest account's password)
    Restore.ipsw            the IPSW, while it downloads and installs
    HardwareModel           the hardware model it was installed for
    MachineIdentifier       its machine identifier
    AuxiliaryStorage        its auxiliary storage
    Disk.img                its disk, a sparse file of 32 GB
  Machines/<VM-ID>/         a machine: an uppercase UUID
    vm.yml                  its metadata file
    HardwareModel, MachineIdentifier, AuxiliaryStorage    copies of the image's, then its own
    Disk.img                an APFS clone of the image's disk, grown to its size, then its own
<data folder>/Runtime/guest/   the folder shared with a setup machine: install.sh and hephaestus-agent
```

- A folder whose name isn't an uppercase UUID, or whose metadata file is missing, invalid or names another id, is
  skipped. A file's `id` and `imageID` are read in uppercase.
- A machine whose `startedBy` isn't `user` is skipped.
- Deleting an image or a machine deletes its folder, not to the Trash: a disk there would keep its space.
- An image's size in the window is the space its files take (`MachineFolder.bytesOnDisk`, allocated sizes): for
  the sparse disk, what was written. A disk's size is `Disk.img`'s length in GB rounded up (`MachineFolder.diskGB`).
- `GB` is 1024³ bytes everywhere: `memoryGB`, `diskGB`, the defaults and the sheets.

### Image file

`VirtualMachines/Images/<IMAGE-ID>/image.yml`, `ImageFile`, written with mode 0600.

| Swift name | Key | Type | Required | Rules |
| --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` |
| id | `id` | `String` | yes | The folder's name. |
| version, build | `version`, `build` | `String` | yes | ipsw.me's, such as `27.2.1`, `26B131`. |
| state | `state` | `String` | yes | `downloading`, `installing`, `needsSetup`, `ready`, `failed`. |
| failure | `failure` | `String?` | written as `null` | The failure's message, one line. |
| userName, password | `userName`, `password` | `String?` | written as `null` | The guest account, in clear: the password of a test computer. |
| created | `created` | date | yes | |

`cores` and `memoryGB` stay as unknown keys; `diskGB`, `progress` and `diskBytes` are dropped.

```yaml
schema: 1
id: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
version: 27.2.1
build: 26B131
state: ready
failure: null
userName: null
password: null
created: 2026-11-09T14:03:00Z
```

### Machine file

`VirtualMachines/Machines/<VM-ID>/vm.yml`, `MachineFile`.

| Swift name | Key | Type | Required | Rules |
| --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` |
| id, name | `id`, `name` | `String` | yes | The name is one line of 1 to 100 characters, trimmed. |
| imageID, version, build | `imageID`, `version`, `build` | `String` | yes | The image it was made from, as it was then. |
| cores, memoryGB | `cores`, `memoryGB` | `Int` | yes | |
| diskGB | `diskGB` | `Int?` | written as `null` | When absent, the size of `Disk.img`. |
| growContainer | `growContainer` | `Bool` | no, `false` | True while the guest's container has to grow over a grown disk. |
| startedBy | `startedBy` | `String` | no, `user` | A machine with another value is skipped ([Storage](#storage)). |
| projectID, chatID | `projectID`, `chatID` | `String?` | written as `null` | Kept as read; the inspector's Project row shows `projectID`'s project. |
| created | `created` | date | yes | |
| macAddress | `macAddress` | `String?` | no, written only when set | The network device's MAC address, `xx:xx:xx:xx:xx:xx`, made at the machine's creation, or at its first start when it has none, so its guest's address can be found. |

`state` and `startedAt` are never stored: after a launch every machine is stopped. A file without `macAddress`
round-trips byte for byte until the machine is given a MAC address.

### macOS versions

`MacOSVersions.fetch`: `GET https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw`, `Accept: application/json`,
30 seconds. Each element of `firmwares` with a non-empty `version` and `buildid` and an `https` `url` is kept,
the first of each build; `filesize` (0 when absent) and `sha256sum` (lowercase, kept only when 64 hexadecimal
digits). Newest first: by version number by number (`27.2.1` before `27.2` before `26.6.2`), then by
`releasedate`, then in the answer's order. A failure is `The macOS versions cannot be read from ipsw.me:
<reason>.`, `<reason>` the network's message, `HTTP <status>` or `unexpected answer`. The host keeps the last list.

### Adding an image

`MachineHost.addImage(build:)`: the version must be in the list (`macOS build <build> not found.`); the image is
written `downloading`, then downloaded and installed in the background.

1. **Download** (`IPSWDownload`): to `Restore.ipsw` as the bytes arrive, no overall timeout, 60 seconds without
   data fails. Progress: bytes over `Content-Length`, else the listed size. Not 200: `The download failed: HTTP
   <status>.`; a SHA-256 that differs: `The downloaded file does not match its checksum.`
2. **Install**: the state becomes `installing`, then waits for a place among the 2 that run, in the order the
   installs began to wait. `MachineInstaller.install` reads the IPSW (`VZMacOSRestoreImage`), takes its most
   featureful supported configuration (none: `This Mac cannot run macOS <version>.`; the default cores or memory
   below its minimum: `macOS <version> needs at least <n> cores and <m> GB of memory.`), writes `HardwareModel`,
   a new `MachineIdentifier`, `AuxiliaryStorage` and a sparse 32 GB `Disk.img`, and runs `VZMacOSInstaller` with
   the default cores and memory. `Restore.ipsw` is deleted at the end, success or failure.
3. The state becomes `needsSetup`.

A failure sets `failed` with its message on one line; no retry: the user deletes the image. Quitting ends the
downloads and installs; at the next launch an image still `downloading` or `installing` becomes `failed` with
`The app quit before the image was ready.` and its IPSW is deleted. Cancel Download deletes the image.

### Setup

An image in `needsSetup` is set up once by the user, in the window's setup view ([UI › Virtual
Machines](ui/virtual-machines.md#setup)). `MachineHost.startSetup` checks the image (`The image is not waiting for
setup.`), the place (`2 virtual machines are already running.`) and the bundle's agent (`The guest agent is missing
from the app bundle.`), fills `Runtime/guest/` with `install.sh` and `hephaestus-agent` (mode 755) from the bundle,
and boots the image's own disk with the default cores and memory and the shared folder.

- **Restart in Recovery**: shuts the guest down through the agent, else asks with the framework's stop request
  (macOS asks in the guest); stops it at once after 30 seconds; starts it with `startUpFromMacOSRecovery`.
- **Finish Setup**: only with the agent connected and SIP off (`The agent is not connected with SIP off.`): the
  agent runs `/sbin/shutdown -h now` as root, the host waits up to 60 seconds, then stops it, and the image
  becomes `ready`.
- **Stop**: through the agent within 30 seconds, else at once; the image stays in `needsSetup`.

No tool starts a setup.

### Machine lifecycle

| Operation | Rules |
| --- | --- |
| Create (`createMachine`) | In this order: Apple silicon; the name; the image exists (`Image <id> not found.`) and is Ready (`The image is not Ready.`); `cores` 2 to this Mac's cores, `memoryGB` 4 to its memory, `diskGB` the image's disk size to 2048 (`<param>: use a number from <min> to <max>.`); fewer than 2 running. Then the folder: copies of the platform files, a clone of the disk grown to `diskGB` ([Growing a disk](#growing-a-disk)), a new MAC address, `vm.yml`; a file that can't be written deletes the folder (`The virtual machine could not be created: <reason>.`). Then it starts; a start that fails leaves it stopped. |
| Start | Fewer than 2 running; the machine made with its cores, memory, folder and MAC address, without a shared folder. |
| Stop | Through the agent (`/sbin/shutdown -h now` as root), waiting up to 60 seconds, else at once, as a power cut. A paused machine stops at once. |
| Pause, Resume | The framework's `pause()` and `resume()`; never stored. |
| Edit (`updateMachine`) | Stopped only (`The virtual machine is running.`); the name; the ranges, `diskGB` from its current size. A larger disk grows `Disk.img` and sets `growContainer`. |
| Delete | A running machine stops at once; the folder is deleted (`The virtual machine could not be deleted: <reason>.`). Deleting an image deletes its machines first. |

- A machine that stops by itself (the guest shut down, or a failure) leaves those that run; a failure's message
  is kept for the window, which shows it once (`MachineHost.failures`).
- Quitting the app stops every machine and setup at once.
- **Address**: every 3 seconds, up to 60 times, while it runs, the host looks up the machine's MAC address in
  `/var/db/dhcpd_leases`, the last lease of it, the octets compared without their leading zeros.

### Growing a disk

`GuestDisk.grow`: the file is extended (sparse); when it holds a GUID partition table whose last partition
is `RecoveryOSContainer`, that partition moves to the new end (its end aligned on 4096 bytes, copied from its end
to its start, blocks of zeros past the old end left unwritten), both copies of the table and the protective MBR
are rewritten, the old backup is cleared. Another layout is only extended. At the next start with the agent
connected, a machine with `growContainer` runs, as root, within 120 seconds:

```
/usr/sbin/diskutil apfs resizeContainer "$(/usr/sbin/diskutil info / | /usr/bin/awk -F': +' '/APFS Physical Store/ {print $2}')" 0
```

and `growContainer` becomes false once it succeeds.

### Configuration

`MachineConfiguration.make`: the platform from the folder's three files (`The hardware model of the image cannot
be read.`, `This Mac cannot run the macOS of the image.`, `The machine identifier of the image cannot be read.`,
`The auxiliary storage of the image is missing.`), the macOS boot loader, the cores and memory, one display of
2560 × 1600 at 220 ppi (the window's view reconfigures it to its size), the disk as a virtio block device, a
virtio network device behind NAT with the machine's MAC address, a Mac keyboard and a USB one, a Mac trackpad and a
USB pointing device, an entropy device, a virtio socket device (the agent's port 47822) and, for a setup, the
shared folder read-only with macOS's automount tag (`/Volumes/My Shared Files` in the guest).

### Guest account

Per image: `MachineHost.setAccount` takes `userName` and `password`, each optional: absent keeps, empty removes
(`null`); the user name is trimmed; a line break is refused (`userName: use one line.`, `password: use one
line.`). A call that changes nothing writes nothing.

### Defaults

`settings.yml`'s `defaultVMCores` (2), `defaultVMMemoryGB` (4) and `defaultVMDiskGB` (64)
([Settings file](#settings-file)): what New Machine starts with, and the cores and memory of an install and a
setup. A value outside this Mac's range is brought into it where used.

Defaults chosen at design time: the image file's mode, the MAC address and the address lookup, the machines
whose `startedBy` isn't `user` skipped.

## Settings file

`<data folder>/settings.yml`: the app's settings. Swift type `SettingsFile`. A missing file gives the defaults; an invalid one is set aside as `settings.yml.invalid`
and gives the defaults (`DataFolder.readSettings()`).

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | |
| mcpPort | `mcpPort` | `Int` | no | `47830` | The MCP server's port on 127.0.0.1: 1024–65535 (`SettingsFile.isPort`). `HEPHAESTUS_MCP_PORT` replaces it while set, without changing the file ([MCP](mcp.md#server-lifecycle)). |
| claudePath | `claudePath` | `String?` | no | absent | The Claude CLI the chats run: an absolute path or one from `~/`; absent finds it ([Chat processes › The CLI](#the-cli)). Written only when set. |
| chatModel | `chatModel` | `String?` | no | absent | The model of new chats, a CLI model value such as `opus`; absent for `default`. Written only when set. |
| chatEffort | `chatEffort` | `String?` | no | absent | The effort of new chats (`low`, `medium`, `xhigh`, `max`); absent for `high`. Written only when set. |
| defaultVMCores | `defaultVMCores` | `Int?` | no | absent (2) | New machines' cores, 2 to this Mac's ([Virtual machines › Defaults](#defaults)). Written only when not the default. |
| defaultVMMemoryGB | `defaultVMMemoryGB` | `Int?` | no | absent (4) | New machines' memory in GB, 4 to this Mac's. |
| defaultVMDiskGB | `defaultVMDiskGB` | `Int?` | no | absent (64) | New machines' disk in GB, 32 to 2048. |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

```yaml
schema: 1
mcpPort: 47830
```

## Secrets file

`<data folder>/secrets.json`, mode 0600: one JSON object, written with two-space indentation, keys sorted,
slashes not escaped, and a final line break. Not in the Keychain, so that a rebuilt app doesn't ask for
access.

| Key | Value |
| --- | --- |
| `schema` | `1` |
| `mcpExternalToken` | The MCP server's external token: 64 lowercase hexadecimal characters ([MCP › Authentication](mcp.md#authentication)). |

- `DataFolder.externalToken(make:)` reads the token; when the file is missing, isn't a JSON object, or holds no
  valid token, it makes one and writes it, the file's other keys kept. `replaceExternalToken(with:)` writes a
  new one the same way. The mode is set to 0600 after each write.

## Unknown keys

V3 keeps every key it doesn't use, so that a file written by another version or by hand keeps them when V3
writes it.

- **Kept keys** are the keys of a table that V3 doesn't use (its **kept** rows). Each is kept exactly as read,
  at its place in the table's order. V3 never adds one that a file doesn't have.
- **Unknown keys** are the keys no table names. They are written after the known and kept keys, in the order
  they were read.
- Both are kept as `RawYAML`: each scalar with its text, its resolved tag and its quoting, each sequence and
  mapping with its order and style, so that writing them back gives the same text. An alias the parser
  couldn't resolve becomes `null`. Not kept: comments, anchors, tags written in the file, and the layout of
  multi-line plain scalars.
- A change made in V3 changes the known keys only.
- The types that keep unknown keys: `ProjectFile`, `EnvironmentEntry`, `EnvironmentOverride`, `RegistryFile`,
  `CurrentEnvironmentsFile`.

## Validation

**Read rules** make a file invalid:

1. The file is valid UTF-8 and valid YAML, one document whose root is a mapping.
2. No mapping has a key twice.
3. `schema` is absent or `1`.
4. Every required key is present and not `null`.
5. Every known key has the type of its table: enumeration values are listed values, dates follow
   [Dates](#dates), and `id`, `color` and `githubPage` follow their rules.

The reason names the key path and the rule, never the file's content: `name: the required key is missing or
null`, `environments.[1].port: expected a value of type Int`. A file that breaks a read rule shows as a file
issue in the windows; V3 never rewrites it at load: it belongs to the project's repository.

**Write rules** are the other rules of the tables (lengths, ranges, single lines, uniqueness, path syntax).
They are checked on what the user or Claude changes, never when reading, and values a change doesn't touch are
written back as they were. A value that breaks one is refused with a `ProjectRuleError`, whose case the
windows put in their own words; its `description` is the English message of the logs and of Claude's tools:

| Case | Message |
| --- | --- |
| `identifierFormat` | `identifier: use 2 to 8 letters A–Z.` |
| `identifierInUse(id)` | `identifier: <id> is already used by another project.` |
| `nameLength(field:)` | `<field>: use 1 to 100 characters on one line.` |
| `relativePath(field:)` | `<field>: use a relative path with / separators and no empty, . or .. component.` |
| `url(field:)` | `<field>: use an absolute http or https URL.` |
| `port(field:)` | `<field>: use a port from 1 to 65535.` |
| `singleLine(field:)` | `<field>: use one line.` |
| `jaeger(field:)` | `<field>: use a Jaeger as <namespace>/<name>.` |
| `argoCDApplication(field:)` | `<field>: use an Argo CD application as <name> or <namespace>/<name>.` |
| `kubeconfig(field:)` | `<field>: use a kubeconfig file as an absolute path or a path starting with ~/.` |
| `githubPage` | `githubPage: use a page of the form https://github.com/<owner>/<name>.` |
| `duplicateEnvironment(name)` | `An environment named “<name>” already exists.` |

## Atomic writes

Every file is written in these steps (`AtomicFile.write`):

1. The complete content is encoded in memory.
2. The missing parent folders are created, mode 0755.
3. A temporary file `.<file name>.<UUID>.tmp` is created in the destination's folder with `O_CREAT | O_EXCL`
   and the mode of the file it replaces, 0644 for a new file (0600 for a private file). The name is 42 bytes
   longer than the file's.
4. All bytes are written, then `fsync`.
5. The temporary file is renamed onto the destination: readers see the old content or the new one, never a
   mix.
6. The SHA-256 of the written bytes is recorded for the path (`OwnWrites`), so that the file event the write
   causes is recognized ([Outside changes](#outside-changes)).

When a step fails, the temporary file is deleted and the write fails with `<path> cannot be written:
<reason>`.

- A destination that is a symbolic link, followed up to 32 levels, is written at its target, so the link
  stays.
- Temporary files a crash left, names matching `.<file name>.<UUID>.tmp`, are deleted when V3 next loads
  their folder.
- Files V3 removes are moved to the Trash, never deleted (`Trash`), and their removal is recorded like a
  write. Tests use a folder that stands for the Trash.
- A change that touches several files writes a file before the files that refer to it, and removes a
  reference before the file it refers to: a crash between two steps leaves at most an unreferenced file,
  never a reference to a missing one. Each feature's section gives its order.

## Outside changes

Files change without V3: git checkouts and merges, editors, scripts. V3 watches them with FSEvents and shows
each change as if it had made it.

- **Streams**: one FSEvents stream per watched folder, with file-level events, following the folder when it is
  created, removed or moved (`FileEventHub.watch`, `restart`). Events report paths with symbolic links
  resolved (`/private/var/…` for `/var/…`).
- **Batches**: events are collected until 300 ms pass without a new one, or 2 seconds after the first,
  whichever comes first, then handed over as one batch, in the order they came. A git checkout that touches a
  thousand files is one batch; a stream of changes still shows within 2 seconds.
- **Own changes**: a file whose SHA-256 equals V3's last write of that path is ignored, and so is the absence
  of a file V3 removed.
- **Watched folders**: the data folder and the folder of each top-level project, and of each registry entry
  that didn't load (so that it loads when it appears); sub projects lie inside their parent's folder. The set
  follows each change.
- **What a batch reloads.** A batch matters when it holds a project file, a `.hephaestus` folder,
  `registry.yml`, `current-environments.yml`, a `.git/config`, a project's folder or one holding it created,
  moved or removed, or dropped events (`mustRescan`, `rootChanged`). Then the registry and the choices are read
  again when their files changed (an invalid or missing one leaves the version in memory, written again at
  the next change), and every project loads again ([Loading](#loading)), with these rules:
  - A file that decodes to the value in memory changes nothing: no new snapshot.
  - A project file that became invalid, or whose `id` changed, leaves the version loaded before: the project
    shows a file issue with the reason (`LoadedProject.fileIssue`); the next change V3 makes writes the version
    in memory over it.
  - A missing project file unloads the project and its sub projects; their entries stay, and they load again
    when the file comes back.
  - A changed registry loads the added folders and unloads the removed ones.
  - A changed `.git/config` reads the origins again.

## Conformance tests

`ProjectDataTests` decode the fixtures ([Examples](#examples)) with the Swift types: the complete project file is
written back byte for byte; every example round-trips to an equal value, and every key of the example is in
the output. `FileStorageTests` check the coding rules on their own documents: kept keys in order and layout,
read rules, defaults, schema, dates and quoting. `TicketDataTests` write the complete example ticket (`HEPH-12`) and
bundle (`HEPH-B2`) back byte for byte, read the minimal ticket with its defaults and creation entry, keep the
unknown keys of `HEPH-14`, and check every rule of [Tickets and bundles](#tickets-and-bundles) in temporary
folders.
