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

| File                        | Path                                                        | Swift type                | Since            |
|-----------------------------|-------------------------------------------------------------|---------------------------|------------------|
| Project file                | `<project>/.hephaestus/project.yml`                         | `ProjectFile`             | Foundation       |
| Git ignore file             | `<project>/.hephaestus/.gitignore`                          | — (text)                  | Foundation       |
| Registry file               | `<data folder>/registry.yml`                                | `RegistryFile`            | Foundation       |
| Current environments file   | `<data folder>/current-environments.yml`                    | `CurrentEnvironmentsFile` | Foundation       |
| Settings file               | `<data folder>/settings.yml`                                | `SettingsFile`            | MCP server       |
| Secrets file                | `<data folder>/secrets.json`                                | — (JSON object)           | MCP server       |
| Ticket file                 | `<project>/.hephaestus/ticket/<TICKET-ID>.yml`              | `TicketFile`              | Tickets          |
| Bundle file                 | `<project>/.hephaestus/bundle/<BUNDLE-ID>.yml`              | `BundleFile`              | Tickets          |
| Attachments                 | `<project>/.hephaestus/attachments/<TICKET-ID>/<id>-<name>` | — (any file)              | Tickets          |
| Chat file                   | `<project>/.hephaestus/chats/<CHAT-ID>.yml`                 | `ChatFile`                | Chat             |
| Builds                      | — (read from GitHub with gh, never stored)                  | —                         | Builds           |
| Contract                    | `<project>/openapi/contract.yaml` (read only)               | `OpenAPIContract`         | Contracts        |
| Stored request values       | `<data folder>/openapi-requests.json`                       | `StoredContract`          | Contracts        |
| Chat transcript             | `<project>/.hephaestus/chats/<CHAT-ID>.jsonl`               | `ChatItem` on each line   | Chat             |
| Chat MCP configuration      | `<data folder>/Runtime/mcp/<CHAT-ID>.json`                  | — (JSON)                  | Chat             |
| Skill run MCP configuration | `<data folder>/Runtime/mcp/skill-<UUID>.json`               | — (JSON)                  | System Prompts   |
| Chat log                    | `<data folder>/Logs/claude-<CHAT-ID>.log`                   | — (text)                  | Chat             |
| Plan usage file             | `<data folder>/plan-usage.yml`                              | `PlanUsage`               | Weekly usage     |
| Ticket chat worktree        | `<data folder>/Worktrees/<project id>/<ticket id>/`         | — (a git worktree)        | Tickets, Chat    |
| Image file                  | `<data folder>/VirtualMachines/Images/<IMAGE-ID>/image.yml` | `ImageFile`               | Virtual Machines |
| Machine file                | `<data folder>/VirtualMachines/Machines/<VM-ID>/vm.yml`     | `MachineFile`             | Virtual Machines |

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

| Id                        | Format                      | Example                                | Chosen by                                                                 |
|---------------------------|-----------------------------|----------------------------------------|---------------------------------------------------------------------------|
| Project identifier        | `^[A-Z]{2,8}$`              | `ORD`                                  | the user, when creating the project                                       |
| Ticket id                 | `^[A-Z]{2,8}-[1-9][0-9]*$`  | `ORD-142`                              | V3, from the project's `nextTicketNumber` ([Ticket rules](#ticket-rules)) |
| Bundle id                 | `^[A-Z]{2,8}-B[1-9][0-9]*$` | `ORD-B3`                               | V3, from the project's `nextBundleNumber`                                 |
| Attachment and comment id | uppercase UUID              | `5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B` | V3, at random                                                             |

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
- **Updates**: the Updater keeps a downloaded update in `~/Library/Caches/HephaestusV3/Updates/<build>/`, outside
  the data folder, under `HEPHAESTUS_DATA_DIR` too: the `.dmg`, `release.json`, the app copied out of it in
  `expanded/`, and `install-failed` after a swap that failed. Only the build being installed has a folder, which
  goes once it is installed ([Updater › Download and verification](updater.md#download-and-verification)).

| File                                  | Content                                                                                                                                   |
|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| `registry.yml`                        | The top-level projects ([Registry file](#registry-file)).                                                                                 |
| `current-environments.yml`            | The environment chosen for each service ([Current environments file](#current-environments-file)); absent until a first choice.           |
| `plan-usage.yml`                      | The Claude plan's newest weekly usage ([Plan usage file](#plan-usage-file)); absent until a chat's first report.                          |
| `settings.yml`, `secrets.json`        | The app's settings and the MCP server's token ([Settings file](#settings-file), [Secrets file](#secrets-file)).                           |
| `skills/<name>/SKILL.md`              | An internal skill's content, once the user wrote it ([Internal skills](#internal-skills)).                                                |
| `Runtime/mcp/<CHAT-ID>.json`          | A running chat's MCP configuration, mode 0600, deleted when its process ends ([Chat processes](#chat-processes)).                         |
| `Runtime/mcp/skill-<UUID>.json`       | A running internal skill's MCP configuration, mode 0600, deleted when the run ends ([Internal skills](#internal-skills)).                 |
| `Runtime/claude-cwd/`                 | The empty folder the CLI's model probe runs in.                                                                                           |
| `Worktrees/<project id>/<ticket id>/` | The git worktree of a ticket chat a bundle's chat started, on the branch `<bundle id>/<ticket id>` ([Implement chats](#implement-chats)). |
| `Runtime/plugins/hephaestus-skills/`  | The internal skills chats call, as a Claude Code plugin, written before each chat process starts ([Chat plugin](#chat-plugin)).           |
| `Runtime/downloads/<UUID>/`           | A release file gh downloads, before it moves into the Downloads folder; removed afterwards ([Builds › Downloads](#downloads)).            |
| `VirtualMachines/`                    | The images and machines ([Virtual machines › Storage](#storage)).                                                                         |
| `Runtime/guest/`                      | The guest agent and its install script, shared with a setup machine ([Virtual machines › Setup](#setup)).                                 |
| `Logs/claude-<CHAT-ID>.log`           | A chat's CLI log: a line per launch, then the CLI's standard error; emptied at a launch once over 10 MB.                                  |

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

| Swift name           | Key                    | Type                            | Required | Default | Rules                                                                                                                                                                                                                                                                                                     |
|----------------------|------------------------|---------------------------------|----------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| schema               | `schema`               | `Int`                           | no       | `1`     | [Keys and values](#keys-and-values).                                                                                                                                                                                                                                                                      |
| id                   | `id`                   | `String`                        | yes      | —       | The project identifier ([Ids](#ids)). Set at creation, never changed. Read rule: `id: "<id>" is not a valid project identifier`.                                                                                                                                                                          |
| name                 | `name`                 | `String`                        | yes      | —       | One line, 1–100 characters. Names need not be unique.                                                                                                                                                                                                                                                     |
| created              | `created`              | `Date`                          | yes      | —       | When the project was created. Never changed.                                                                                                                                                                                                                                                              |
| type                 | `type`                 | `ProjectKind`                   | no       | `none`  | [Project kind](#project-kind).                                                                                                                                                                                                                                                                            |
| color                | `color`                | `String?`                       | no       | `null`  | `#` and six hex digits, uppercased when read, or the name of a tint ([Project color](#project-color)). Any other value makes the file invalid (`color: "<text>" is not a color of the form #RRGGBB, nor a tint`). Left out of the file when there is none.                                                |
| icon                 | `icon`                 | `String?`                       | no       | `null`  | An SF Symbol name, such as `hammer`. Read trimmed, an empty value being none. Left out of the file when there is none.                                                                                                                                                                                    |
| nextTicketNumber     | `nextTicketNumber`     | `Int`                           | no       | `1`     | The first number tried for the next ticket.                                                                                                                                                                                                                                                               |
| nextBundleNumber     | `nextBundleNumber`     | `Int`                           | no       | `1`     | The first number tried for the next bundle.                                                                                                                                                                                                                                                               |
| docsPath             | `docsPath`             | `String`                        | no       | `docs`  | Relative path of the documentation folder, which may be missing.                                                                                                                                                                                                                                          |
| githubPage           | `githubPage`           | `String?`                       | no       | `null`  | The page typed in the GitHub page field, `https://github.com/<owner>/<name>`: read trimmed and without a trailing `/`; any other value makes the file invalid ([GitHub page](#github-page)). Left out of the file when there is none.                                                                     |
| —                    | `useParentSettings`    | kept                            | no       | absent  | V2's switch for a sub project to use its parent's settings. No effect in V3, where a sub project takes every value it leaves empty from its parent ([Resolution](#resolution)); kept as read, never added.                                                                                                |
| subprojects          | `subprojects`          | `[String]`                      | no       | `[]`    | Relative paths of the direct sub projects, in the order they were added, each once. Each names a folder inside this project's folder that holds `.hephaestus/project.yml`. An entry whose folder or file is missing or invalid is kept.                                                                   |
| —                    | `webTabs`              | kept                            | no       | absent  | Web tabs; not used.                                                                                                                                                                                                                                                                                       |
| —                    | `skills`               | kept                            | no       | absent  | Enabled skills; not used.                                                                                                                                                                                                                                                                                 |
| —                    | `chatDefaults`         | kept                            | no       | absent  | Settings of new chats; not used.                                                                                                                                                                                                                                                                          |
| graphEnabled         | `graphEnabled`         | `Bool?`                         | no       | `null`  | Whether the graph is enabled: the project overview then shows the Service Map's graph ([UI › Projects › Graph](ui/projects.md#graph)); `null` takes the parent's value, `false` for a top-level project ([Resolution](#resolution)). V3 writes `false` too, while set; left out of the file while `null`. |
| environments         | `environments`         | `[EnvironmentEntry]`            | no       | `[]`    | The project's own environments, whatever its type, in the order they were added; names unique, letter case included ([Project environment](#project-environment)).                                                                                                                                        |
| environmentOverrides | `environmentOverrides` | `[String: EnvironmentOverride]` | no       | `{}`    | A sub project's changes to the environments it inherits, by environment name, written in Unicode code point order ([Environment override](#environment-override)). A change for a name no inherited environment has is kept and ignored.                                                                  |
| dashboardWidgets     | `dashboardWidgets`     | `[DashboardWidgetEntry]?`       | no       | `null`  | The widgets of the project's [Dashboard](ui/dashboard.md), in their order ([Dashboard widget](#dashboard-widget)). `null` shows the default list and `[]` no widget. Left out of the file while the project has no stored list.                                                                           |
| dashboardGraphWindow | `dashboardGraphWindow` | `DashboardGraphWindow?`         | no       | `null`  | The time window of the Dashboard's service widgets: `fiveMinutes`, `hour`, `day` or `week`; `null` is `hour`. Any other value makes the file invalid. Left out of the file while `null`. V3 has no `week` window yet: a stored `week` is kept, and the Dashboard shows the last hour.                     |
| —                    | `deletedChats`         | kept                            | no       | absent  | Costs of deleted chats; not used.                                                                                                                                                                                                                                                                         |
| —                    | `commentAnswers`       | kept                            | no       | absent  | Costs of comment answers; not used.                                                                                                                                                                                                                                                                       |
| keptKeys             | —                      | `YAMLMapping`                   | —        | empty   | The kept keys present in the file, as read.                                                                                                                                                                                                                                                               |
| unknownKeys          | —                      | `YAMLMapping`                   | —        | empty   | [Unknown keys](#unknown-keys).                                                                                                                                                                                                                                                                            |

A `commands` key is an unknown key, not a kept one.

### Project kind

Swift type `ProjectKind`, key `type`: a string enumeration. Any other value makes the file invalid.

| Value              | Name    |
|--------------------|---------|
| `none`             | Other   |
| `goService`        | Service |
| `swiftApplication` | App     |
| `library`          | Library |

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

| Swift name         | Key                  | Type          | Required | Default        | Rules                                                                                                                                                                                                       |
|--------------------|----------------------|---------------|----------|----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| id                 | `id`                 | `UUID`        | yes      | —              | Unique within the list.                                                                                                                                                                                     |
| kind               | `kind`               | `Kind`        | yes      | —              | `project`, `tickets`, `recentChats`, `cost`, `instances`, `serviceGraph`, `busiestCalls`, `failedRequests`, `requestsPerMinute` or `recentBuilds`. Any other value makes the file invalid.                  |
| title              | `title`              | `String`      | no       | `""`           | The Title setting: one line, at most 100 characters, trimmed; empty means the title of the kind.                                                                                                            |
| column             | `column`             | `Int?`        | no       | `null`         | The first column the widget covers, 0–23.                                                                                                                                                                   |
| row                | `row`                | `Int?`        | no       | `null`         | The first row it covers, from 0.                                                                                                                                                                            |
| width              | `width`              | `Int?`        | no       | `null`         | The columns it covers, 1–24; `column` + `width` is at most 24.                                                                                                                                              |
| height             | `height`             | `Int?`        | no       | `null`         | The rows it covers, from 1.                                                                                                                                                                                 |
| fields             | `fields`             | `[Field]`     | no       | all four       | `project`: the fields shown, among `name`, `identifier`, `type` and `folder`. At least one, each once.                                                                                                      |
| statuses           | `statuses`           | `[Status]`    | no       | the first four | `tickets`: the counts shown, among `todo`, `in_progress`, `review`, `done` and `draft`. At least one, each once. The default is the first four; a widget V3 adds starts with all five, written in the file. |
| includeSubprojects | `includeSubprojects` | `Bool`        | no       | `true`         | `tickets` and `cost`: whether the counts or the total cover the loaded sub projects.                                                                                                                        |
| chatCount          | `chatCount`          | `Int`         | no       | `5`            | `recentChats`: the most chats listed, 1–20.                                                                                                                                                                 |
| chatKinds          | `chatKinds`          | `[ChatKind]`  | no       | all four       | `recentChats`: `project`, `ticket`, `bundle`, `feedback`. At least one, each once.                                                                                                                          |
| count              | `count`              | `Int`         | no       | `5`            | `busiestCalls`, `failedRequests` and `recentBuilds`: the most rows listed, 1–20.                                                                                                                            |
| unknownKeys        | —                    | `YAMLMapping` | —        | empty          | [Unknown keys](#unknown-keys).                                                                                                                                                                              |

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

| Swift name               | Key                        | Type          | Required | Default | Rules                                                                                                                                                    |
|--------------------------|----------------------------|---------------|----------|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| name                     | `name`                     | `String`      | yes      | —       | One line, 1–100 characters, trimmed. Unique within the project, letter case included.                                                                    |
| url                      | `url`                      | `String?`     | no       | `null`  | The address of the environment's API: an absolute `http` or `https` URL with a host.                                                                     |
| port                     | `port`                     | `Int?`        | no       | `null`  | 1–65535. Replaces the URL's port in the base URL.                                                                                                        |
| allowInvalidCertificates | `allowInvalidCertificates` | `Bool`        | no       | `false` | Requests to the environment accept an invalid server certificate.                                                                                        |
| namespace                | `namespace`                | `String?`     | no       | `null`  | The Kubernetes namespace of the deployment; `null` uses the current context's.                                                                           |
| deployment               | `deployment`               | `String?`     | no       | `null`  | The Kubernetes Deployment that runs the service.                                                                                                         |
| jaeger                   | `jaeger`                   | `String?`     | no       | `null`  | The Kubernetes Service of the environment's Jaeger, `<namespace>/<name>`: one `/`, parts not empty, no white space.                                      |
| argoCDApplication        | `argoCDApplication`        | `String?`     | no       | `null`  | The Argo CD Application: `<name>`, in the namespace `argocd`, or `<namespace>/<name>`; one `/` at most, parts not empty, no white space.                 |
| kubeconfig               | `kubeconfig`               | `String?`     | no       | `null`  | The kubeconfig file: an absolute path or one starting with `~/`; `null` uses kubectl's default (`KUBECONFIG` of the login shell, else `~/.kube/config`). |
| unknownKeys              | —                          | `YAMLMapping` | —        | empty   | [Unknown keys](#unknown-keys). A `context` key is one: kubectl always uses the kubeconfig file's current context.                                        |

- `url` and the five Kubernetes keys are single lines, read and written trimmed, an empty value being `null`.
- The **base URL** is `url` with its port replaced by `port` when set, without a trailing `/`; none without
  `url` (`EnvironmentEntry.baseURL`).

### Environment override

Swift type `EnvironmentOverride`, one value of `environmentOverrides`, under the name of the environment it
changes. A key with a value replaces the parent's; `null` keeps the parent's, so a change can't remove a
parent's value. Every field of the environment but its name can change: V3 adds `namespace` and
`kubeconfig` to V2's six keys.

| Swift name               | Key                        | Type          | Default | Rules                                                                               |
|--------------------------|----------------------------|---------------|---------|-------------------------------------------------------------------------------------|
| url                      | `url`                      | `String?`     | `null`  | As `EnvironmentEntry.url`.                                                          |
| port                     | `port`                     | `Int?`        | `null`  | 1–65535.                                                                            |
| allowInvalidCertificates | `allowInvalidCertificates` | `Bool?`       | `null`  | Stored only while it differs from the parent's.                                     |
| namespace                | `namespace`                | `String?`     | `null`  | V3's addition. One line. Left out of the file while `null`.                         |
| deployment               | `deployment`               | `String?`     | `null`  |                                                                                     |
| jaeger                   | `jaeger`                   | `String?`     | `null`  | `<namespace>/<name>`.                                                               |
| argoCDApplication        | `argoCDApplication`        | `String?`     | `null`  | `<name>` or `<namespace>/<name>`.                                                   |
| kubeconfig               | `kubeconfig`               | `String?`     | `null`  | V3's addition. As `EnvironmentEntry.kubeconfig`. Left out of the file while `null`. |
| unknownKeys              | —                          | `YAMLMapping` | empty   | [Unknown keys](#unknown-keys).                                                      |

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

| Swift name  | Key        | Type          | Required | Default | Rules                                                                                                                                                                                 |
|-------------|------------|---------------|----------|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| schema      | `schema`   | `Int`         | no       | `1`     |                                                                                                                                                                                       |
| projects    | `projects` | `[String]`    | no       | `[]`    | Absolute paths of the projects' folders ([Paths](#paths)), in the order they were added, each once. An entry that isn't an absolute path is skipped when loading (`loadableEntries`). |
| unknownKeys | —          | `YAMLMapping` | —        | empty   | [Unknown keys](#unknown-keys).                                                                                                                                                        |

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

| Swift name  | Key        | Type               | Required | Default | Rules                                                                                                                                                                                                                    |
|-------------|------------|--------------------|----------|---------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| schema      | `schema`   | `Int`              | no       | `1`     |                                                                                                                                                                                                                          |
| projects    | `projects` | `[String: String]` | no       | `{}`    | The chosen environment's name, by project identifier, written in Unicode code point order of the identifiers. A project without an entry, or whose entry names none of its environments, works in its first environment. |
| unknownKeys | —          | `YAMLMapping`      | —        | empty   | [Unknown keys](#unknown-keys).                                                                                                                                                                                           |

```yaml
schema: 1
projects:
  DEMO: staging
  DEMOAPI: local
```

## Plan usage file

`<data folder>/plan-usage.yml`: the newest weekly usage of the Claude account, which the CLI reports in any chat
([Stream mapping](#stream-mapping)), kept so that the status bar shows it after a restart, before any chat runs
([UI › Navigation › Weekly usage](ui/navigation.md#weekly-usage)). The file doesn't exist before the first report.
Swift type `PlanUsage` (ChatData): V2's `plan-usage.yml` without its `received`, which only ordered the values of
several Macs.

| Swift name            | Key                     | Type          | Required | Default | Rules                                                                                                                            |
|-----------------------|-------------------------|---------------|----------|---------|----------------------------------------------------------------------------------------------------------------------------------|
| schema                | `schema`                | `Int`         | no       | `1`     |                                                                                                                                  |
| utilization           | `utilization`           | `Double`      | yes      | —       | The part of the week's limit used: a number of 0 or more, usually up to 1; the CLI sends more than 1 past the limit.             |
| resetsAt              | `resetsAt`              | `Date`        | yes      | —       | When the weekly window resets. From then on the value isn't shown.                                                               |
| status                | `status`                | `String`      | yes      | —       | The CLI's `status`, for the window that limits the account now: `allowed`, `allowed_warning` or `rejected`. One line, not empty. |
| overageStatus         | `overageStatus`         | `String?`     | no       | `null`  | The CLI's `overageStatus`, such as `rejected`. One line, not empty.                                                              |
| overageDisabledReason | `overageDisabledReason` | `String?`     | no       | `null`  | The CLI's `overageDisabledReason`, such as `out_of_credits`. One line, not empty.                                                |
| isUsingOverage        | `isUsingOverage`        | `Bool?`       | no       | `null`  | The CLI's `isUsingOverage`.                                                                                                      |
| unknownKeys           | —                       | `YAMLMapping` | —        | empty   | [Unknown keys](#unknown-keys).                                                                                                   |

```yaml
schema: 1
utilization: 0.68
resetsAt: 2026-11-22T20:00:00Z
status: allowed
overageStatus: rejected
overageDisabledReason: out_of_credits
isUsingOverage: false
```

- **Reading.** `ChatSession.start` reads it. A missing file gives no value; an invalid one is set aside as
  `plan-usage.yml.invalid`, replacing an older one, and gives no value. A value whose reset time has passed is
  read all the same: it isn't shown.
- **Writing.** A report that differs from the kept value replaces it, then the file is written
  ([Atomic writes](#atomic-writes)), with the kept value's unknown keys; a report equal to it writes nothing. A
  write that fails keeps the value in memory. The value is never cleared, only replaced.
- The strings are kept as the CLI sends them, so a value a later CLI adds is kept and shown.

## Loading

When the app starts (`ProjectSession.start`, [Architecture › ProjectData](architecture.md#projectdata)):

1. The data folder is created when missing, and its lock taken.
2. `registry.yml` is read; a missing one is created empty, an invalid one set aside as `registry.yml.invalid`
   and recreated empty. `current-environments.yml` is read; a missing one gives no choice, an invalid one is
   set aside and gives no choice.
3. The projects load: the registry's entries in order, each followed by its sub projects, depth first, in
   `subprojects` order. Temporary files a crash left in a `.hephaestus/` folder are deleted. An entry is
   skipped, and reported with its reason (`ProjectIssue`), when:

   | Reason                            | When                                                                                     |
   |-----------------------------------|------------------------------------------------------------------------------------------|
   | `invalidEntry`                    | A registry entry isn't an absolute path, or a `subprojects` entry isn't a relative path. |
   | `folderMissing`                   | The folder doesn't exist.                                                                |
   | `fileMissing`                     | The folder has no `.hephaestus/project.yml`.                                             |
   | `invalidFile(reason:)`            | The project file breaks a read rule ([Validation](#validation)).                         |
   | `identifierInUse(identifier:by:)` | A project loaded before it has its identifier. It loads once that project is removed.    |

   The entry stays where it is: the project loads as soon as its folder and file are fine. A folder reached
   twice (through a symbolic link) loads once.
4. The files are watched ([Outside changes](#outside-changes)).
5. Then, without holding the windows: the login shell's environment is captured, the tools are looked up,
   and the `origin` of each loaded folder is read ([GitHub page](#github-page)).

Invalid project files are never renamed or rewritten at load: they belong to the project's repository.

## Changes

Every change goes through `ProjectLibrary`, one at a time, and gives a new snapshot. Files are written with
[Atomic writes](#atomic-writes), a referenced file before the file that refers to it.

| Change                             | Rules                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Order of the writes                                                                                                                                             |
|------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Create** (`NewProject`)          | Name: one line, 1–100 characters, trimmed. Identifier: uppercased, 2–8 letters A–Z, used by no loaded project. With a parent: the folder is strictly inside the parent's folder (`Choose a folder inside “<parent name>”.`), checked before anything is written. The folder is created when missing and `createsFolder` is set; otherwise it must exist. A folder that already holds a project is refused: open it instead. The new file has `created` = now, the name, the identifier and the type; every other key takes its default.                                                                                                                                                                                                                                                                                                                                                                                  | 1. the project file and `.gitignore` 2. the parent's `subprojects` (the given parent, else the innermost loaded project whose folder holds it), or the registry |
| **Open** (a folder)                | A folder already loaded gives its project. Otherwise it must hold a valid project file whose identifier no loaded project uses. Registry entries that its file lists as its descendants, at any depth, leave the registry: they load under it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | 1. `.gitignore` 2. the innermost loaded project's `subprojects`, or the registry                                                                                |
| **Update** (`ProjectChange`)       | Only the values the change sets: name; type; color (a tint, or `#RRGGBB` uppercased, or none); icon (trimmed, none when empty); docs folder (a relative path, not `.hephaestus` or inside it); GitHub page (validated, none when empty); graph (on, off or none, which takes the parent's); the whole list of the project's own environments; all its changes to inherited environments; the whole list of Dashboard widgets ([Dashboard widget](#dashboard-widget) › Write rules); the Dashboard's time window. An environment or a change equal to a stored one is written back as it is, even when a hand edit made it break a rule (each stored environment keeps at most one equal environment: a copy is checked); any other is checked ([Validation](#validation)), its names trimmed, a change that sets nothing dropped. An own environment can't take a name another environment has, inherited ones included. | the project file, then `current-environments.yml` when a choice follows a rename or is forgotten                                                                |
| **Remove**                         | The project and its loaded sub projects leave the app: its entry leaves the parent's `subprojects` or the registry, and their chosen environments are forgotten. No file of theirs changes.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | 1. the parent's project file, or the registry 2. `current-environments.yml`                                                                                     |
| **Choose the current environment** | One of the project's environments as they apply.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | `current-environments.yml`                                                                                                                                      |

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

| Key           | Type                              | Required | Default            | Rules                                                                                                                                                          |
|---------------|-----------------------------------|----------|--------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `schema`      | `Int`                             | no       | `1`                | [Keys and values](#keys-and-values).                                                                                                                           |
| `id`          | ticket id                         | yes      | —                  | Equals the file name without `.yml`; its identifier part is the project's `id`. A file whose `id` differs is invalid.                                          |
| `title`       | `String`                          | yes      | —                  | One line, 1–200 characters once trimmed.                                                                                                                       |
| `status`      | `TicketFileStatus`                | no       | `todo`             | `draft`, `todo`, `in_progress`, `review`, `done` ([Ticket rules](#ticket-rules)).                                                                              |
| `created`     | date                              | yes      | —                  | Never changed.                                                                                                                                                 |
| `updated`     | date                              | no       | `created`          | Set to now by every write of the file by V3.                                                                                                                   |
| `createdBy`   | `user` or `claude`                | no       | `user`             | Who created the ticket.                                                                                                                                        |
| `description` | `String`                          | no       | `""`               | Markdown, line breaks LF.                                                                                                                                      |
| `attachments` | `[AttachmentEntry]`               | no       | `[]`               | The ticket's own files, in the order added ([Attachments](#attachments)).                                                                                      |
| `comments`    | `[CommentEntry]`                  | no       | `[]`               | Oldest first; ids unique within the ticket.                                                                                                                    |
| `chats`       | `[String]`                        | no       | `[]`               | The chats linked to the ticket, uppercase UUIDs: Implement and a feedback chat append theirs ([Implement chats](#implement-chats)); kept as read.              |
| `links`       | `[TicketLinkEntry]`               | no       | `[]`               | The links this ticket declares, in the order given ([Link rules](#link-rules)).                                                                                |
| `history`     | `[HistoryEntry]`                  | no       | one creation entry | Oldest first, only appended to. A file without history reads with one `created` entry made from `created` and `createdBy`, `to: todo`, without device or chat. |
| `priority`    | `low`, `medium`, `high`, `urgent` | no       | none               | Written after `history` only when set.                                                                                                                         |
| `labels`      | `[String]`                        | no       | `[]`               | Written after `history` (and `priority`) only when not empty; trimmed, empty ones dropped, each once.                                                          |

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

| Key      | Rules                                                                                                                                                                                                                                       |
|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `kind`   | `created`, `status`, `title`, `linkAdded`, `linkRemoved`, `description`.                                                                                                                                                                    |
| `date`   | When the change was made.                                                                                                                                                                                                                   |
| `from`   | The previous status (`status`) or title (`title`); required for those two, `null` for the others.                                                                                                                                           |
| `to`     | The new status (`created`: the status it was created with), the new title, or the link as `<kind> <ticket id>`; not written for `description`.                                                                                              |
| `author` | `user`, `claude` or `automatic`; V3 writes `automatic` for the title `set-ticket-title` gives a ticket created without one ([UI › Tickets › Titles written by Claude](ui/tickets.md#titles-written-by-claude)), with no `device` or `chat`. |
| `device` | For `user`: the Mac's computer name at the time (`TicketSession.computerName()`).                                                                                                                                                           |
| `chat`   | For `claude`: the chat's id, or `external` for a terminal session.                                                                                                                                                                          |

A file breaking these rules (a `status` entry without two statuses, a link entry not shaped `<kind> <id>`) is
invalid.

### Bundle file

`.hephaestus/bundle/<BUNDLE-ID>.yml`, Swift type `BundleFile`: `schema`, `id` (bundle id, equal to the file
name), `title` (one line, 1–200 characters), `status` (`todo`, `in_progress` or `done`; default `todo`),
`created`, `updated` (default `created`), `tickets` (ticket ids of the project, in implementation order, each
once; default `[]`), `chats` (Implement All appends its chat, [Implement chats](#implement-chats); kept as read; default `[]`), then unknown keys. A ticket may belong to several
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

| Change                               | Rules                                                                                                                                                                                                                                                                                                                                                                          | Order of the writes                                                                                                                                |
|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| **Create a ticket** (`NewTicket`)    | The project is loaded (`Project <ID> not found.`). Title, description, status (`todo` or `draft`: `A new ticket is To Do or a draft.`), files and links are checked before a number is taken. `created` and `updated` now, `createdBy` the actor, the history one `created` entry.                                                                                             | 1. project file (counter) 2. attachment files 3. ticket file; when 2 or 3 fails, the copied files are removed                                      |
| **Change a ticket** (`TicketChange`) | Title, description, priority, labels, the whole list of links. History entries in this order: rename, description edit, one `linkRemoved` per link no longer declared (in the old order), one `linkAdded` per new link (in the given order); a link whose kind changes is removed, then added. Priority and labels add no entry. A change that changes nothing writes nothing. | ticket file                                                                                                                                        |
| **Set a ticket's status**            | [Ticket rules › Status](#ticket-rules); one `status` entry.                                                                                                                                                                                                                                                                                                                    | 1. ticket file 2. each bundle file the automatic rules change, in bundle number order                                                              |
| **Delete tickets**                   | Their ids leave every bundle (the automatic rules apply in the same write), and every link to them leaves the other tickets of the project, with no history entry.                                                                                                                                                                                                             | 1. each bundle file listing them 2. each ticket file linking to them 3. the ticket files and their `attachments/<ID>/` folders, moved to the Trash |
| **Add a comment**                    | Text or files; the comment's author is the actor.                                                                                                                                                                                                                                                                                                                              | 1. attachment files 2. ticket file                                                                                                                 |
| **Edit a comment**                   | Its text, with the same rule; sets the comment's `updated`. Its files can't change. Anyone may edit any comment.                                                                                                                                                                                                                                                               | ticket file                                                                                                                                        |
| **Delete a comment**                 | `Comment <id> not found.` for an unknown one.                                                                                                                                                                                                                                                                                                                                  | 1. ticket file 2. its files, moved to the Trash                                                                                                    |
| **Add attachments**                  | To the ticket's own files.                                                                                                                                                                                                                                                                                                                                                     | 1. attachment files 2. ticket file                                                                                                                 |
| **Remove an attachment**             | A ticket attachment only (`Attachment <id> not found.`).                                                                                                                                                                                                                                                                                                                       | 1. ticket file 2. the file, moved to the Trash                                                                                                     |
| **Create a bundle**                  | At least one ticket (`A bundle needs at least one ticket.`), each of the project (`<ID> does not belong to project <IDENT>.`), existing (`Ticket <ID> not found.`), once (`<ID> is listed more than once.`). Starts `done` when they all are.                                                                                                                                  | 1. project file (counter) 2. bundle file                                                                                                           |
| **Change a bundle**                  | Title; the whole list of tickets, which may be empty, where an id the bundle already lists may name a missing ticket.                                                                                                                                                                                                                                                          | bundle file                                                                                                                                        |
| **Set a bundle's status**            | [Ticket rules › Bundle status](#ticket-rules).                                                                                                                                                                                                                                                                                                                                 | bundle file                                                                                                                                        |
| **Delete a bundle**                  | Its tickets stay.                                                                                                                                                                                                                                                                                                                                                              | the bundle file, moved to the Trash                                                                                                                |

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

| Swift name         | Key                | Type            | Required | Default    | Rules                                                                                                                                                                                                                                                                                                                                         |
|--------------------|--------------------|-----------------|----------|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| schema             | `schema`           | `Int`           | no       | `1`        |                                                                                                                                                                                                                                                                                                                                               |
| id                 | `id`               | `String`        | yes      | —          | An uppercase UUID (`ChatIDs.isChatID`), equal to the file's name.                                                                                                                                                                                                                                                                             |
| title              | `title`            | `String`        | no       | `New Chat` | One line. V3 titles a new chat with the first line of its first message that isn't empty, at most 80 characters; a rename takes 1 to 100 characters on one line.                                                                                                                                                                              |
| kind               | `kind`             | `ChatFile.Kind` | yes      | —          | `project`, `ticket`, `bundle`, `feedback`, `ci` or `setup` ([Chat kinds](#chat-kinds)). V3 makes `project` chats, `feedback` chats ([Feedback chats](#feedback-chats)), `ticket` and `bundle` chats ([Implement chats](#implement-chats)), `ci` chats ([CI chats](#ci-chats)).                                                                |
| ticketID           | `ticket`           | `String?`       | no       | `null`     | Always written, `null` when absent.                                                                                                                                                                                                                                                                                                           |
| bundleID           | `bundle`           | `String?`       | no       | `null`     | Always written, `null` when absent.                                                                                                                                                                                                                                                                                                           |
| orchestratorChatID | `orchestrator`     | `String?`       | no       | absent     | A `ticket` or `ci` chat's orchestrator: the bundle chat that started it with `implement_ticket`, or the chat that started it with `watch_ci` ([CI chats](#ci-chats)). Never changed. Written only when set.                                                                                                                                   |
| imageID            | `image`            | `String?`       | no       | absent     | A `setup` chat's image, kept as read ([Chat kinds](#chat-kinds)). Written only when set.                                                                                                                                                                                                                                                      |
| created            | `created`          | `Date`          | yes      | —          | Never changed.                                                                                                                                                                                                                                                                                                                                |
| updated            | `updated`          | `Date`          | no       | `created`  | Set by a message sent, a turn's end, a rename, a settings change. The Chat window lists chats by it, the latest first.                                                                                                                                                                                                                        |
| settings           | `settings`         | `ChatSettings`  | no       | defaults   | [Chat settings](#chat-settings).                                                                                                                                                                                                                                                                                                              |
| sessionStarted     | `sessionStarted`   | `Bool`          | no       | `false`    | True once the CLI has started the session (its first `system/init`): later launches resume it.                                                                                                                                                                                                                                                |
| closed             | `closed`           | `Bool`          | no       | `false`    | Whether the chat is closed. A message sent sets it back to `false`.                                                                                                                                                                                                                                                                           |
| questionsBlocked   | `questionsBlocked` | `Bool`          | no       | `false`    | `ticket` chats only: set by Implement, cleared by the user's first message ([Implement chats](#implement-chats)). Written only when `true`.                                                                                                                                                                                                   |
| origin             | `origin`           | `String?`       | no       | absent     | The tool whose chat panel started the chat, a `ToolKind` value such as `tickets`; absent for a chat of the Chat window. Written only when set.                                                                                                                                                                                                |
| unknownKeys        | —                  | `YAMLMapping`   | —        | empty      | Kept and written after the known keys ([Unknown keys](#unknown-keys)); `contextUsage` among them, which V3 reads and writes there, as V2's layout had it ([Context usage](#context-usage)). The runtime keys `projectID`, `state`, `backgroundWork`, `compactingSince`, `costUSD` and `mentionedIDs` are ignored when read and never written. |

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

| Kind       | `ticket`                                                                | `bundle` | Other                           |
|------------|-------------------------------------------------------------------------|----------|---------------------------------|
| `project`  | `null`                                                                  | `null`   |                                 |
| `ticket`   | required                                                                | `null`   | may have an `orchestrator`      |
| `bundle`   | `null`                                                                  | required |                                 |
| `feedback` | `null`, or the first ticket it made ([Feedback chats](#feedback-chats)) | `null`   | its files in `chats/<CHAT-ID>/` |
| `ci`       | exactly one of `ticket` and `bundle`                                    |          | `orchestrator` required         |
| `setup`    | `null`                                                                  | `null`   | `image` required                |

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

| `type`                                                      | Keys                                                                                                                                                                                                                                                                                                                                                     | Id                                                          |
|-------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| `user`                                                      | `text` (the message as written, without what V3 adds for Claude), `attachments` (the files the message carried, [Message files](#message-files)), `sender` (the Mac's name), `linkedItems` (kept as read), `references` (`[{tool, project, focus, title, environment}]`, the item the message's chip carried; `tool` is a `ToolKind` value or `project`) | a new uppercase UUID, also the message's `uuid` for the CLI |
| `assistant`                                                 | `text`, `messageID`, `parentToolUseID`, `model` (the CLI's model id), `effort`                                                                                                                                                                                                                                                                           | `<message id>#<block index>`                                |
| `thinking`                                                  | `text`, `parentToolUseID` (kept; not shown)                                                                                                                                                                                                                                                                                                              | `<message id>#<block index>`                                |
| `toolUse`                                                   | `toolUseID`, `name` (without `mcp__<server>__`), `server` (`hephaestus` for the app's tools, `null` for the CLI's), `input`, `parentToolUseID`                                                                                                                                                                                                           | `<message id>#<block index>`                                |
| `toolResult`                                                | `toolUseID`, `text`, `isError`, `images` (the result's images as files, [Result images](#result-images))                                                                                                                                                                                                                                                 | `<tool use id>#result`                                      |
| `questions`                                                 | `questionSetID`, `questions`, `answers`, `completed` ([Questions](#questions))                                                                                                                                                                                                                                                                           | the set's id, a new uppercase UUID                          |
| `permissionRequest`                                         | `requestID`, `toolName` (the CLI's name, `mcp__hephaestus__add_comment`), `input`, `reason`, `decision` (`allow`, `allowAlways`, `deny`; `null` while it waits), `decidedBy` (the Mac whose user answered; `null` while it waits and when the app cancelled it)                                                                                          | `perm-<request id>`                                         |
| `system`                                                    | `text` (in English), `level` (`info`, `warning`, `error`)                                                                                                                                                                                                                                                                                                | a new uppercase UUID                                        |
| `result`                                                    | `durationMs`, `costUSD` (kept; not shown), `isError`, `summary`                                                                                                                                                                                                                                                                                          | a new uppercase UUID                                        |
| `images`                                                    | `caption`, `images` ([Images item](#images-item))                                                                                                                                                                                                                                                                                                        | a new uppercase UUID                                        |
| `symbol`, `color`, `sound`, `shortcut`, `font`, `animation` | `requestID`, `question`, `suggestions`, `recommended`, `answer`; `lightAndDark` for a color, `sample` for a font, `inUse` for a shortcut, and the keys V3 doesn't read, kept ([Picker requests](#picker-requests))                                                                                                                                       | the request's id, a new uppercase UUID                      |

A string
longer than 100,000 characters in a call's input or a result's text is cut, followed by `… [truncated <n>
characters]`.

The `system` lines V3 writes:

| When                                                        | Level   | Text                                                                                                                                           |
|-------------------------------------------------------------|---------|------------------------------------------------------------------------------------------------------------------------------------------------|
| The CLI can't be started                                    | error   | `Claude failed to start: <reason>`                                                                                                             |
| No `system/init` within 60 s                                | error   | `Claude did not start within 60 seconds.`                                                                                                      |
| The CLI exits during a turn, not ended by the app           | error   | `Claude exited with code <n>: <last line of its standard error>`, or `Claude exited with code <n>.`, or `Claude was terminated by signal <n>.` |
| The first `system/init` lists no usable `hephaestus` server | warning | `The Hephaestus tools aren't available in this session: the app's MCP server is <failed, needs-auth, disabled or missing>.`                    |
| A resumed session the CLI doesn't find                      | warning | `Claude's session for this chat was not found. A new session started: Claude doesn't remember this chat's earlier messages.`                   |
| The CLI refuses a model or effort change                    | warning | `Claude did not accept the new <model or effort> now: <reason>. It applies the next time Claude starts.`                                       |
| Stop                                                        | info    | `Stopped by the user.`                                                                                                                         |
| The app quits during a turn                                 | warning | `Stopped because Hephaestus quit.`                                                                                                             |
| A compaction                                                | info    | `Conversation compacted (<automatic or manual>, <tokens> tokens before)`, tokens as `24.6K`, `967K`, `1.2M`                                    |

#### Questions

Claude asks the user with the MCP tool `ask_questions` ([MCP](mcp.md#ask_questions)); the chat shows them in a
card over the composer ([UI › Chat › Questions](ui/chat.md#questions)). The `questions` item is V2's:

| Key             | Type               | Rules                                                                                                                                            |
|-----------------|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `questionSetID` | `String`           | The set's id; the item's `id` too.                                                                                                               |
| `questions`     | `[Question]`       | 1 to 26, labelled `A`, `B`… in order.                                                                                                            |
| `answers`       | `{String: String}` | By label: the chosen option's label, the user's own text, `Skipped`, or for a multiple question one line `- <choice>` per choice. `{}` at first. |
| `completed`     | `Bool`             | Every question has an answer, and the answers went to Claude.                                                                                    |

A `Question` (`ChatQuestion`): `label`, `question` (Markdown), `kind` (`single`, the default when absent, or
`multiple`), `options` (`[{label, description}]`, `description` `null` when absent; the recommended ones first),
`recommended` (a string in a single question, a list in a multiple one, as V2 wrote it; V3 reads both forms),
and for a multiple question `minChoices` and `maxChoices` (`null` when absent: 1, and no maximum).

**Rules** (`QuestionsItem.questions(from:)`), checked in this order; the first one broken refuses the whole set
with `invalid` and nothing shows:

| Rule                                                                | Message                                                                                    |
|---------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| 1 to 26 questions                                                   | `questions: give 1 to 26 questions.`                                                       |
| Question *n* has the *n*-th letter as label                         | `questions: question <n> has the label "<letter>".`                                        |
| A question's text isn't empty, trimmed                              | `questions: question <label> has no text.`                                                 |
| 2 to 10 options                                                     | `questions: question <label> has 2 to 10 options.`                                         |
| Option labels not empty, trimmed, and distinct ignoring case        | `questions: question <label> has an empty option label, or two the same.`                  |
| Option labels one line of at most 200 characters                    | `questions: question <label> has an option label of several lines or over 200 characters.` |
| `minChoices` and `maxChoices` only on a multiple question           | `questions: question <label> has minChoices or maxChoices without the kind multiple.`      |
| A single question recommends exactly one of its option labels       | `questions: question <label> recommends exactly one of its option labels.`                 |
| A multiple question recommends one or more of its labels, each once | `questions: question <label> recommends one or more of its option labels, each once.`      |
| `minChoices` and `maxChoices` at least 1                            | `questions: question <label> has a minChoices under 1.` (or `maxChoices`)                  |
| `minChoices` (1 when absent) at most `maxChoices`                   | `questions: question <label> has a minChoices over its maxChoices.`                        |
| At most `maxChoices` recommended                                    | `questions: question <label> recommends more options than its maxChoices.`                 |

Options and recommended labels are trimmed of spaces. A set that passes gets each question's recommended options
moved first, in their order among the options, the others keeping theirs; `recommended` is stored in that order.

**Posting** (`ChatSession.postQuestions`): the chat's transcript is read; a chat that already has a set without
all its answers refuses (`conflict`, `Questions already wait for the user's answers in this chat.`). The item
is added and the chat's state refreshed: `running` while the turn that asked goes on, then `waitingAnswers`.

**Answering** (`ChatSession.answerQuestion`, from the card):

- The answer is trimmed and has 1 to 10,000 characters (`invalid`, `answer: write 1 to 10,000 characters.`); for
  a multiple question, `Skipped` or one line `- <choice>` per choice, none empty (`invalid`, `answer: write one
  line "- <choice>" per choice, or Skipped.`), their number within `minChoices` and `maxChoices` (`invalid`,
  `answer: the number of choices is outside the question's bounds.`). An unknown label is `invalid` (`label: the
  set has no question <label>.`); a set no longer waiting is a `conflict` (`These questions are already
  answered.`).
- Questions are answered in any order; an answer replaces an earlier one. The item is rewritten (`update`).
- The answer that completes the set needs the Claude CLI (as a message does), sets `completed`, then sends the
  answers as the user's message, as any message: to the running CLI, or to a new one (with `--resume` when the
  session started). The message, its lines separated by `\n`, the questions in label order:

```
Answers:
A: Do nothing and beep
B: Skipped
C:
- Web tabs
- In the window title too
```

A multiple question's answer, unless skipped, follows `<label>:` on its own lines. A set stays waiting across
the CLI's exits and the app's restarts; messages typed meanwhile go to Claude as usual and change nothing in it.

#### Picker requests

V2's six requests, brought over on the user's request (18 November 2026): Claude asks the user to choose an SF
Symbol, a color, a sound, a keyboard shortcut, a font or an animation with the MCP tools `ask_symbol`,
`ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation` ([MCP](mcp.md#ask_symbol)); the chat
shows the request in its card over the composer ([UI › Chat › Picker cards](ui/chat.md#picker-cards)). Each is a
transcript item whose `type` is its kind (`PickerItem`, `PickerKind`, ChatPickers.swift), with V2's keys:

| Key            | Type                             | Kinds      | Rules                                                                                                                                                                           |
|----------------|----------------------------------|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `requestID`    | `String`                         | all        | The request's id, a new uppercase UUID; the item's `id` too.                                                                                                                    |
| `question`     | `String`                         | all        | Markdown, trimmed, not empty.                                                                                                                                                   |
| `suggestions`  | `[String]`, or `[{light, dark}]` | all        | 2 to 10, distinct, trimmed, in Claude's order. A color request asked with `lightAndDark` has pairs `{"light": <color>, "dark": <color>}`; every other suggestion is a string.   |
| `recommended`  | `String`, or `{light, dark}`     | all        | One of `suggestions`, as Claude wrote it.                                                                                                                                       |
| `answer`       | `String?`                        | all        | `null` until the user answers, then set once: the card's marker, the user's own text, or `Skipped`.                                                                             |
| `lightAndDark` | `Bool`                           | `color`    | Claude asked for a light and dark pair; written for a color request only, `false` when absent.                                                                                  |
| `sample`       | `String`                         | `font`     | The text the card draws in the chosen font, trimmed, not empty.                                                                                                                 |
| `inUse`        | `[{shortcut, command}]`          | `shortcut` | The app's own shortcuts, in Claude's order, each trimmed: `shortcut` in menu notation, `command` one line of 1 to 200 characters; no shortcut twice; at most 500; may be empty. |

Keys V3 doesn't read are kept (`otherKeys`) and written back with the item. An item without `question`,
`suggestions` (one at least that reads as a string or a pair) or `recommended` is skipped.

```json
{"type":"color","id":"7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A","created":"2026-11-03T14:20:01Z","requestID":"7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A","question":"Which background color should the card use?","lightAndDark":true,"suggestions":[{"light":"#FFFFFF","dark":"#1C1C1E"},{"light":"systemBackground","dark":"secondarySystemBackground"}],"recommended":{"light":"#FFFFFF","dark":"#1C1C1E"},"answer":"Light ![](color:#FFFFFF), Dark ![](color:#2C2C2E)"}
{"type":"shortcut","id":"8E1F2A3B-4C5D-4E6F-9A7B-8C9D0E1F2A3B","created":"2026-11-03T14:22:10Z","requestID":"8E1F2A3B-4C5D-4E6F-9A7B-8C9D0E1F2A3B","question":"Which shortcut should open the ticket filter?","suggestions":["⇧⌘F","⌥⌘F","⌃⌘F"],"recommended":"⇧⌘F","inUse":[{"shortcut":"⌘N","command":"New Ticket"}],"answer":null}
```

**Rules** (`PickerItem.request(_:from:catalogs:created:)`), checked in this order after trimming the question,
the sample, each suggestion and the recommendation (and each `shortcut` and `command` of `inUse`); the first one
broken refuses the call with `invalid`, and nothing shows. `<tool>` is the tool's name.

| Rule                                                                                                                                                                                                          | Message                                                                                                                       |
|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| The question isn't empty                                                                                                                                                                                      | `<tool> needs a question.`                                                                                                    |
| A font request's sample isn't empty                                                                                                                                                                           | `ask_font needs a sample text.`                                                                                               |
| 2 to 10 suggestions                                                                                                                                                                                           | `<tool> needs 2 to 10 suggestions.`                                                                                           |
| Color: without `lightAndDark`, each suggestion and the recommendation are one color (a string)                                                                                                                | `ask_color needs one color per suggestion, or lightAndDark for light and dark pairs.`                                         |
| Color: with `lightAndDark`, each suggestion and the recommendation are a pair                                                                                                                                 | `ask_color needs a light and dark pair per suggestion.`                                                                       |
| Color: each color is a hex color `#RRGGBB`, its digits in either case, or a system color name with its case ([Text › System colors](text.md#system-colors)), checked in order, a pair's light before its dark | `<color> is not a hex color #RRGGBB or a system color name.`                                                                  |
| Color: the suggestions are distinct, colors compared as [Text › System colors](text.md#system-colors) says                                                                                                    | `ask_color has a repeated suggestion.`                                                                                        |
| Color: the recommendation is one of them                                                                                                                                                                      | `ask_color: the recommended color must be one of the suggestions.`                                                            |
| Other kinds: no suggestion is empty, none twice                                                                                                                                                               | `<tool> has an empty or repeated suggestion.`                                                                                 |
| Symbol: each one is in the Mac's SF Symbols, localized variants included ([Picker catalogues](#picker-catalogues))                                                                                            | `<name> is not an SF Symbol of this Mac.`                                                                                     |
| Sound: each one is in the project's sound catalogue                                                                                                                                                           | `<name> is not a sound of this Mac or of the project.`                                                                        |
| Shortcut: each one is in menu notation ([Text › Shortcut notation](text.md#shortcut-notation))                                                                                                                | `<shortcut> is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key.`                              |
| Font: each one is a text style or three parts separated by `/` ([Text › Font notation](text.md#font-notation))                                                                                                | `<font> is not a font: write a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17.` |
| Font: a family font's size is 1 to 999 pt with at most one decimal                                                                                                                                            | `<font>: the size must be 1 to 999 pt, with at most one decimal.`                                                             |
| Font: its family is in the project's font catalogue, with that weight                                                                                                                                         | `<font> is not a font of this Mac.`                                                                                           |
| Animation: `.`, a name of letters, optionally parameters in parentheses ([Text › Animation expressions](text.md#animation-expressions))                                                                       | `<suggestion> is not a SwiftUI animation expression.`                                                                         |
| Animation: the name is a preset                                                                                                                                                                               | `<suggestion>: use .smooth, .snappy, .bouncy, .spring, .easeIn, .easeOut, .easeInOut or .linear.`                             |
| Animation: the preset's parameters, each once, in its order                                                                                                                                                   | `<suggestion>: .<preset> takes (<labels>).`, such as `.spring takes (duration:bounce:).`                                      |
| Animation: each value within its range                                                                                                                                                                        | `<suggestion>: <label> must be from <minimum> to <maximum>.`                                                                  |
| Other kinds: the recommendation is one of the suggestions                                                                                                                                                     | `<tool>: the recommended <kind> must be one of the suggestions.`                                                              |
| Shortcut: at most 500 entries in `inUse`                                                                                                                                                                      | `ask_shortcut accepts at most 500 inUse entries.`                                                                             |
| Shortcut: each `inUse` shortcut is in menu notation                                                                                                                                                           | as for the suggestions                                                                                                        |
| Shortcut: each command is one line of 1 to 200 characters                                                                                                                                                     | `ask_shortcut: the command of <shortcut> in inUse must be one line of 1 to 200 characters.`                                   |
| Shortcut: no shortcut twice in `inUse`                                                                                                                                                                        | `ask_shortcut: <shortcut> appears twice in inUse.`                                                                            |

The checks of a suggestion run in the order of `suggestions`, every check on one suggestion before the next, and
name the first that fails.

**Posting** (`ChatSession.postPicker`): an unknown chat is refused (`notFound`, `Chat <id> not found.`); a sound,
shortcut or animation request in a project whose type isn't App (`swiftApplication`) is refused (`forbidden`,
V2's messages `ask_sound is only available in Swift application projects.`, `ask_shortcut is available only in
Swift application projects.`, `ask_animation is available only in Swift application projects.`); then the
catalogues the kind needs are read and the rules checked. The chat's transcript is read; a chat has one request
waiting at most, questions included: while questions wait, `conflict` with `Questions already wait for the user's
answers in this chat.`; while a request waits, `conflict` with V2's `A symbol request is already waiting for an
answer in this chat.` (`color`, `sound`, `shortcut`, `font`; `An animation request …` for an animation).
`postQuestions` refuses the same way while a request waits. The item is added and the state refreshed: `running`
while the turn that asked goes on, then `waitingAnswers` ([Chat processes](#chat-processes)).

**Answering** (`ChatSession.answerPicker`, from the card): the answer is trimmed and has 1 to 10,000 characters
(`invalid`, `answer: write 1 to 10,000 characters.`); an unknown request is `notFound`; one already answered is a
`conflict` (`This <kind> request was already answered.`). It needs the Claude CLI, as a message does; the item is
rewritten (`update`) with its answer, then the message `<Kind>: <answer>` goes to Claude as the user's, as any
message: to the running CLI, or to a new one (with `--resume` once the session started). A closed chat reopens,
as for any message.

```
Symbol: ![](sf:line.3.horizontal.decrease.circle)
Color: Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)
Sound: ![](sound:iOS 26.1/sms-received1.caf)
Shortcut: ![](shortcut:⇧⌘K)
Font: ![](font:System Rounded/Semibold/17)
Animation: ![](animation:.spring(duration: 0.4, bounce: 0.2))
```

The cards answer with these markers ([Text › Markers](text.md#markers)): `![](sf:<name>)`; `![](color:<color>)`
or `Light ![](color:<light>), Dark ![](color:<dark>)`, a hex color in uppercase; `![](sound:<name>)`;
`![](shortcut:<shortcut>)`, a key `(`, `)` or `\` written with a `\` before it; `![](font:<font>)`, a family
font's size written `17` or `15.5`; `![](animation:<expression>)`. "Answer another way" gives the field's text,
trimmed, its line breaks kept; Skip gives `Skipped`. A request stays waiting across the CLI's exits and the app's
restarts; messages typed meanwhile go to Claude as usual and change nothing in it. The result of the tool is
`{"requestID": <id>}`.

#### Picker catalogues

What the requests check their suggestions against and the cards search (`PickerCatalogs`, PickerCatalogs.swift),
as V2's. `ChatSession.catalogs` holds them; its `Sources` are injectable (the tests use fixtures in temporary
folders): `system(runner:environment:)` reads this Mac. The Mac's catalogues are read the first time they are
needed, off the main actor, and kept until the app quits; a project's files are read at each use.

- **SF Symbols** (`SFSymbolCatalog`): `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/`'s
  `name_availability.plist` (`symbols` maps each name to its release, `year_to_release` each release to its OS
  versions; a name belongs when its release's `macOS` version is at most the running macOS, or gives none) and
  `symbol_search.plist` (each name's keywords). A file that can't be read leaves the catalogue empty, or the names
  without keywords. A localized variant is a name whose last dot-separated part is one of `ar`, `bn`, `el`, `gu`,
  `he`, `hi`, `ja`, `km`, `kn`, `ko`, `ml`, `mni`, `mr`, `my`, `or`, `pa`, `rtl`, `ru`, `sat`, `si`, `ta`, `te`,
  `th`, `zh`: Claude may suggest one; the search never lists one.
- **Symbol search**: the query trimmed, lowercased and split at white space (empty: nothing); a name matches by
  name when it contains every word, by keyword when each word is in the name or one of its keywords; the name
  matches then the keyword matches, each in alphabetical order, without localized variants and without the
  request's suggestions; no limit.
- **Sounds** (`SoundCatalog`): `macOS/<file>` for each sound file directly in `/System/Library/Sounds`;
  `<platform> <version>/<path>` for each sound file at any depth under `System/Library/Audio/UISounds` of each
  Simulator runtime that `/usr/bin/xcrun simctl list runtimes --json` lists (its `name` and `runtimeRoot`; run with
  the login shell's environment, 30 s at most; the first of two runtimes of one name; none when it fails, such as
  without Xcode); `Project/<path>` for each sound file of the project ([Project files](#picker-catalogues)). A sound
  file is a regular file ending in `.caf`, `.aiff`, `.wav` or `.mp3` (any case); names starting with `.` and
  symbolic links are skipped. Order: the macOS sounds, then each runtime's in the order of their names, then the
  project's, paths in Finder order (`localizedStandardCompare`). A name with a line break, unbalanced parentheses,
  or white space at either end is left out: a marker couldn't carry it.
- **Sound search**: a name matches when, lowercased, it contains every word of the trimmed, lowercased query
  (empty: nothing); the request's suggestions left out; catalogue order; no limit.
- **Fonts** (`FontCatalog`): the system designs `System`, `System Rounded`, `System Serif` and `System Monospaced`
  with the nine SwiftUI weights `Ultralight` (-0.8), `Thin` (-0.6), `Light` (-0.4), `Regular` (0), `Medium` (0.23),
  `Semibold` (0.3), `Bold` (0.4), `Heavy` (0.56), `Black` (0.62); every family CoreText lists
  (`CTFontManagerCopyAvailableFontFamilyNames`, names starting with `.` left out), its faces' style names as weights,
  italic faces included, each with CoreText's weight trait; the families of the project's `.ttf`, `.otf` and `.ttc`
  files (a collection gives each of its fonts; a file CoreText can't read is skipped). A project family named like
  an installed one adds the faces the installed one lacks; a family named like a system design is left out. A
  family's weights are listed by value, upright before italic, then by name; families in alphabetical order after
  the system designs; then the eleven text styles.
- **Font search**: a family matches when its name, lowercased, contains every word of the query; a text style when
  its notation does; an empty query lists every family and text style; the text styles that are suggestions are
  left out. **Nearest weight**: choosing a family of the results keeps the weight when the family has one of that
  name, else takes the face whose value is nearest the current weight's in the family it was chosen in, an upright
  face before an italic one on a tie, then the first.
- **Project files** (`ProjectFiles`): `git ls-files -z --cached --others --exclude-standard` in the project's
  folder (10 s at most), so git's ignored files stay out; without git or outside a work tree, a walk of the folder
  that skips names starting with `.`, symbolic links and the folders `node_modules`, `DerivedData`, `Pods` and
  `build`, 100,000 entries at most. The folders of its sub projects are left out either way.
- **Playing a sound** (`ChatSession.soundFile(named:projectRoot:)`): `Project/<path>` is the sound file at that path
  in the view's project folder (never outside it); another name is the Mac's sound of that name.

#### Context usage

As V2 did, the app asks a chat's CLI how much of the context its conversation uses (`ChatSession.askContextUsage`),
writing `{"type":"control_request","request_id":<id>,"request":{"subtype":"get_context_usage"}}`: after Claude's
first `assistant` item of each message of the main conversation, after each `result`, and after a compaction.
One request waits at most; a line that asks meanwhile asks once more when the answer comes, or after 30 s without
one. A success answer gives `ContextUsage` (`ContextUsage.from`): `usedTokens` its `totalTokens` (0 or more),
`windowTokens` its `maxTokens` (above 0), `bufferTokens` the `tokens` of its `categories` entry whose `id` is
`autocompact_buffer` (0 without one, below the window), `received` the time read. It replaces the chat file's
`contextUsage`, a mapping of those four keys (the date as the files write dates), kept after the process ends. A
failure, or a value that breaks those rules, leaves it as it was. The UI shows it ([UI › Chat › Context
indicator](ui/chat.md#context-indicator)); `left` is the window less the buffer and the tokens used, at least 0.

#### Closing and deleting chats

- **Close** (`ChatSession.close`, the window's Close, `close_chat`): without a turn in progress, `closed` becomes
  true at once and the CLI ends as when idle (stdin closed, SIGTERM then SIGKILL 5 s apart). During a turn, the
  run remembers it (`closesAfterTurn`); the turn's end closes the chat as above; a Stop, an error `result` or the
  process's exit cancels it. A message delivered to a closed chat sets `closed` to false.
- **Reopen** sets `closed` to false.
- **`close_chat`** (`closeChats(_:caller:)`): without `chatIDs`, the calling chat (at once, or once its turn ends);
  with them, each: the caller's own as above; a closed one stays closed and counts as closed; another chat of the
  caller's project closes at once unless its state is starting, running or waitingPermission (refused, `Claude is
  at work in chat <id>.`); an unknown id (`Chat <id> not found.`) and another project's chat (`Chat <id> belongs
  to another project.`) are refused. The external token's list has no project to keep to.
- **Delete** (`ChatSession.delete`): the chat's process ends (SIGTERM, then SIGKILL), its cards are cancelled, then
  `<CHAT-ID>.yml`, `<CHAT-ID>.jsonl` and the folder `<CHAT-ID>/` move to the Trash (each only when it exists), and
  the chat is forgotten. A file that can't be moved stops it (`storage`).
- **Resume** (`needsResume`, `resume`): available while the chat isn't closed and its state is `error`, or idle with
  its newest `result` an error other than `Stopped by the user.`; it sends `/hephaestus-skills:resume-chat`, the
  call of the internal skill `resume-chat` ([Internal skills](#internal-skills)).

#### Result images

A tool's result that holds images (`tool_result` content parts `{"type":"image","source":{"type":"base64","media_type":…,"data":…}}`)
gives `StreamOutput.toolResultImages` after its item, as V2 kept them: `storeResultImages` writes each into the
chat's folder as `<UUID>-image-<n>.<extension>` (`n` from 1 in each result; the extension `png`, `jpg`, `gif`,
`webp`, or the type's subtype), and rewrites the `toolResult` item with them as `images`, V2's `Attachment`s
(`contentType` the image's type) ([Message files](#message-files)). An image that can't be written is left out.
The images aren't sent back to Claude, which had them.

#### Images item

The images Claude shows with `show_image` ([MCP › show_image](mcp.md#show_image)), as V2's item (`ImagesItem`,
`ChatSession.postImages`):

| Key       | Type           | Rules                                                                                                                                    |
|-----------|----------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `caption` | `String?`      | Markdown shown above the images, trimmed; `null` when Claude gave none or it is blank.                                                   |
| `images`  | `[Attachment]` | 1 to 10 images stored in `.hephaestus/chats/<CHAT-ID>/` as `<UUID>-<name>`, in the order of the paths ([Message files](#message-files)). |

```json
{"type":"images","id":"9F0A1B2C-3D4E-4F5A-8B6C-7D8E9F0A1B2C","created":"2026-11-03T22:10:04Z","caption":"The new icon at 1024 px.","images":[{"id":"1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D","name":"icon-1024.png","path":"chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301/1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D-icon-1024.png","contentType":"image/png","size":98418}]}
```

The rules, in this order, refuse the whole call (`invalid`) and store nothing:

| Rule                                                                                                                                             | Message                                                                        |
|--------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| 1 to 10 paths                                                                                                                                    | `show_image needs 1 to 10 images.`                                             |
| Each path (absolute, from `~/`, or from the project's folder) names a regular file that can be read                                              | `<path> is not a readable file.`                                               |
| Each file is at most 20 MB, and all together                                                                                                     | `<name> is larger than 20 MB.`, `The attachments of one request exceed 20 MB.` |
| Each file starts with a PNG (`89 50 4E 47 0D 0A 1A 0A`), JPEG (`FF D8 FF`), GIF (`GIF87a`, `GIF89a`) or WebP (`RIFF`, 4 bytes, `WEBP`) signature | `<path> is not a PNG, JPEG, GIF or WebP image.`                                |

The signature decides the stored `contentType` (`image/png`, `image/jpeg`, `image/gif`, `image/webp`), whatever
the extension. The same path twice is stored twice. The item is the main conversation's, whatever agent made the
call. A copy that fails removes those made (`unavailable`, `The images couldn't be stored: <reason>`).

#### Message files

A user item's `attachments`, as V2's `Attachment` (`MessageAttachment` in ChatData): each file is copied once
into the chat's folder, `.hephaestus/chats/<CHAT-ID>/<id>-<name>`, and never changed; it moves to the Trash with
the chat's folder.

| Key           | Type     | Required | Default                    | Rules                                                                                               |
|---------------|----------|----------|----------------------------|-----------------------------------------------------------------------------------------------------|
| `id`          | `String` | yes      | —                          | An uppercase UUID, unique in the chat; the stored file's name starts with it.                       |
| `name`        | `String` | yes      | —                          | The name shown, one path component, such as `screenshot.png`.                                       |
| `path`        | `String` | yes      | —                          | Relative to `.hephaestus/`: `chats/<CHAT-ID>/<id>-<name>`.                                          |
| `contentType` | `String` | no       | `application/octet-stream` | A MIME type: the name's extension's preferred one (`UTType(filenameExtension:)`), else the default. |
| `size`        | `Int`    | no       | `0`                        | In bytes; 0 when unknown.                                                                           |

- Other keys are kept and written back after these. An entry without `id`, `name` or `path` is skipped.
- **Reading a file** (`MessageAttachment.url(inProject:)`): only a `path` of three parts, `chats`, a folder and
  a name, none empty, `.` or `..`, whose real path, the links of its existing part resolved, lies inside the
  project's `.hephaestus/` folder. Another path opens nothing. V2's own files of messages, tool results and shown
  images follow the same form.
- V3 writes them for a feedback chat's first message ([Feedback chats](#feedback-chats)), and for a message sent
  with files from the composer (`ChatSession.send(…files:)`):
  1. Checks the files (`MessageAttachment.check`): a folder is `invalid` (`Folders cannot be attached.`), a file
     over 20 MB `invalid` (`<name> is larger than 20 MB.`), all over 20 MB together `invalid` (`The attachments of
     one request exceed 20 MB.`); a message needs text or files (`invalid`, `text: write a message.`).
  2. Makes the chat when it is new: titled with the text's first line, or the first file's name without text.
  3. Copies each file into the chat's folder under its own name (`MessageAttachment.store`); a copy that fails
     removes those made (`unavailable`, `The files couldn't be stored: <reason>`).
  4. Records the user item with the text and the files as its `attachments`, and sends Claude the images among
     them ([Claude images](#claude-images)), before the text, then the text followed by one `Attached: file <stored
     path>` line per file, after the item's line ([Messages](#messages)); without text, those lines alone.
- **1.0.31 to 1.0.33** stored a feedback's files without listing them on the message. For a user item without
  `attachments`, the lines after its `Feedback context:` line that read `- Screenshot: <path>` or `- Attachment:
  <path>`, whose path is a file `<UUID>-<name>` directly in the chat's own folder, are taken as its files, in
  order, with an unknown size (`FeedbackReport.files(inMessage:chatID:root:)`). Nothing is written back.

### Stream mapping

`StreamMapper` turns each line the CLI writes (stream-json, checked against captures of Claude Code
2.1.309 in `ChatDataTests/Fixtures`) into items and events. A line that isn't a JSON object is
skipped.

| Line                                       | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|--------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `system` `init`                            | A CLI turn opens. The first of a process sets `sessionStarted` and checks `mcp_servers` for `hephaestus`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `system` `status`                          | `compacting` starts a compaction; the next `status` ends it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `system` `compact_boundary`                | The compaction line, from `compact_metadata.trigger` and `pre_tokens`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `stream_event`                             | `message_start` records the message's id and model; `content_block_start` opens block `index`; a `text_delta` (main conversation) streams text into the chat; `thinking_delta` accumulates. Others are ignored. A line's message is its `api_message_id`, else the latest `message_start` of its `parent_tool_use_id`.                                                                                                                                                                                                                                                                                                 |
| `assistant`                                | One item per block of `message.content`: `text` → `assistant` (none when empty), `thinking` → `thinking` (none when empty), `tool_use` → `toolUse`. A block takes the index of the first open block of its message with its type and no item yet, else the next index of the message.                                                                                                                                                                                                                                                                                                                                  |
| `user` with `tool_result` blocks           | One `toolResult` each: `content` as a string, or its `text` parts joined with LF, then one line of compact JSON per part that is neither text nor image.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `control_request` `can_use_tool`           | A `permissionRequest` item: the CLI asks ([Chat processes › Permissions](#permissions)). Another subtype is refused at once: `Unsupported control request: <subtype>`.                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `control_response`                         | Matched to the app's request by `request_id`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `control_cancel_request`                   | The request is cancelled: `decision` `deny`, `decidedBy` `null`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `result`                                   | Open text and thinking blocks with text become items, open calls are dropped; then a `result` item: `durationMs` = `duration_ms`, `costUSD` = `total_cost_usd`, `isError` = `is_error`, `summary` null without error, else `Stopped by the user.` for the first result after Stop, else `result` for subtype `success`, else the `errors` joined with LF, else the `subtype`. The CLI turn closes.                                                                                                                                                                                                                     |
| `command_lifecycle`                        | The state of the message whose `uuid` is `command_uuid`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `rate_limit_event`                         | The weekly usage of the Claude account, which replaces the app's ([Plan usage file](#plan-usage-file)), when `rate_limit_info.unifiedWindows.seven_day` has the numbers `utilization`, 0 or more, and `resetsAt`, in Unix seconds, and `rate_limit_info.status` is a string of one line, not empty: `utilization`, `resetsAt` (to whole seconds), `status`, then `overageStatus` and `overageDisabledReason` (absent unless a string of one line, not empty) and `isUsingOverage` (absent unless a boolean), all from `rate_limit_info`. Otherwise ignored. The five-hour window and the others aren't read, as in V2. |
| Others (`keep_alive`…)                     | Ignored.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

### Chat processes

How a chat's CLI runs (`ChatSession`, [Architecture › ChatData](architecture.md#chatdata)).

#### The CLI

The first that applies: Settings ▸ Chat's path (`claudePath`); `HEPHAESTUS_CLAUDE_PATH`; `~/.local/bin/claude`,
`/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, the first that is an executable file; `claude` in the login
shell's `PATH`. A path set in Settings or the variable that isn't an executable file is an error, and nothing
else is tried. Then `<path> --version` (30 s): the version is its output's first `[0-9]+(\.[0-9]+)+`.

| Outcome                | Status                                                                                                                          |
|------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| Not found              | `Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat.`                                                |
| Set but not executable | `<path> is not an executable file.`                                                                                             |
| `--version` fails      | `<path> --version failed: <reason>.`: `timeout`, the first line of its standard error without final periods, or `exit code <n>` |
| A version              | Available.                                                                                                                      |

The check runs once the projects and tools are loaded, and again after the path changes or **Look Again**. Then
the model probe reads the CLI's models and commands: `<path> -p --input-format stream-json --output-format
stream-json --verbose --no-session-persistence --tools "" --strict-mcp-config --mcp-config {"mcpServers":{}}
--plugin-dir <data folder>/Runtime/plugins` in `Runtime/claude-cwd/` (the [chat plugin](#chat-plugin) written
first; without it when it can't be), writes `initialize`, takes `response.models` and `response.commands` from
its answer (30 s at most), closes stdin, then SIGTERM and SIGKILL 2 s later. No message is sent: the probe makes no model request. Each model entry gives
`value`, `displayName` (default `value`), `description`, `supportedEffortLevels`, `resolvedModel`; an entry without
`value` is skipped. Until an answer, the list is the fallback: Default, Opus, Fable, Sonnet, Haiku. Every chat
process's `initialize` answer replaces the list too. A model id's name is the `displayName` of the first model
other than `default` that resolves to it, else of the model whose value it is, else the id.

**Commands** (`ClaudeCommand`): each entry of `commands` gives `name` (what follows `/`), `description`,
`argumentHint` and `builtin` (`isBuiltIn`, false when absent); an entry without a name is skipped, and an answer
without entries changes nothing. `isSynced` marks a skill the CLI syncs from the user's claude.ai account: its
description, trimmed, ends with `(claude.ai sync)`, or its name's part before `:` is a synced plugin, one of the
folders of `<CLI folder>/plugins/synced/<account>/` holding a `.claude-plugin/plugin.json` (by its `name`, else
the folder's), the CLI folder being `CLAUDE_CONFIG_DIR`, else `~/.claude`, from the app's environment. The probe's list is `ChatSession.commands`: the user's skills, their plugins'
and the app's own, outside any project. Each chat process's `initialize` answer sets the list of its chat's
project (`projectCommands`), which then adds the project's own skills; `commands(forProject:)` gives the
project's list, else the probe's. Lists stay in memory only. The composer offers the skills among them ([UI ›
Chat › Skill completion](ui/chat.md#skill-completion)).

#### Launch

A message to a chat without a live process starts one, in the project's folder, with the login shell's
environment (no `HEPHAESTUS_*`) plus `MCP_TOOL_TIMEOUT=1800000`, its standard error appended to the chat's log.
The arguments, one element each, no shell:

```
<cli> -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
  --session-id <CHAT-ID>          (or --resume <CHAT-ID> once sessionStarted)
  --model <settings.model> --effort <settings.effort>
  --permission-mode <settings.permissionMode> --allow-dangerously-skip-permissions
  --settings {"ultracode":true}          (only with Ultracode)
  --autocompact 200000 | 1000000         (only for a context window of 200K or 1M)
  --permission-prompt-tool stdio
  --disallowedTools AskUserQuestion      (AskUserQuestion,Edit,Write,NotebookEdit under Never)
  --strict-mcp-config --mcp-config <data folder>/Runtime/mcp/<CHAT-ID>.json
  --allowedTools mcp__hephaestus__<tool>,mcp__hephaestus__<tool>,…
  --plugin-dir <data folder>/Runtime/plugins
```

- No `--tools`: Claude has every one of the CLI's own tools, as in V2 (files, the shell, the web, agents,
  workflows), but those of `--disallowedTools`: the CLI's question tool, which `ask_questions` replaces, and the
  editing tools (`Edit`, `Write`, `NotebookEdit`) when Settings ▸ Chat › Edit the project's files is Never as the
  process starts ([File tools](#file-tools)). The CLI asks before a call as the chat's permission mode says; the
  app answers for the file tools, and shows a card for the others. `--strict-mcp-config` leaves it the app's
  server alone.
- `--allowedTools` lists every tool of the app's server: the CLI runs them without asking, and the app's server
  asks the user before a change, as Settings ▸ Chat says ([MCP › Permissions](mcp.md#permissions)).
- No system prompt and no hook: V3 sends Claude nothing written for it besides its tools' descriptions and the
  line of a message's item ([Decisions › What Claude reads](decisions.md#what-claude-reads)). The one plugin is
  the user's: the internal skills chats call, as the user wrote them, regenerated before each launch ([Chat
  plugin](#chat-plugin)). When it can't be written, the CLI starts without `--plugin-dir` and the chat gets a
  warning, "Skills could not be prepared: <reason>".
- The MCP configuration, mode 0600: `{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <token>"}}}}`, the token a new chat token
  ([MCP › Authentication](mcp.md#authentication)), revoked with the file when the process ends.

Then the app writes `{"type":"control_request","request_id":"hephaestus-1","request":{"subtype":"initialize"}}`
and the message. Control request ids are `hephaestus-<n>`, counting from 1 per process.

#### Messages

Each message is one line: `{"type":"user","message":{"role":"user","content":[{"type":"text","text":<text>}]},"uuid":<user item id>}`.
A message with images, a feedback chat's first one ([Feedback chats](#feedback-chats)), has one block per image
before the text block, `{"type":"image","source":{"type":"base64","media_type":"image/png","data":<base 64>}}`,
each a [Claude image](#claude-images): a message whose image comes after its text wouldn't call its skill.
`<text>` is the message, then, for the item its chip carried, a blank line and one line V3 writes:

| Item                   | Line                                                                                                                                 |
|------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| The project            | `Attached: project ORD`                                                                                                              |
| A ticket               | `Attached: ticket ORD-142 of project ORD`                                                                                            |
| A service, a request   | `Attached: service payments-api of project ORD, as seen in Staging`; `Attached: request req-8f3a of project ORD, as seen in Staging` |
| A run, a release       | `Attached: run 1288 of project ORD`; `Attached: release v1.4.0 of project ORD`                                                       |
| An operation           | `Attached: operation createOrder of project ORD`                                                                                     |
| A file (a skill's run) | `Attached: file /absolute/path`                                                                                                      |

#### Turns

A turn runs from a message written (or a CLI turn the CLI begins) until no message written is outstanding and
no CLI turn is open. Each message written is outstanding; `command_lifecycle` records its `state`, and a state
other than `queued` and `started` finishes it; a `result` closes the CLI turn and finishes the messages
`started`, or the oldest without a state. A message sent during a turn is written at once: the CLI runs it
after its current CLI turn. The turn's end writes `updated`.

| State               | When                                                                                                                                                      |
|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `starting`          | A process was started; its first `system/init` hasn't come.                                                                                               |
| `running`           | A turn runs.                                                                                                                                              |
| `waitingPermission` | A card waits: the CLI's request, or the app's.                                                                                                            |
| `waitingAnswers`    | No turn runs, and the chat's transcript, read, has questions ([Questions](#questions)) or a picker request ([Picker requests](#picker-requests)) waiting. |
| `error`             | The CLI couldn't start, didn't start in 60 s, or exited during a turn on its own. Until the next message.                                                 |
| `idle`              | Otherwise.                                                                                                                                                |

#### Permissions

- **The app's cards.** Before a change by a chat's Claude that Settings ▸ Chat sets to Ask First, the server's
  gate calls `ChatSession.requestApproval`: a `permissionRequest` item with a new lowercase UUID as request id
  and `mcp__hephaestus__<tool>` as `toolName`; the call waits for the answer.
- **The CLI's requests.** A `can_use_tool` request for a file tool is answered as [File tools](#file-tools) says:
  at once, or with a card (Accept Edits and Allow All count as Settings ▸ Chat's Always unless it is Never).
  Another (one the CLI makes on its own, such as for a tool the user's Claude Code settings deny) becomes a card
  too. The request's `permission_suggestions` stay in memory with it. Allow writes
  `{"type":"control_response","response":{"subtype":"success","request_id":<id>,"response":{"behavior":"allow","updatedInput":<input>}}}`;
  Always Allow adds `"updatedPermissions":<the suggestions>` (the plain allow without any); Don't Allow writes
  `"behavior":"deny","message":<the user's message, trimmed, or "Permission denied by the user.">`.
- **The app's cards** follow the chat's mode first: Plan Only refuses every change (`forbidden`, `The chat is in Plan
  Only: Claude plans and changes nothing.`), Don't Ask refuses what would ask (`The chat doesn't ask (Don't Ask):
  …`), Allow All runs it. Never stays a refusal. Always Allow on an app's card allows the call.
- An answer records `decision` (`allow`, `allowAlways`, `deny`) and `decidedBy`, this Mac's name; the app's own
  refusals (Stop, the end of the process, quitting) record `deny` without `decidedBy`.

#### Chat settings

The chat file's `settings` (V2's `ChatSettings`): `model`, `effort`, `permissionMode` (`ChatPermissionMode`:
`manual`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`; `manual` for an unknown value),
`ultracode` and `contextWindow` (`ChatContextWindow`: `auto`, `200k`, `1m`). A new chat starts with `manual`,
`false` and `auto`. `ChatSession.setSettings(_:_:)` checks them (`invalid`: `model: use a model of the list.`,
`permissionMode: use a mode of the list.`, `contextWindow: use auto, 200k or 1m.`), writes them, and with a live
process:

- a new model sends `set_model`; a new effort `apply_flag_settings` `{"effortLevel":<effort>}`;
- a new mode sends `set_permission_mode` `{"mode":<mode>}` (`default` for `manual`); on its success, while the mode
  is still the chat's, each card waiting that it allows is approved as if the mode had come first (every card
  under `bypassPermissions`; an `Edit` or `Write` inside the project's folder under `acceptEdits`), recorded as
  allowed by this Mac. A failure adds the warning `Claude did not accept the new permission mode now: <reason>.
  It applies the next time Claude starts.`;
- a new Ultracode sends `apply_flag_settings` `{"ultracode":<bool>}`;
- a new context window needs a new process: the app ends it (closing stdin, as when idle) once no turn runs, at
  once when none does; the next message resumes the session with the new `--autocompact`.

#### File tools

The CLI's file tools (`ClaudeFileTools`): `Read`, `Grep` and `Glob` read, `Edit`, `Write` and `NotebookEdit`
edit. Claude has the CLI's other tools too, as in V2 (the user's request, 17 November 2026); their requests always
show a card. The CLI runs a call on its own where its rules allow it (a read inside its working folder,
a tool the user's Claude Code settings allow); otherwise it sends `can_use_tool`, and the app answers with the
setting **Edit the project's files** (`chat.fileEdits` in the user defaults: `never`, `askFirst`, `always`;
`askFirst` when unset) read at that moment:

| Request                                                                                | Setting    | Answer                                                                                  |
|----------------------------------------------------------------------------------------|------------|-----------------------------------------------------------------------------------------|
| `Read`, `Grep`, `Glob` inside the project's folder                                     | Any        | `allow`, no item                                                                        |
| `Read`, `Grep`, `Glob` outside it                                                      | Any        | A `permissionRequest` item: a card                                                      |
| `Edit`, `Write`, `NotebookEdit`                                                        | `never`    | `deny`, `The user doesn't let Claude edit files from chats (Settings ▸ Chat).`, no item |
| `Edit`, `Write`, `NotebookEdit`                                                        | `askFirst` | A card                                                                                  |
| `Edit`, `Write`, `NotebookEdit` inside the project's folder, not in its `.hephaestus/` | `always`   | `allow`, no item                                                                        |
| `Edit`, `Write`, `NotebookEdit` in `.hephaestus/` or outside the project's folder      | `always`   | A card                                                                                  |

- The path is `file_path` (`Read`, `Edit`, `Write`), `notebook_path` (`NotebookEdit`) or `path` (`Grep`, `Glob`;
  the project's folder without one).
  `~` is expanded; a relative path is taken from the project's folder; `.` and `..` are removed; the symbolic links
  of the longest part that exists are resolved, in the path and in the project's folder. A path is inside when it
  is the folder or starts with the folder and `/`.
- `allow` writes `{"behavior":"allow","updatedInput":<input>}`, `deny` `{"behavior":"deny","message":<message>}`,
  as an answer to a card does ([Permissions](#permissions)).
- An item for another tool keeps its card, whatever the setting.

#### Stop, end and quit

| Event                                                                                                               | What happens                                                                                                                                                                                                                                                                  |
|---------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Stop                                                                                                                | Each card waiting is refused (the CLI's with `The user stopped Claude.`), recorded with this Mac's name; the line `Stopped by the user.`; the `interrupt` control request. Without a `result` 5 s later, SIGINT, then SIGTERM, then SIGKILL, 5 s apart, to the process group. |
| No turn for 20 min                                                                                                  | stdin closed, then SIGTERM and SIGKILL, 5 s apart. The next message starts a process with `--resume`.                                                                                                                                                                         |
| No `system/init` in 60 s                                                                                            | SIGTERM, SIGKILL 5 s later; the error line.                                                                                                                                                                                                                                   |
| The app quits                                                                                                       | A turn in progress gets its line and its cards are cancelled; SIGTERM, SIGKILL after 3 s.                                                                                                                                                                                     |
| A resumed process exits before its `system/init`, its standard error saying `No conversation found with session ID` | `sessionStarted` false, the warning line, and one launch again with `--session-id`, writing the same messages.                                                                                                                                                                |
| Any exit                                                                                                            | Open blocks finish as items; the cards still waiting are cancelled; the token and the MCP configuration go.                                                                                                                                                                   |
| `set_model`, `apply_flag_settings`                                                                                  | A model or effort change of a chat whose process runs: `{"subtype":"set_model","model":<model>}`, `{"subtype":"apply_flag_settings","settings":{"effortLevel":<effort>}}`.                                                                                                    |

### Agents

V2's workflows and agents (`ChatAgents.swift`), checked on V2's captures `stream-workflow.jsonl` with its folder,
`stream-workflow-stop.jsonl` and `stream-background-agent.jsonl` (`ChatAgentsTests`).

| Record                                        | Made when                                                                                             | `id`                 | Title                                                 |
|-----------------------------------------------|-------------------------------------------------------------------------------------------------------|----------------------|-------------------------------------------------------|
| workflow (`ChatWorkflow`)                     | `system/task_started` with `task_type` `local_workflow`                                               | the line's `task_id` | `summary`: its `description`, else `Workflow`         |
| workflow agent (`ChatAgent`, kind `workflow`) | a `workflow_agent` entry of a `task_progress` line, or a `started` entry of the run's `journal.jsonl` | `agentId`            | `label`, else `Agent`                                 |
| sub-agent (`ChatAgent`, kind `subagent`)      | a `toolUse` item `Agent` or `Task` of the CLI                                                         | the call's id        | its `description`, else `subagent_type`, else `Agent` |

- A workflow keeps `toolUseID` (its Workflow call), `runID`, `name` (`workflow_name`), `summary` (a
  `task_progress`'s new `summary` replaces it), `state`, `started`, `ended`. An agent keeps `kind`, `workflowID`,
  `title`, `phase` (`phaseTitle`, the journal's `phase`), a sub-agent's `taskID` (the CLI's id: a
  `task_started` `local_agent` line of its call, or the last `agentId: <id>` line of its call's result), `state`,
  `started`, `ended`.
- **States** (`ChatAgentState`): `running`, `completed`, `failed`, `stopped`. A workflow ends on `task_updated`
  (`patch.status` `completed`, `failed`, `killed` → stopped) or `task_notification` (`completed`, `failed`,
  `stopped`); its agents still running then stop. A workflow agent completes on its entry's `done` (or fails on
  `error`) or the journal's `result`. A sub-agent ends on the `task_notification` of its call or task, or, when
  not started in the background, on its call's result (failed when it is an error) or the turn's `result`
  (stopped); a `task_started` of its task while it has ended runs it again (SendMessage resumed it). The
  process's exit stops everything running.
- **The run's folder.** The Workflow call's result names it: "Task ID: <id>", "Run ID: <id>", "Transcript dir:
  <path>", an absolute path whose last part is the run id. The session reads it at once, then every second
  while the workflow runs, and once as it ends: the complete lines added to `journal.jsonl` and to each
  `agent-<agentId>.jsonl` since the last read. A file not there yet is read later; a line that isn't JSON is
  skipped. The app never writes there.
- **Agent transcript lines** (`AgentTranscriptLine`): `assistant` → one item per block (`text`, `thinking` not
  empty, `tool_use`), id `<message id>#<index + apiBlockIndex>`; `user` with a string (not `isMeta`) → a `user`
  item, sender `Claude`, id the line's `uuid`; `user` with blocks → a `toolResult` per `tool_result`, and a `user`
  item of its texts. `created` is the line's `timestamp` to the second. The size limits apply; an item the
  transcript has is skipped.
- **Files.** Each new record or change appends the whole record to `.hephaestus/chats/<CHAT-ID>/agents.jsonl`, V2's
  file: `{"workflow":{…}}` or `{"agent":{…}}` per line, the last of an id winning when read; a record read
  running reads stopped. A workflow agent's items go to `.hephaestus/chats/<CHAT-ID>/agents/<AGENT-ID>.jsonl`,
  in the chat transcript's format. A sub-agent's transcript isn't stored again: it is the chat's items of its
  call (its `prompt` as a `user` item `<call id>#prompt`, then every item whose `parentToolUseID` is its call or
  a call of an agent among them, with their results). The agents file is read with the chat's mentions, after
  `reload()`; a workflow agent's file when its view opens (`openAgent`).
- **Stop Workflow** writes `{"subtype":"stop_task","task_id":<id>}`; an error answer adds the warning `The workflow
  “<summary>” was not stopped: <error>.` The CLI's `task_updated` (`killed`) then stops it.
- **Resume** sends `/hephaestus-skills:resume-agent <title> (agent id <taskID>)` to the chat, for a sub-agent that
  failed or stopped and has a `taskID`.

### Background work

V2's background work: Claude starts work that goes on after its turn, a command with `Bash` and
`run_in_background`, an agent in the background, a workflow. Claude Code reports it in `system` lines, checked on
V2's capture `stream-background-bash.jsonl` (`BackgroundWorkTests`):

| `subtype`                  | Sent when                        | Read                                                                              |
|----------------------------|----------------------------------|-----------------------------------------------------------------------------------|
| `background_tasks_changed` | a background task starts or ends | `tasks`, each `task_id`: the tasks still running (`StreamOutput.backgroundTasks`) |
| `task_notification`        | a task ends                      | `task_id` (`StreamOutput.taskNotification`)                                       |

For each process (`ChatRun`): the tasks running (`backgroundTasks`), every task a `background_tasks_changed` listed
(`listedTasks`), and whether the CLI owes a turn (`notificationPending`):

1. `background_tasks_changed` replaces the tasks running.
2. A `task_notification` of a listed task, read while no CLI turn is open, makes a turn owed: the CLI then starts
   a turn on its own to give Claude the task's result.
3. A `system/init` ends the owed turn; the turn it opens makes the chat running, as any.
4. The process's exit drops both.

The process has **background work** while a task runs or a turn is owed (`hasBackgroundWork`).
`ChatSession.backgroundWork` holds those chats. It doesn't change the chat's state: after its turn, the chat is idle
(or waits for answers). While it lasts, the idle timer doesn't run; it starts when the work ends and no turn runs, and
a changed context window waits for it too. The status bar counts an idle chat with background work as running,
"Running in background" ([Navigation › Status bar](ui/navigation.md#status-bar)).

| Lines of the capture                      | Tasks       | Turn owed | State   | Background work |
|-------------------------------------------|-------------|-----------|---------|-----------------|
| 1 `system/init`                           | none        | no        | running | no              |
| 18 `background_tasks_changed` `bw1kgc2rd` | `bw1kgc2rd` | no        | running | yes             |
| 29 `result`                               | `bw1kgc2rd` | no        | idle    | yes             |
| 32 `task_notification` `bw1kgc2rd`        | `bw1kgc2rd` | yes       | idle    | yes             |
| 33 `background_tasks_changed` `[]`        | none        | yes       | idle    | yes             |
| 34 `system/init`                          | none        | no        | running | no              |
| 43 `result`                               | none        | no        | idle    | no              |

### Chat events

What the session reports for the notifications (`ChatEvent`, `ChatSession.onEvent`, in ChatNotifications.swift),
as V2's `chat.notification` events. `refreshState` computes a chat's state after each change; a change from a
state the session had already computed reports:

| Kind      | `ChatEvent.Kind` | When                                                                                                                                                                                  |
|-----------|------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| needs you | `needsYou`       | The state becomes `waitingPermission` or `waitingAnswers` from another one.                                                                                                           |
| finished  | `finished`       | The state becomes `idle` from `starting`, `running` or `waitingPermission`, and the last turn (the items after the user's last message) has no `Stopped by the user.` line or result. |

- A chat's first state (loading, a new chat) reports nothing, so a relaunch doesn't report the chats already
  waiting; nor does `error`.
- **Fields.** `chatID`, `projectID`, `title` (the chat's), `kind`, `detail` and `summaryInput`.
- **Claude's last reply of the turn**: the text of the last turn's last `assistant` item without
  `parentToolUseID`.
- **`detail`**: the reply's first line that isn't empty, trimmed and cut to 200 characters; without a reply,
  `Claude finished replying`, `Waiting for your permission` or `Waiting for your answers`.
- **`summaryInput`**, nil when there is nothing to sum up (a finished turn without a reply):
  - finished: `Claude's reply:` + `\n` + the reply;
  - a card: `Permission request:` + `\n` + `Tool: <tool name without its mcp__ prefix>` + `\n` + `Input: <input>`,
    the oldest pending request's input as JSON without indentation, keys sorted;
  - questions: `Questions:` + `\n` + one `<label>: <question>` line per question of the set waiting, in order;
  - a picker request: V2's `Symbol request:`, `Color request:`, `Sound request:`, `Shortcut request:`, `Font
    request:` or `Animation request:` + `\n` + its question.

  The part after the label is cut at 4,000 characters.
- **Summary** (`ChatSession.summary(of:)`): runs `notification-summary` ([Internal skills](#internal-skills)) on
  `summaryInput`, stopped after 30 s; at most two at once, the others waiting first in, first out. The answer is
  cleaned (`ChatEvent.cleanSummary`): each run of white space, line breaks included, becomes one space; a leading
  `Summary:` (any case) goes; quote characters (`"`, `'`, `“`, `”`, `‘`, `’`, `«`, `»`, `` ` ``) around it go,
  again and again; longer than 150 characters, it is cut at the last space at or before the 150th (at 150 without
  one). A failure, a timeout or an empty text gives `detail`.
- **Shown chats** (`showing(_:inKeyWindow:view:)`): each view showing a chat says so, and whether its window is
  the key window; `isInKeyWindow(_:)` tells the notifier, and a chat that starts to show in the key window calls
  `onOpen`, as `open(_:)` does when a window opens a chat.
- `waitingChats` (`waitingPermission`, `waitingAnswers`) and `runningChats` (`starting`, `running`) feed the Dock's
  badge and the status bar.

### Mentioned ids

The ticket and bundle ids each chat mentions, for the Mentioned In lists ([UI › Tickets › Mentioned
In](ui/tickets.md#mentioned-in)), as V2's `mentionedIDs` (`ChatMentions`, `ChatSession.mentions`):

- a `user` item: the ids its `text` shows as links, the `focus` of each of its `references` whose tool is
  `tickets`, and the `name` of each of V2's `linkedItems` of kind `ticket` or `bundle`;
- an `assistant` item without `parentToolUseID`: the ids its `text` shows as links.

A text is read with the transcript's own rules (`MarkdownItemIDs.linkedIDs(inMarkdown:)`, TextFormats): an id in
text, or a code span that is exactly an id, counts; one in a code block, inside a link, in HTML or a marker
doesn't. Every identifier counts, whether a loaded project has it or not. The other items add none.

- **Reading.** After the chats are read (`reload()`), the session reads, one transcript at a time and off the
  main actor, those of the chats not read yet, and adds their ids; a read asked for meanwhile follows it. Each
  item recorded afterwards adds its own. Ids only grow while the app runs; a chat gone drops its own.
- **Never stored**: each launch reads them again from the transcripts.
- `chats(mentioning:)` gives the loaded chats that mention an id, the latest `updated` first.

### Feedback chats

Send Feedback's chat (`ChatSession.createFeedback`, [UI › Chat › Feedback](ui/chat.md#feedback)), as V2's
`chats.createFeedback`:

1. Fails, creating nothing, for a blank comment (`invalid`, `comment: write what happened.`), an unavailable CLI
   (`unavailable`), a project that isn't loaded (`notFound`), a file over 20 MB (`invalid`, `<name> is larger
   than 20 MB.`), or the screenshot and the files over 20 MB together (`invalid`, `The attachments of one
   request exceed 20 MB.`).
2. Copies the screenshot, unless it is left out, then the added files, in order, into
   `.hephaestus/chats/<CHAT-ID>/`: `<UUID>-screenshot.png`, then `<UUID>-<name>`. A copy that fails removes the
   folder (`unavailable`, `The feedback's files couldn't be stored: <reason>`).
3. Writes the [chat file](#chat-file): kind `feedback`, `ticket` null, the title the comment's first line that
   isn't empty, at most 80 characters, the sheet's model and effort, no `origin`.
4. Sends the first message, its text below, the images among the stored files (by content type, else
   extension) before it, the screenshot first; the user item stores the text, and the stored files as its
   `attachments` ([Message files](#message-files)), the screenshot first as `screenshot.png`, each with the
   UUID of its file name as `id`, its size, and its type from its name.

```
/hephaestus-skills:report-feedback
<comment, trimmed>

Feedback context:
- <context line>…
- Screenshot: <absolute path of the stored screenshot>
- Attachment: <absolute path of a stored file>…
```

The context lines are the sheet's, in order (`App: Hephaestus V3 <version> (<build>)`, `macOS <version>`,
`Window: <name>`, `Project: <name> (<ID>)`, `Item: <item>`, the last two when there are some); the Screenshot
line only with a screenshot; one Attachment line per file, in order. Lines are separated by `\n`; the text
doesn't end with one. The CLI runs it as a call of the skill: the skill's content, then the rest of the text as
its arguments.

**Its ticket.** `create_ticket` called with this chat's token, while the chat is `feedback` with `ticket` null,
writes the ticket with `chats: [<CHAT-ID>]`, then sets the chat's `ticket` to the new id (V2's feedback link).
Later tickets aren't linked.

### Implement chats

The chats of Implement and Implement All ([UI › Tickets › Implement](ui/tickets.md#implement)) and of the tools
`implement_ticket` and `implement_bundle` ([MCP](mcp.md#implement_ticket)), as V2's `chats.implementTicket` and
`chats.implementBundle`. `Implementer` (ToolsScenes) checks the item and links the chat to it; `ChatSession.startImplementChat` makes the chat, its worktree and its first message ([Architecture](architecture.md#chatdata)).

**Checks**, in order; a failure creates nothing:

| Check                                                                             | Error                                                                                                                 |
|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| The ticket, or the bundle, is loaded                                              | `notFound`: `Ticket <ID> not found.`, `Bundle <ID> not found.`                                                        |
| A ticket isn't done                                                               | `conflict`: `<ID> is done; set another status to implement it.`                                                       |
| A ticket isn't a draft (Claude can't move a draft, [Ticket rules](#ticket-rules)) | `conflict`: `<ID> is a draft; create it to implement it.`                                                             |
| A bundle is `todo`                                                                | `conflict`: `<ID> is in progress; set it to To Do to implement it.`, `<ID> is done; set it to To Do to implement it.` |
| A bundle lists a ticket that is loaded and isn't done                             | `conflict`: `<ID> has no ticket left to implement.`                                                                   |
| The Claude CLI is available                                                       | `unavailable`, as for any message ([Chat processes](#chat-processes))                                                 |
| An orchestrated ticket chat's branch and worktree are made (below)                | `unavailable`: `Cannot create the branch and worktree of <TICKET-ID>: <reason>`                                       |

**Then:**

1. The [chat file](#chat-file): kind `ticket` with `ticket: <TICKET-ID>` and `questionsBlocked: true`, or kind
   `bundle` with `bundle: <BUNDLE-ID>`; an orchestrated ticket chat also has `orchestrator: <bundle chat id>`. Its
   title is `Implement <ID>: <title>` for a ticket, `Implement All <ID>: <title>` for a bundle, cut to 80
   characters. Its settings are the sheet's; `implement_ticket` and `implement_bundle` give a new chat's (Settings ▸
   Chat's model and effort, the other settings' defaults), except for an orchestrated ticket chat, which takes its
   orchestrator's settings as they are at the call.
2. The link, as the user (`TicketLibrary.linkChat(_:toTicket:by:)`, `startImplementation(of:chat:by:)`): the chat's
   id is appended to the ticket's `chats`; or to the bundle's `chats` with its status set to `in_progress`, in one
   write, the bundle's checks made again first. `updated` is set. A link that fails deletes the chat's file and
   fails with its error.
3. The first message, as the user's on this Mac: `/hephaestus-skills:implement-ticket <TICKET-ID>`,
   `/hephaestus-skills:implement-ticket <TICKET-ID> <BUNDLE-ID>` for an orchestrated ticket chat, or
   `/hephaestus-skills:implement-bundle <BUNDLE-ID>`. The CLI runs it as the call of the [internal
   skill](#internal-skills), the ids as its arguments.

**Orchestrated ticket chats.** `implement_ticket` called with the token of a chat of kind `bundle`, for a ticket
that chat's bundle lists, starts an orchestrated ticket chat: the calling chat is its `orchestrator`. Every other
call, and Implement, starts a ticket chat without one.

**Branch and worktree** of an orchestrated ticket chat, made before its file, V2's steps: `<branch>` is
`<BUNDLE-ID>/<TICKET-ID>`, such as `ORD-B3/ORD-142`; `<worktree>` is `<data folder>/Worktrees/<project id>/<TICKET-ID>`.
Each step is a `git` command run in the project's folder, 60 s at most:

1. `git worktree list --porcelain`: when it lists `<worktree>`, `git worktree remove --force --force <worktree>`.
2. When the folder `<worktree>` still exists, it is deleted; then `git worktree prune`.
3. When `git show-ref --verify --quiet refs/heads/<branch>` exits with 0, `git branch -D <branch>`.
4. `git worktree add -b <branch> <worktree> HEAD`: the branch starts at the project's current commit.

- Steps 1 to 3 drop what an earlier chat of the ticket left: a retry starts on a fresh branch.
- `<reason>`: `git is not available` (the tools have none); `git cannot start: <error>`; `git did not finish within
  60 seconds`; for a command that exits with another status than 0 (but `show-ref`), its standard error trimmed, or
  its standard output when the error is empty; `<path> cannot be deleted: <error>`, `<path> cannot be created:
  <error>`. A project outside a git repository fails at step 1 with git's `fatal: not a git repository…`.
- One worktree is made at a time, so calls made together never run git in the same repository at once.

**Working folder.** An orchestrated ticket chat's CLI starts in its worktree, at every launch, while its
orchestrator chat exists, it is its ticket's newest orchestrated chat (the latest `created`) and the folder exists;
otherwise in the project's folder, as every chat. For a project whose folder is a subfolder of its repository (the
nearest folder up holding `.git`), it is the same subfolder of the worktree. The file tools treat that folder as
the project's ([File tools](#file-tools)). The chat commits on its branch; merging it, and removing the worktree and
the branch, are the bundle's chat's work.

**Reports to the orchestrator.** When a chat with an `orchestrator` goes from `starting`, `running` or
`waitingPermission` to `idle` or `error`, the app sends the orchestrator chat one message, as the user's on this
Mac, which starts a turn there after the one at work and reopens it when closed:

| The turn                                                   | Message                                                                      |
|------------------------------------------------------------|------------------------------------------------------------------------------|
| was stopped with Stop                                      | `Chat of <TICKET-ID> was stopped.`                                           |
| left the chat in `error`, or its last `result` is an error | `Chat of <TICKET-ID> ended in error: <reason>`                               |
| ended otherwise                                            | `Chat of <TICKET-ID> finished its turn:`, a blank line, then the final reply |

- The turn is the items after the chat's last `user` item. The final reply is the turn's last `assistant` item
  without `parentToolUseID`, empty without one; `<reason>` is the turn's last `system` item of level `error`, else
  the last `result`'s `summary`.
- A CI chat reports the same way, with its own messages ([CI chats](#ci-chats)).
- Nothing is sent when the orchestrator chat is gone or the CLI isn't available, nor for a turn that ends waiting
  for answers (`waitingAnswers`): the turn after the answers reports.
- [Chat events](#chat-events): a chat with an `orchestrator` reports no `finished`, and its orchestrator reports
  `finished` only while none of its chats is `starting`, `running` or `waitingPermission`.

**Questions blocked.** While a chat's `questionsBlocked` is true, `ask_questions` and the six picker requests fail
with `forbidden` and `This chat implements a ticket: it asks the user nothing until the user writes in it.`, but
for one question set after a CI failure ([CI chats](#ci-chats)). The
first message the user sends with the composer (`ChatSession.send`) sets it to false, in the chat file's write
that records the message; Resume (`resume-chat`), the first message and the reports don't.

**The item's chats**, as the Tickets window lists them (`ChatSession.chats(ofTicket:)`, `chats(ofBundle:)`): a
ticket's are the loaded chats whose `ticket` is its id; a bundle's, those whose `bundle` is its id. Those whose
`orchestrator` isn't one of them come first, the latest updated first, each followed by the chats whose
`orchestrator` it is, oldest first: a bundle's chat by the ticket chats and the CI chat it started, a ticket's chat
by its CI chats. Deleting a chat leaves its id in the `chats` key, kept as
read. [Mentioned ids](#mentioned-ids) leave a ticket's or bundle's own chats out of its Mentioned In.

### CI chats

The chats of `watch_ci` ([MCP](mcp.md#watch_ci)), as V2's CI chats (the user's request, 20 November 2026): the
chat that pushed an implementation starts one to follow the GitHub Actions runs of the pushed commit, and gets its
report. `ChatSession.startCIChat` checks the call and makes the chat; `Implementer` (ToolsScenes) links it to the
ticket or bundle ([Architecture](architecture.md#chatdata)).

**Checks**, in order; a failure creates nothing:

| Check                                                                        | Error                                                                                          |
|------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| The caller is a chat's Claude, not the external token                        | `forbidden`: `Only a chat's own Claude can start a CI chat.`                                   |
| The calling chat is loaded                                                   | `notFound`: `Chat <ID> not found.`                                                             |
| It is a `ticket` or `bundle` chat without `orchestrator`                     | `forbidden`: `Only a ticket or bundle chat that no other chat started can start a CI chat.`    |
| `commit` is 40 or 64 hexadecimal characters, in any case                     | `invalid`: `commit: give the full hash of the pushed commit, 40 or 64 hexadecimal characters.` |
| The calling chat's project has a [GitHub page](#github-page), as it resolves | `conflict`: `Project <ID> has no GitHub page.`                                                 |
| The Claude CLI is available                                                  | `unavailable`, as for any message ([Chat processes](#chat-processes))                          |

**Then:**

1. The [chat file](#chat-file): kind `ci`, `orchestrator: <calling chat id>`, and the calling chat's `ticket`, or
   its `bundle`. Its title is `CI of <ID>: <the commit's first 7 characters>`, such as `CI of ORD-142: 8e7ccf3`;
   its settings are the calling chat's, as they are at the call.
2. The link, as the user (`TicketLibrary.linkChat(_:toTicket:)`, `linkChat(_:toBundle:)`): the chat's id is
   appended to the ticket's or the bundle's `chats`, once; `updated` is set. A link that fails, such as for a ticket
   or bundle that isn't loaded (`notFound`: `Ticket <ID> not found.`, `Bundle <ID> not found.`), deletes the chat's
   file and fails with its error.
3. The first message, as the user's on this Mac: `/hephaestus-skills:watch-ci <commit>`, the commit in lowercase,
   carrying the project, so that its text ends with `Attached: project <ID>` ([Messages](#messages)). The CLI runs
   it as the call of the [internal skill](#internal-skills) `watch-ci`, the rest of the text as its arguments.

- It works in the project's folder, as every chat but an orchestrated ticket chat, and has no `questionsBlocked`.
  What its Claude does is the skill's to say: as written by default, it waits with gh in its shell for every
  workflow run of the commit, then ends its turn with a reply whose first line is `CI passed.`, `CI failed.` or
  `CI not checked.` ([UI › System Prompts › CI skill](ui/system-prompts.md#ci-skill)). The app doesn't check
  what it does. Its permission prompts show in its own chat, as any chat's.
- It isn't opened in a window.

**Reports.** Each of its turns is reported to the orchestrator as an orchestrated ticket chat's is
([Implement chats](#implement-chats)), from the same items, with these messages:

| The turn                                                   | Message                                                          |
|------------------------------------------------------------|------------------------------------------------------------------|
| was stopped with Stop                                      | `CI chat was stopped.`                                           |
| left the chat in `error`, or its last `result` is an error | `CI chat ended in error: <reason>`                               |
| ended otherwise                                            | `CI chat finished its turn:`, a blank line, then the final reply |

- A report is a **CI failure** unless it is `CI chat finished its turn:` and the final reply's first line that
  isn't empty, without the white space, `*`, `_` and `#` at its ends, starts with `CI passed.` or `CI not
  checked.`. A stopped CI chat, or one that ended in error, thus reports a failure. V2's messages and rule; V2
  wanted the line alone, V3 also takes it trimmed and followed by more (default chosen at design time).
- **One question set after a failure.** When a CI failure report is sent to an orchestrator whose
  `questionsBlocked` is true, its next `ask_questions` runs despite it, so that its Claude can ask the user how to go
  on; the question set it posts uses that up. A report of a CI chat that isn't a failure, and the orchestrator's
  deletion, take it back. It is kept in memory only (`ChatSession.ciQuestionChats`), and the picker requests stay
  refused (V2's rule).

### Chat plugin

The internal skills chats call ([Internal skills](#internal-skills)), as a Claude Code plugin, which every chat's
CLI gets with `--plugin-dir <data folder>/Runtime/plugins` (V2's generated plugin, without its projects' own
skills: V3 has none):

```
<data folder>/Runtime/plugins/
  hephaestus-skills/
    .claude-plugin/plugin.json      {"name":"hephaestus-skills","version":"1.0.0"}
    skills/report-feedback/SKILL.md
```

- Written before each chat process starts (`DataFolder.writeChatPlugin`): `plugin.json` and each `SKILL.md`
  atomically, only when they differ; a folder in `skills/` of another name is removed.
- Each `SKILL.md` is the user's file (`skills/<name>/SKILL.md`) as last saved: its front matter's `name` and
  other lines, then its content, without the app's `model` and `effort` keys, so that the chat keeps its own
  model and effort.
- The skills the app runs itself (`set-ticket-title`) aren't in it. A running process keeps the plugin it
  started with.

### Claude images

An image Claude gets (`ClaudeImage` in FileStorage): a feedback chat's images, and `get_attachment`'s ([MCP ›
get_attachment](mcp.md#get_attachment)). ImageIO's thumbnail of the file, its orientation applied, at most
1568 pixels on its longest side (a smaller image keeps its size), as PNG, or as JPEG at quality 0.8 when the PNG
would be over 3,750,000 bytes. A file is an image when its content type, or else its extension, conforms to
`public.image`; one ImageIO can't read isn't sent.

### Chat loading and outside changes

`ChatSession.start`, once the projects and tools are loaded, reads the chat files of every loaded project (names
`<CHAT-ID>.yml` only; an invalid file, or one whose `id` differs from its name, is skipped), and again when the
projects change, or when a batch of file events names a `chats/` folder itself, a chat's `.yml` the session didn't
write (its content isn't what the session's `OwnWrites` recorded, or it was removed), or says events were dropped.
The lines appended to a transcript, a chat's folder (`chats/<CHAT-ID>/`) and the session's own writes of a chat's
file don't read the chats again: a chat at work writes them at each item. Transcripts aren't followed: a transcript
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

| Call        | Command                                                                                                                                                            | Timeout   |
|-------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| Runs        | `gh run list --repo=<repo> --limit=50 --json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,number,startedAt,status,updatedAt,workflowName` | 30 s      |
| A run       | `gh run view --repo=<repo> --json=<the same>,jobs -- <run id>`                                                                                                     | 30 s      |
| A job's log | `gh run view --repo=<repo> --log --job=<job id>`                                                                                                                   | 60 s      |
| Re-run      | `gh run rerun --repo=<repo> [--failed] -- <run id>`                                                                                                                | 30 s      |
| Cancel      | `gh run cancel --repo=<repo> -- <run id>`                                                                                                                          | 30 s      |
| Releases    | `gh api repos/<owner>/<name>/releases?per_page=50`, then `gh release list --repo=<repo> --limit=50 --exclude-drafts --json=tagName,isLatest` for the latest        | 30 s each |
| A file      | `gh release download --repo=<repo> --pattern=<asset> --dir=<folder> -- <tag>`                                                                                      | 30 min    |

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

| Case                       | Message                                                                                                                                |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| No GitHub page             | `Project <ID> has no GitHub page.`                                                                                                     |
| No gh                      | `Install the GitHub CLI (gh) to see runs and releases.`                                                                                |
| gh exits with 4 (no login) | `Run gh auth login in Terminal to see runs and releases.`                                                                              |
| gh fails otherwise         | `gh <command> failed: <reason>.`, the reason `timeout`, the first line of its standard error without final periods, or `exit code <n>` |
| Output not as expected     | `gh <command> returned unexpected output: <reason>.`                                                                                   |

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

| Call                  | Command                                                                                                                                                                                   |
|-----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Deployments           | `get deployments -o json`                                                                                                                                                                 |
| A Deployment's status | `get deployment/<deployment> -o json`, then `get pods --selector=<its matchLabels> -o json`                                                                                               |
| Logs                  | `logs <pod or deployment/<deployment>> --tail=<n> --timestamps` (`--all-containers` for the Deployment; `--container`, `--since=<n>s`, `--previous`)                                      |
| Events                | `get events -o json`, those whose object is the Deployment or named after it                                                                                                              |
| Restart               | `rollout restart deployment/<deployment>`                                                                                                                                                 |
| Scale                 | `scale deployment/<deployment> --replicas=<0–100>`                                                                                                                                        |
| Argo CD status        | `get applications.argoproj.io/<name> -o json`: `status.sync.status`, `status.health.status`, the revision, `status.operationState.phase`                                                  |
| Argo CD sync          | `patch applications.argoproj.io/<name> --type=merge --patch={"operation":{"initiatedBy":{"username":"Hephaestus"},"sync":{"syncStrategy":{"hook":{}}}}}`, refused while an operation runs |
| Port forward          | `port-forward <target> --address=127.0.0.1 <local>:<remote>`, waiting at most 30 s for `Forwarding from 127.0.0.1:<port> -> <remote>`                                                     |

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
  `<service>-bucket`, a bucket node, from `s3.enabled` or `…/yc-shared/s3store`.
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

| Swift name         | Key                    | Type      | Required          | Rules                                                         |
|--------------------|------------------------|-----------|-------------------|---------------------------------------------------------------|
| schema             | `schema`               | `Int`     | no                | `1`                                                           |
| id                 | `id`                   | `String`  | yes               | The folder's name.                                            |
| version, build     | `version`, `build`     | `String`  | yes               | ipsw.me's, such as `27.2.1`, `26B131`.                        |
| state              | `state`                | `String`  | yes               | `downloading`, `installing`, `needsSetup`, `ready`, `failed`. |
| failure            | `failure`              | `String?` | written as `null` | The failure's message, one line.                              |
| userName, password | `userName`, `password` | `String?` | written as `null` | The guest account, in clear: the password of a test computer. |
| created            | `created`              | date      | yes               |                                                               |

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

| Swift name              | Key                           | Type      | Required                  | Rules                                                                                                                                                               |
|-------------------------|-------------------------------|-----------|---------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| schema                  | `schema`                      | `Int`     | no                        | `1`                                                                                                                                                                 |
| id, name                | `id`, `name`                  | `String`  | yes                       | The name is one line of 1 to 100 characters, trimmed.                                                                                                               |
| imageID, version, build | `imageID`, `version`, `build` | `String`  | yes                       | The image it was made from, as it was then.                                                                                                                         |
| cores, memoryGB         | `cores`, `memoryGB`           | `Int`     | yes                       |                                                                                                                                                                     |
| diskGB                  | `diskGB`                      | `Int?`    | written as `null`         | When absent, the size of `Disk.img`.                                                                                                                                |
| growContainer           | `growContainer`               | `Bool`    | no, `false`               | True while the guest's container has to grow over a grown disk.                                                                                                     |
| startedBy               | `startedBy`                   | `String`  | no, `user`                | A machine with another value is skipped ([Storage](#storage)).                                                                                                      |
| projectID, chatID       | `projectID`, `chatID`         | `String?` | written as `null`         | Kept as read; the inspector's Project row shows `projectID`'s project.                                                                                              |
| created                 | `created`                     | date      | yes                       |                                                                                                                                                                     |
| macAddress              | `macAddress`                  | `String?` | no, written only when set | The network device's MAC address, `xx:xx:xx:xx:xx:xx`, made at the machine's creation, or at its first start when it has none, so its guest's address can be found. |

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

| Operation                | Rules                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Create (`createMachine`) | In this order: Apple silicon; the name; the image exists (`Image <id> not found.`) and is Ready (`The image is not Ready.`); `cores` 2 to this Mac's cores, `memoryGB` 4 to its memory, `diskGB` the image's disk size to 2048 (`<param>: use a number from <min> to <max>.`); fewer than 2 running. Then the folder: copies of the platform files, a clone of the disk grown to `diskGB` ([Growing a disk](#growing-a-disk)), a new MAC address, `vm.yml`; a file that can't be written deletes the folder (`The virtual machine could not be created: <reason>.`). Then it starts; a start that fails leaves it stopped. |
| Start                    | Fewer than 2 running; the machine made with its cores, memory, folder and MAC address, without a shared folder.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Stop                     | Through the agent (`/sbin/shutdown -h now` as root), waiting up to 60 seconds, else at once, as a power cut. A paused machine stops at once.                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Pause, Resume            | The framework's `pause()` and `resume()`; never stored.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Edit (`updateMachine`)   | Stopped only (`The virtual machine is running.`); the name; the ranges, `diskGB` from its current size. A larger disk grows `Disk.img` and sets `growContainer`.                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Delete                   | A running machine stops at once; the folder is deleted (`The virtual machine could not be deleted: <reason>.`). Deleting an image deletes its machines first.                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

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

| Swift name                 | Key                          | Type          | Required | Default         | Rules                                                                                                                                                                                                                                                                                                                              |
|----------------------------|------------------------------|---------------|----------|-----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| schema                     | `schema`                     | `Int`         | no       | `1`             |                                                                                                                                                                                                                                                                                                                                    |
| mcpPort                    | `mcpPort`                    | `Int`         | no       | `47830`         | The MCP server's port on 127.0.0.1: 1024–65535 (`SettingsFile.isPort`). `HEPHAESTUS_MCP_PORT` replaces it while set, without changing the file ([MCP](mcp.md#server-lifecycle)).                                                                                                                                                   |
| claudePath                 | `claudePath`                 | `String?`     | no       | absent          | The Claude CLI the chats run: an absolute path or one from `~/`; absent finds it ([Chat processes › The CLI](#the-cli)). Written only when set.                                                                                                                                                                                    |
| chatModel                  | `chatModel`                  | `String?`     | no       | absent          | The model of new chats, a CLI model value such as `opus`; absent for `default`. Written only when set.                                                                                                                                                                                                                             |
| chatEffort                 | `chatEffort`                 | `String?`     | no       | absent          | The effort of new chats (`low`, `medium`, `xhigh`, `max`); absent for `high`. Written only when set.                                                                                                                                                                                                                               |
| defaultVMCores             | `defaultVMCores`             | `Int?`        | no       | absent (2)      | New machines' cores, 2 to this Mac's ([Virtual machines › Defaults](#defaults)). Written only when not the default.                                                                                                                                                                                                                |
| defaultVMMemoryGB          | `defaultVMMemoryGB`          | `Int?`        | no       | absent (4)      | New machines' memory in GB, 4 to this Mac's.                                                                                                                                                                                                                                                                                       |
| defaultVMDiskGB            | `defaultVMDiskGB`            | `Int?`        | no       | absent (64)     | New machines' disk in GB, 32 to 2048.                                                                                                                                                                                                                                                                                              |
| newWindows                 | `newWindows`                 | `String?`     | no       | absent (`tabs`) | How the windows the app opens appear: `tabs`, as tabs of the frontmost window, or `windows`, each on its own; absent or another value reads as `tabs` (`SettingsFile.opensWindowsAsTabs`). Written when Settings ▸ General changes it ([Navigation › Settings ▸ General](ui/navigation.md#settings--general)). A V3 key.           |
| feedbackProjectID          | `feedbackProjectID`          | `String?`     | no       | absent          | The project that receives feedback chats ([Navigation › Settings ▸ General](ui/navigation.md#settings--general)); absent for none, which hides the status bar's ladybug and Help ▸ Send Feedback…. Written after `newWindows`, and removed by None. A V3 key, named as an earlier V2 setting was, which V2 no longer read.         |
| notifyNeedsYou             | `notifyNeedsYou`             | `Bool?`       | no       | absent (true)   | Whether a chat that starts to wait for the user posts a notification ([UI › Chat › Notifications](ui/chat.md#notifications)). Written, with the next two, when Settings ▸ Notifications changes a toggle ([Navigation › Settings ▸ Notifications](ui/navigation.md#settings--notifications)), after `feedbackProjectID`. V2's key. |
| notifyFinished             | `notifyFinished`             | `Bool?`       | no       | absent (true)   | Whether a turn that ends well posts a notification. V2's key.                                                                                                                                                                                                                                                                      |
| notifyAISummary            | `notifyAISummary`            | `Bool?`       | no       | absent (true)   | Whether a notification's line is written by `notification-summary` ([Internal skills](#internal-skills)); false posts the detail at once. V2's key.                                                                                                                                                                                |
| autoUpdate                 | `autoUpdate`                 | `Bool?`       | no       | absent (true)   | Whether an update downloads as soon as it is found and the app restarts to install it when idle ([UI › Updates](ui/updates.md#settings--updates)). Written, with the next key, when Settings ▸ Updates changes either, after `notifyAISummary`. V2's key.                                                                          |
| updateCheckIntervalMinutes | `updateCheckIntervalMinutes` | `Int?`        | no       | absent (30)     | Minutes between two update checks, 5–1440: a value outside reads as the nearest bound (`SettingsFile.updateCheckInterval`). V2's key.                                                                                                                                                                                              |
| unknownKeys                | —                            | `YAMLMapping` | —        | empty           | [Unknown keys](#unknown-keys).                                                                                                                                                                                                                                                                                                     |

```yaml
schema: 1
mcpPort: 47830
```

## Secrets file

`<data folder>/secrets.json`, mode 0600: one JSON object, written with two-space indentation, keys sorted,
slashes not escaped, and a final line break. Not in the Keychain, so that a rebuilt app doesn't ask for
access.

| Key                | Value                                                                                                                 |
|--------------------|-----------------------------------------------------------------------------------------------------------------------|
| `schema`           | `1`                                                                                                                   |
| `mcpExternalToken` | The MCP server's external token: 64 lowercase hexadecimal characters ([MCP › Authentication](mcp.md#authentication)). |

- `DataFolder.externalToken(make:)` reads the token; when the file is missing, isn't a JSON object, or holds no
  valid token, it makes one and writes it, the file's other keys kept. `replaceExternalToken(with:)` writes a
  new one the same way. The mode is set to 0600 after each write.

## Internal skills

The app's own Claude skills, whose list and names the code defines (`InternalSkill.all` in ChatData) and whose
content the user writes in [System Prompts](ui/system-prompts.md). A V3 addition.

- **Names**: Claude's skill name format, 1 to 64 characters of lowercase ASCII letters, digits and hyphens, not
  starting or ending with a hyphen, without two in a row (`InternalSkill.isValidName`). Today:
  `set-ticket-title` and `notification-summary`, which the app runs itself ([Running a skill](#internal-skills),
  below, and [Chat events](#chat-events)), and
  `report-feedback`, `resume-chat`, `resume-agent`, `implement-ticket`, `implement-bundle` and `watch-ci`, which chats call (`isCalledFromChats`), through the [chat plugin](#chat-plugin):
  a feedback chat's first message calls `report-feedback` ([Feedback chats](#feedback-chats)), Resume calls
  `resume-chat` ([Closing and deleting chats](#closing-and-deleting-chats)), an agent's Resume `resume-agent` ([Agents](#agents)),
  Implement `implement-ticket` and Implement All `implement-bundle` ([Implement chats](#implement-chats)), a CI chat's first message `watch-ci` ([CI chats](#ci-chats)). The first two are empty by default;
  `resume-chat`, `resume-agent`, `notification-summary`, `implement-ticket`, `implement-bundle` and `watch-ci` hold V3's own text, which the user's saved file replaces. Every text the app has Claude act on
  is an internal skill, never written in the code (the user's rule, 17 November 2026).
- **File**: `<data folder>/skills/<name>/SKILL.md`, Claude's skill layout. Written atomically by
  `DataFolder.writeSkill(_:of:)`, its folder made when missing: a front matter with `name` (the code's),
  `model` and `effort`, then the other front matter lines read, in their order; then the content exactly as
  typed (no line break added):

```text
---
name: set-ticket-title
model: haiku
effort: low
---
<content>
```

- **`model`**: what the CLI's `--model` takes (`default`, `haiku`, `opus`, a model id); **`effort`**: `low`,
  `medium`, `high`, `xhigh` or `max`. They are what the app uses when it runs the skill itself; a chat that calls
  the skill keeps its own. Each skill's defaults come from the code (`InternalSkill.defaults`): `set-ticket-title`
  and `notification-summary` are `haiku` and `low`; a skill without its own is `default` and `high`, as a new chat.
- **Reading** (`DataFolder.readSkill(_:)`): the front matter is the lines between a first `---` line and the
  next. `name` is ignored (the code's name stands); `model` with a value, and `effort` with one of the five levels,
  replace the defaults, and any other value of theirs leaves the default; every other line is kept as written
  (`InternalSkillValues.otherLines`) and written back. The content is the text after the closing `---` line; a
  file without front matter is all content, with the default model and effort; without a file, or one that can't
  be read as UTF-8, the skill's defaults. The front matter has no `description` of the app's: the app runs these
  skills itself rather than handing them to the CLI as skills (default chosen at design time).
- **Running a skill** (`ChatSession.run(_:input:attaching:)`, `InternalSkillRun`): the CLI found for the chats,
  in `Runtime/claude-cwd` (empty), with the login shell's environment, as

```text
claude -p --output-format json --no-session-persistence --model <model> --effort <effort> --tools "" \
  --strict-mcp-config --mcp-config <data folder>/Runtime/mcp/skill-<UUID>.json \
  --allowedTools mcp__hephaestus__<tool>,… [--system-prompt <content>]
```

  `--system-prompt` only while the content isn't blank; stopped after 2 minutes, or the time the caller gives
  (30 s for `notification-summary`).
- **MCP access** (the user's request): every run gets the app's MCP server, as a chat does. Its configuration
  file is a chat's ([Chat processes](#chat-processes)), with a token made for the run
  (`MCPTokens.issue(forSkill:)`), written mode 0600 before the run and deleted after it; the token ends with the
  run. The token's caller is `MCPCaller.internalSkill(<name>)`: the server lets it read and nothing else, and not
  open windows ([MCP › Permissions](mcp.md#permissions)), whatever Settings ▸ Chat says. The CLI's own tools stay
  off.
- **The message**, on standard input, is the input, then one `Attached:` line per item the run links, as a
  chat's message carries the item of its chip ([Messages](#messages)); the lines alone when the input is blank.
  `set-ticket-title` (the user's request: Claude reads the whole ticket, not its description alone):
  - an untitled ticket: `Attached: ticket HEPH-3 of project HEPH` alone;
  - the editor's **Generate Title**: the same line, after the description being edited while it differs from
    the saved one;
  - New Ticket's, before the ticket exists: the description, without a line.

  Claude reads the ticket with `get_ticket` (title, status, priority, labels, dates, description, comments,
  links, history, attachments' paths) and its files with `get_attachment` ([MCP ›
  get_attachment](mcp.md#get_attachment)).
  The answer is the JSON's `result` when `subtype` is `success` and `is_error` isn't true; otherwise the run fails
  with the `result`, standard error or standard output, in that order of availability. Before the CLI is checked,
  or without one, the run fails at once and starts nothing.

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

| Case                         | Message                                                                           |
|------------------------------|-----------------------------------------------------------------------------------|
| `identifierFormat`           | `identifier: use 2 to 8 letters A–Z.`                                             |
| `identifierInUse(id)`        | `identifier: <id> is already used by another project.`                            |
| `nameLength(field:)`         | `<field>: use 1 to 100 characters on one line.`                                   |
| `relativePath(field:)`       | `<field>: use a relative path with / separators and no empty, . or .. component.` |
| `url(field:)`                | `<field>: use an absolute http or https URL.`                                     |
| `port(field:)`               | `<field>: use a port from 1 to 65535.`                                            |
| `singleLine(field:)`         | `<field>: use one line.`                                                          |
| `jaeger(field:)`             | `<field>: use a Jaeger as <namespace>/<name>.`                                    |
| `argoCDApplication(field:)`  | `<field>: use an Argo CD application as <name> or <namespace>/<name>.`            |
| `kubeconfig(field:)`         | `<field>: use a kubeconfig file as an absolute path or a path starting with ~/.`  |
| `githubPage`                 | `githubPage: use a page of the form https://github.com/<owner>/<name>.`           |
| `duplicateEnvironment(name)` | `An environment named “<name>” already exists.`                                   |

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
