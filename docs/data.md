# Data

Hephaestus V3 keeps its data in plain files, in HephaestusV2's format: each project's `.hephaestus/` folder,
committed with the project, and the app's data folder, which belongs to this Mac. V3 replaces V2 and reads
the same project folders, so this page is V2's format (V2's `docs/data-model.md`) as V3 reads and writes it,
plus V3's additions, each marked **V3 addition**. A file V3 writes with an addition may be refused by V2.

This page is the contract for the files, precise enough to rebuild their code from: where each file lives,
its keys in order, its types, defaults and rules, how files are read and written, and how V3 meets HephaestusV2's
data on its first launch. The code is in the data targets of `HephaestusV3Kit` ([Architecture › The data
targets](architecture.md#the-data-targets)): `FileStorage` reads and writes, `ProjectData` knows the files.

V3 brings V2's features over one at a time ([Future improvements](future-improvements.md) lists those that
come later). A file arrives on this page with the feature that reads it; until then V3 never opens it, and
a project's other files stay as V2 left them.

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
| Chat transcript | `<project>/.hephaestus/chats/<CHAT-ID>.jsonl` | `ChatItem` on each line | Chat |
| Chat MCP configuration | `<data folder>/Runtime/mcp/<CHAT-ID>.json` | — (JSON) | Chat |
| Chat log | `<data folder>/Logs/claude-<CHAT-ID>.log` | — (text) | Chat |

`<data folder>` is the App Group container, or the folder `HEPHAESTUS_DATA_DIR` names ([Data
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
  can't be plain, such as one starting with `#`. These rules make V3's output of a file V2 wrote byte for
  byte the file V2 wrote.
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
tickets (`ORD-142`). A name suggests one: its first four ASCII letters, accents removed, uppercased; nothing
when the name has fewer than two (`ProjectRules.suggestedIdentifier(fromName:)`).

## Data folder

The files that belong to this Mac rather than to a project.

- **Location**: the App Group container, `~/Library/Group Containers/group.fr.azavech.hephaestusv3/`
  (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`), as the workspace rule wants an app's
  data in its App Group. The environment variable `HEPHAESTUS_DATA_DIR`, set to an absolute path, names
  another folder for development; a relative value is ignored. A build without the App Group entitlement has
  no data folder (`DataFolder.resolve()` returns nil).
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
| `Logs/claude-<CHAT-ID>.log` | A chat's CLI log: a line per launch, then the CLI's standard error; emptied at a launch once over 10 MB. |

## Import from HephaestusV2

V3 replaces V2 and works on the same project folders. On its first launch it brings over what V2 kept on
this Mac and nothing else: the list of top-level projects and the environment chosen for each service.

- **When**: when the data folder has no `registry.yml`. The import then writes one, even when there is
  nothing to import, so that it runs once: a list the user empties later never brings V2's projects back.
  Deleting `registry.yml` by hand runs it again.
- **From**: V2's data folder, `~/Library/Application Support/HephaestusV2/`. A missing or invalid V2
  `registry.yml` imports no project.
- **The list**: V2's `projects` in their order, without:
  - entries that aren't absolute paths, and entries already taken;
  - V2's own project, the folder whose `.hephaestus/project.yml` has the identifier `HEPH` (the
    HephaestusV2 repository, which V3 doesn't carry: default chosen at design time). A folder whose project
    file can't be read is kept: it shows as unavailable.
- **The choices**: V2's `current-environments.yml`, without `HEPH`'s entry, written when it holds one or more
  choices.
- **Order of the writes**: `current-environments.yml`, then `registry.yml`, the sign that the import ran.
- V2's files are only read. Sub projects need no import: their parents' project files list them.
- `V2Import.runIfNeeded(into:from:ownWrites:)` returns what it did (`imported`, `skippedV2Project`,
  `skippedInvalid`, `foundV2List`, `currentEnvironments`), or nil when it had already run.

Defaults chosen at design time: the import's trigger, its content, and the skipping of `HEPH`.

## Project folder

```
<project>/
  .hephaestus/
    project.yml                       ProjectFile
    .gitignore                        the line "chats/"
    ticket/<TICKET-ID>.yml            TicketFile
    bundle/<BUNDLE-ID>.yml            BundleFile
    attachments/<TICKET-ID>/          the files of a ticket and its comments
    chats/                            chats (not read yet; git-ignored)
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
page, sub projects and environments. Swift type `ProjectFile`. The table is V2's, in its order; the keys
marked **kept** are V2's keys that V3 doesn't use yet ([Unknown keys](#unknown-keys)): `webTabs`, `skills`,
`chatDefaults`, `deletedChats`, `commentAnswers`.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | [Keys and values](#keys-and-values). |
| id | `id` | `String` | yes | — | The project identifier ([Ids](#ids)). Set at creation, never changed. Read rule: `id: "<id>" is not a valid project identifier`. |
| name | `name` | `String` | yes | — | One line, 1–100 characters. Names need not be unique. |
| created | `created` | `Date` | yes | — | When the project was created. Never changed. |
| type | `type` | `ProjectKind` | no | `none` | [Project kind](#project-kind). |
| color | `color` | `String?` | no | `null` | `#` and six hex digits, uppercased when read, or **V3 addition** the name of a tint ([Project color](#project-color)). Any other value makes the file invalid (`color: "<text>" is not a color of the form #RRGGBB, nor a tint`). Left out of the file when there is none. |
| icon | `icon` | `String?` | no | `null` | An SF Symbol name, such as `hammer`. Read trimmed, an empty value being none. Left out of the file when there is none. |
| nextTicketNumber | `nextTicketNumber` | `Int` | no | `1` | The first number tried for the next ticket. |
| nextBundleNumber | `nextBundleNumber` | `Int` | no | `1` | The first number tried for the next bundle. |
| docsPath | `docsPath` | `String` | no | `docs` | Relative path of the documentation folder, which may be missing. |
| githubPage | `githubPage` | `String?` | no | `null` | The page typed in the GitHub page field, `https://github.com/<owner>/<name>`: read trimmed and without a trailing `/`; any other value makes the file invalid ([GitHub page](#github-page)). Left out of the file when there is none. |
| useParentSettings | `useParentSettings` | `Bool` | no | `true` | Whether a sub project uses its parent's settings: the parent's GitHub page and, for a service, its environments. No effect for a top-level project. |
| subprojects | `subprojects` | `[String]` | no | `[]` | Relative paths of the direct sub projects, in the order they were added, each once. Each names a folder inside this project's folder that holds `.hephaestus/project.yml`. An entry whose folder or file is missing or invalid is kept. |
| — | `webTabs` | kept | no | absent | V2's web tabs. |
| — | `skills` | kept | no | absent | V2's enabled skills. |
| — | `chatDefaults` | kept | no | absent | V2's settings of new chats. |
| graphEnabled | `graphEnabled` | `Bool` | no | `false` | Whether the service's graph is enabled. Left out of the file while `false`. |
| environments | `environments` | `[EnvironmentEntry]` | no | `[]` | The environments of a service, in the order they were added; names unique, letter case included ([Project environment](#project-environment)). Kept when the type changes. |
| environmentOverrides | `environmentOverrides` | `[String: EnvironmentOverride]` | no | `{}` | A sub project's changes to the environments it inherits, by environment name, written in Unicode code point order ([Environment override](#environment-override)). A change for a name no inherited environment has is kept and ignored. |
| dashboardWidgets | `dashboardWidgets` | `[DashboardWidgetEntry]?` | no | `null` | The widgets of the project's [Dashboard](ui/dashboard.md), in their order ([Dashboard widget](#dashboard-widget)). `null` shows the default list and `[]` no widget. Left out of the file while the project has no stored list. |
| dashboardGraphWindow | `dashboardGraphWindow` | `DashboardGraphWindow?` | no | `null` | The time window of the Dashboard's service widgets: `fiveMinutes`, `hour`, `day` or `week`; `null` is `hour`. Any other value makes the file invalid. Left out of the file while `null`. V3 has no `week` window yet: a stored `week` is kept, and the Dashboard shows the last hour. |
| — | `deletedChats` | kept | no | absent | V2's costs of deleted chats. |
| — | `commentAnswers` | kept | no | absent | V2's costs of comment answers. |
| keptV2Keys | — | `YAMLMapping` | — | empty | The kept keys present in the file, as read. |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

A `commands` key, which old V2 versions wrote, is an unknown key.

### Project kind

Swift type `ProjectKind`, key `type`: a string enumeration. Any other value makes the file invalid.

| Value | V2's name | V3's name |
| --- | --- | --- |
| `none` | None | Other |
| `goService` | Go service | Service |
| `swiftApplication` | Swift application | App |
| `library` | — | Library. **V3 addition.** |

### Project color

V2 stores a color as `#RRGGBB`. V3's projects take one of AZDesign's semantic colors, a tint
(ToolsFoundation's `ProjectTint`), and V3 stores the tint's name. **V3 addition.** The names are
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
its position and size on the Dashboard's grid and its settings ([UI › Dashboard](ui/dashboard.md)). V2's format;
the Dashboard changes the list through [Update](#changes) and `ProjectChange.dashboardWidgets`.

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| id | `id` | `UUID` | yes | — | Unique within the list. |
| kind | `kind` | `Kind` | yes | — | `project`, `tickets`, `recentChats`, `cost`, `instances`, `serviceGraph`, `busiestCalls`, `failedRequests`, `requestsPerMinute`, or **V3 addition** `recentBuilds`. Any other value makes the file invalid. |
| title | `title` | `String` | no | `""` | The Title setting: one line, at most 100 characters, trimmed; empty means the title of the kind. |
| column | `column` | `Int?` | no | `null` | The first column the widget covers, 0–23. |
| row | `row` | `Int?` | no | `null` | The first row it covers, from 0. |
| width | `width` | `Int?` | no | `null` | The columns it covers, 1–24; `column` + `width` is at most 24. |
| height | `height` | `Int?` | no | `null` | The rows it covers, from 1. |
| fields | `fields` | `[Field]` | no | all four | `project`: the fields shown, among `name`, `identifier`, `type` and `folder`. At least one, each once. |
| statuses | `statuses` | `[Status]` | no | V2's four | `tickets`: the counts shown, among `todo`, `in_progress`, `review`, `done` and **V3 addition** `draft`. At least one, each once. The default is V2's four; V3 writes the list a widget it adds starts with: all five. |
| includeSubprojects | `includeSubprojects` | `Bool` | no | `true` | `tickets` and `cost`: whether the counts or the total cover the loaded sub projects. |
| chatCount | `chatCount` | `Int` | no | `5` | `recentChats` (V2's): the most chats listed, 1–20. |
| chatKinds | `chatKinds` | `[ChatKind]` | no | all four | `recentChats` (V2's): `project`, `ticket`, `bundle`, `feedback`. At least one, each once. |
| count | `count` | `Int` | no | `5` | `busiestCalls`, `failedRequests` and **V3 addition** `recentBuilds`: the most rows listed, 1–20. |
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
- **Write rules**, checked on each widget the list adds or changes, in order (V2's
  `DashboardWidget.normalized`); a widget equal to a stored one is written back as it is, as many times as the
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
  (`DashboardWidgetEntry.defaultID`); V3's default list differs from V2's ([UI › Dashboard › Default list](ui/dashboard.md#default-list)).
- `recentChats` and `cost` are V2's: V3 keeps them, with their settings, and never shows them.

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
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). V2's old `context` key is one: kubectl always uses the kubeconfig file's current context. |

- `url` and the five Kubernetes keys are single lines, read and written trimmed, an empty value being `null`.
- The **base URL** is `url` with its port replaced by `port` when set, without a trailing `/`; none without
  `url` (`EnvironmentEntry.baseURL`).

### Environment override

Swift type `EnvironmentOverride`, one value of `environmentOverrides`, under the name of the environment it
changes. A key with a value replaces the parent's; `null` keeps the parent's, so a change can't remove a
parent's value.

| Swift name | Key | Type | Default | Rules |
| --- | --- | --- | --- | --- |
| url | `url` | `String?` | `null` | As `EnvironmentEntry.url`. |
| port | `port` | `Int?` | `null` | 1–65535. |
| allowInvalidCertificates | `allowInvalidCertificates` | `Bool?` | `null` | Stored only while it differs from the parent's. |
| deployment | `deployment` | `String?` | `null` | |
| jaeger | `jaeger` | `String?` | `null` | `<namespace>/<name>`. |
| argoCDApplication | `argoCDApplication` | `String?` | `null` | `<name>` or `<namespace>/<name>`. |
| unknownKeys | — | `YAMLMapping` | empty | [Unknown keys](#unknown-keys). |

The four string keys are read and written trimmed, an empty value being `null`. Names are compared with the
inherited environments' exactly, letter case included. `applied(to:)` gives the parent's environment with the
values the change sets; `isEmpty` is true when it sets none.

### Examples

The test fixtures `HephaestusV3Kit/Tests/ProjectDataTests/Fixtures/project-*.yml` are V2's four examples,
copied from V2's `docs/data-model.md`. The complete one, as V2 wrote it, which V3 writes back byte for byte:

```yaml
schema: 1
id: HEPH
name: Hephaestus V2
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
useParentSettings: true
subprojects: []
environments: []
environmentOverrides: {}
```

A Go service with two environments (`project-service.yml`), and a sub project of it that uses its parent's
settings, changes the inherited `local` and `staging`, and adds `replay` (`project-subproject.yml`):

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
- /Users/example/Developer/HephaestusV2
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
2. The import from V2 runs, once ([Import from HephaestusV2](#import-from-hephaestusv2)).
3. `registry.yml` is read; a missing one is created empty, an invalid one set aside as `registry.yml.invalid`
   and recreated empty. `current-environments.yml` is read; a missing one gives no choice, an invalid one is
   set aside and gives no choice.
4. The projects load: the registry's entries in order, each followed by its sub projects, depth first, in
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
5. The files are watched ([Outside changes](#outside-changes)).
6. Then, without holding the windows: the login shell's environment is captured, the tools are looked up,
   and the `origin` of each loaded folder is read ([GitHub page](#github-page)).

Invalid project files are never renamed or rewritten at load: they belong to the project's repository.

## Changes

Every change goes through `ProjectLibrary`, one at a time, and gives a new snapshot. Files are written with
[Atomic writes](#atomic-writes), a referenced file before the file that refers to it.

| Change | Rules | Order of the writes |
| --- | --- | --- |
| **Create** (`NewProject`) | Name: one line, 1–100 characters, trimmed. Identifier: uppercased, 2–8 letters A–Z, used by no loaded project. With a parent: the folder is strictly inside the parent's folder (`Choose a folder inside “<parent name>”.`), checked before anything is written. The folder is created when missing and `createsFolder` is set; otherwise it must exist. A folder that already holds a project is refused: open it instead. The new file has `created` = now, the name, the identifier and the type; every other key takes its default. | 1. the project file and `.gitignore` 2. the parent's `subprojects` (the given parent, else the innermost loaded project whose folder holds it), or the registry |
| **Open** (a folder) | A folder already loaded gives its project. Otherwise it must hold a valid project file whose identifier no loaded project uses. Registry entries that its file lists as its descendants, at any depth, leave the registry: they load under it. | 1. `.gitignore` 2. the innermost loaded project's `subprojects`, or the registry |
| **Update** (`ProjectChange`) | Only the values the change sets: name; type; color (a tint, or `#RRGGBB` uppercased, or none); icon (trimmed, none when empty); docs folder (a relative path, not `.hephaestus` or inside it); GitHub page (validated, none when empty); Use parent settings; graph; the whole list of the project's own environments; all its changes to inherited environments; the whole list of Dashboard widgets ([Dashboard widget](#dashboard-widget) › Write rules); the Dashboard's time window. An environment or a change equal to a stored one is written back as it is, even when a hand edit made it break a rule (each stored environment keeps at most one equal environment: a copy is checked); any other is checked ([Validation](#validation)), its names trimmed, a change that sets nothing dropped. An own environment can't take a name another environment has, inherited ones included. | the project file, then `current-environments.yml` when a choice follows a rename or is forgotten |
| **Remove** | The project and its loaded sub projects leave the app: its entry leaves the parent's `subprojects` or the registry, and their chosen environments are forgotten. No file of theirs changes. | 1. the parent's project file, or the registry 2. `current-environments.yml` |
| **Choose the current environment** | One of the project's environments as they apply. | `current-environments.yml` |

## Resolution

What a project's settings are once inheritance applies (`ResolvedSettings`):

- **Environments.** A project that isn't a service (`goService`) has none. A sub project that uses its
  parent's settings first has its parent's environments, as the parent resolves them (so also those the
  parent inherits), each with the sub project's change of its name applied: the URL, port, certificate
  setting, deployment, Jaeger and Argo CD application it sets replace the parent's; the name, namespace and
  kubeconfig file stay the parent's. Then come its own environments, in order, except those whose name an
  inherited environment has: they stay in the file, left out. A change for a name no inherited environment
  has is kept and ignored. A top-level project, and a sub project that doesn't use its parent's settings,
  has only its own. `inheritedEnvironments` are the parent's, without the changes.
- **Current environment.** The environment chosen in `current-environments.yml` while the project has it;
  otherwise the first; none without environments. After a change, a chosen environment that the change
  renamed (an environment of the list whose name changed at the same place, the list keeping its length)
  stays chosen under its new name, in the project and in the sub projects that inherit it; one a project no
  longer has is forgotten, so that a later environment of that name doesn't become current again. A rename
  made in `project.yml` outside the app counts as a removal.
- **GitHub page.** A sub project that uses its parent's settings has its parent's page, which may come from
  the parent's parent. Otherwise the typed `githubPage`; otherwise the page of the project's `origin` remote
  ([GitHub page](#github-page)), read with `git config --get remote.origin.url` in its folder, and for an SSH
  host alias with `ssh -G <alias>`. Until the origins are read, and without git, there is no origin page;
  without ssh, an alias stays unresolved. `originGithubPage` is the project's own origin page, the field's
  placeholder.
- **Graph.** Never for a project that isn't a service; the parent's, as the parent resolves it, while a sub
  project uses its parent's settings; otherwise its own `graphEnabled`.

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
| `status` | `TicketFileStatus` | no | `todo` | `draft` (**V3 addition**), `todo`, `in_progress`, `review`, `done` ([Ticket rules](#ticket-rules)). |
| `created` | date | yes | — | Never changed. |
| `updated` | date | no | `created` | Set to now by every write of the file by V3. |
| `createdBy` | `user` or `claude` | no | `user` | Who created the ticket. |
| `description` | `String` | no | `""` | Markdown, line breaks LF. |
| `attachments` | `[AttachmentEntry]` | no | `[]` | The ticket's own files, in the order added ([Attachments](#attachments)). |
| `comments` | `[CommentEntry]` | no | `[]` | Oldest first; ids unique within the ticket. |
| `chats` | `[String]` | no | `[]` | The chats linked to the ticket, uppercase UUIDs; kept as read until Chat comes over. |
| `links` | `[TicketLinkEntry]` | no | `[]` | The links this ticket declares, in the order given ([Link rules](#link-rules)). |
| `history` | `[HistoryEntry]` | no | one creation entry | Oldest first, only appended to. A file without history reads with one `created` entry made from `created` and `createdBy`, `to: todo`, without device or chat. |
| `priority` | `low`, `medium`, `high`, `urgent` | no | none | **V3 addition**, written after `history` only when set. |
| `labels` | `[String]` | no | `[]` | **V3 addition**, written after `history` (and `priority`) only when not empty; trimmed, empty ones dropped, each once. |

V2's runtime-only keys `inverseLinks` (on a ticket) and `answer` (on a comment) are ignored when read and never
written. Every other unknown key is kept ([Unknown keys](#unknown-keys)).

**Comment** (`CommentEntry`): `id` (UUID, required), `author` (`user` or `claude`, required), `created` (date,
required), `updated` (date or `null`, when the text was last edited), `text` (Markdown, default `""`),
`attachments` (`[AttachmentEntry]`), `model` and `effort` (strings or `null`: set by V2 for comments Claude
added from a chat; kept as read). A comment has text that isn't empty once trimmed, at least one attachment,
or both.

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
| `author` | `user`, `claude` or `automatic` (V2's Haiku naming; V3 writes `user` and `claude` only). |
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
without a title takes its tickets' titles joined with `, `, cut to 60 characters and trimmed. (V2 then had
Haiku name them; V3 keeps the provisional title, which the user or Claude may change.)

**Descriptions.** Free Markdown, from the user and from Claude alike. V2 made Claude's descriptions follow a
six-heading template; V3 drops it with the rest of V2's prompts ([Decisions › V2's prompts](decisions.md#v2s-prompts)).

**Status.** Statuses in order: Draft (**V3 addition**), To Do, In Progress, In Review, Done. A ticket starts
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
files are V2's: the metadata file and the transcript, in the project's `.hephaestus/chats/`, which
`.hephaestus/.gitignore` keeps out of git (the first chat of a project adds the line `chats/` when it is
missing). V3 reads V2's chats of every kind and writes its own in the same format, with two V3 additions: the
`origin` of a chat and the `references` of a message. `<CHAT-ID>` is an uppercase UUID, also the CLI's session
id. Names in `chats/` that aren't `<CHAT-ID>.yml` or `<CHAT-ID>.jsonl` are ignored: V2's per-chat folders
(attachments, agents) stay as they are.

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
| orchestratorChatID | `orchestrator` | `String?` | no | absent | V2's orchestrated chats. Written only when set. |
| imageID | `image` | `String?` | no | absent | V2's Auto Setup chats. Written only when set. |
| created | `created` | `Date` | yes | — | Never changed. |
| updated | `updated` | `Date` | no | `created` | Set by a message sent, a turn's end, a rename, a settings change. The Chat window lists chats by it, the latest first. |
| settings | `settings` | `ChatSettings` | no | defaults | [Chat settings](#chat-settings). |
| sessionStarted | `sessionStarted` | `Bool` | no | `false` | True once the CLI has started the session (its first `system/init`): later launches resume it. |
| closed | `closed` | `Bool` | no | `false` | V2's closed chats. A message sent sets it back to `false`. |
| questionsBlocked | `questionsBlocked` | `Bool` | no | `false` | V2's implement chats. Written only when `true`. |
| origin | `origin` | `String?` | no | absent | **V3 addition.** The tool whose chat panel started the chat, a `ToolKind` value such as `tickets`; absent for a chat of the Chat window and for V2's chats. Written only when set. |
| unknownKeys | — | `YAMLMapping` | — | empty | Kept and written after the known keys, V2's `contextUsage` among them ([Unknown keys](#unknown-keys)). V2's runtime keys (`projectID`, `state`, `backgroundWork`, `compactingSince`, `costUSD`, `mentionedIDs`) are ignored when read and never written. |

A V2 chat file is written back byte for byte. Example, a chat V3 started from the Tickets window's panel:

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

V2's rules; a file that breaks them is invalid and isn't listed:

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
empty, no white space), `effort` (`low`, `medium`, `high`, `xhigh` or `max`, default `high`), then V2's
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
| `user` | `text` (the message as written, without what V3 adds for Claude), `attachments` (V2's files, kept), `sender` (the Mac's name), `linkedItems` (V2's, kept), `references` (**V3 addition**: `[{tool, project, focus, title, environment}]`, the item the message's chip carried; `tool` is a `ToolKind` value or `project`) | a new uppercase UUID, also the message's `uuid` for the CLI |
| `assistant` | `text`, `messageID`, `parentToolUseID`, `model` (the CLI's model id), `effort` | `<message id>#<block index>` |
| `thinking` | `text`, `parentToolUseID` (kept; not shown) | `<message id>#<block index>` |
| `toolUse` | `toolUseID`, `name` (without `mcp__<server>__`), `server` (`hephaestus` for the app's tools, `null` for the CLI's), `input`, `parentToolUseID` | `<message id>#<block index>` |
| `toolResult` | `toolUseID`, `text`, `isError`, `images` (V2's, kept) | `<tool use id>#result` |
| `permissionRequest` | `requestID`, `toolName` (the CLI's name, `mcp__hephaestus__add_comment`), `input`, `reason`, `decision` (`allow`, `allowAlways`, `deny`; `null` while it waits), `decidedBy` (the Mac whose user answered; `null` while it waits and when the app cancelled it) | `perm-<request id>` |
| `system` | `text` (in English, as V2 wrote them), `level` (`info`, `warning`, `error`) | a new uppercase UUID |
| `result` | `durationMs`, `costUSD` (kept; not shown), `isError`, `summary` | a new uppercase UUID |

V2's other items, `questions`, `symbol`, `color`, `sound`, `shortcut`, `font`, `animation` and `images`, belong
to features V3 doesn't bring over: they are skipped when a transcript is read, and stay in the file. A string
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

`StreamMapper` turns each line the CLI writes (stream-json, checked against V2's captures of Claude Code
2.1.309, copied into `ChatDataTests/Fixtures`) into items and events. A line that isn't a JSON object is
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
`value` is skipped. Until an answer, the list is V2's fallback: Default, Opus, Fable, Sonnet, Haiku. Every chat
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
  descriptions and the line of a message's item ([Decisions › V2's prompts](decisions.md#v2s-prompts)).
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

## Settings file

`<data folder>/settings.yml`: the app's settings. V3's own file: V2's `settings.yml` isn't imported. Swift
type `SettingsFile`. A missing file gives the defaults; an invalid one is set aside as `settings.yml.invalid`
and gives the defaults (`DataFolder.readSettings()`).

| Swift name | Key | Type | Required | Default | Rules |
| --- | --- | --- | --- | --- | --- |
| schema | `schema` | `Int` | no | `1` | |
| mcpPort | `mcpPort` | `Int` | no | `47830` | The MCP server's port on 127.0.0.1: 1024–65535 (`SettingsFile.isPort`). `HEPHAESTUS_MCP_PORT` replaces it while set, without changing the file ([MCP](mcp.md#server-lifecycle)). |
| claudePath | `claudePath` | `String?` | no | absent | The Claude CLI the chats run: an absolute path or one from `~/`; absent finds it ([Chat processes › The CLI](#the-cli)). Written only when set. |
| chatModel | `chatModel` | `String?` | no | absent | The model of new chats, a CLI model value such as `opus`; absent for `default`. Written only when set. |
| chatEffort | `chatEffort` | `String?` | no | absent | The effort of new chats (`low`, `medium`, `xhigh`, `max`); absent for `high`. Written only when set. |
| unknownKeys | — | `YAMLMapping` | — | empty | [Unknown keys](#unknown-keys). |

```yaml
schema: 1
mcpPort: 47830
```

## Secrets file

`<data folder>/secrets.json`, mode 0600: one JSON object, written with two-space indentation, keys sorted,
slashes not escaped, and a final line break. Not in the Keychain, as V2 did, so that a rebuilt app doesn't ask
for access.

| Key | Value |
| --- | --- |
| `schema` | `1` |
| `mcpExternalToken` | The MCP server's external token: 64 lowercase hexadecimal characters ([MCP › Authentication](mcp.md#authentication)). |

- `DataFolder.externalToken(make:)` reads the token; when the file is missing, isn't a JSON object, or holds no
  valid token, it makes one and writes it, the file's other keys kept. `replaceExternalToken(with:)` writes a
  new one the same way. The mode is set to 0600 after each write.

## Unknown keys

V3 keeps every key it doesn't use, so that a file written by V2, by a later version or by hand keeps them
when V3 writes it.

- **Kept keys** are V2's keys that V3 doesn't use yet (the **kept** rows of a table). Each is kept exactly as
  read, at its place in the table's order. V3 never adds one that a file doesn't have.
- **Unknown keys** are the keys no table names. They are written after the known and kept keys, in the order
  they were read. (V2 sorted them by key; a file V2 wrote has them sorted already.)
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
  never a reference to a missing one. Each feature's section gives its order; the import's is above.

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

`ProjectDataTests` decode the fixtures, V2's examples, with the Swift types: the complete project file is
written back byte for byte; every example round-trips to an equal value, and every key of the example is in
the output. `FileStorageTests` check the coding rules on their own documents: kept keys in order and layout,
read rules, defaults, schema, dates and quoting. `TicketDataTests` write V2's complete ticket (`HEPH-12`) and
bundle (`HEPH-B2`) back byte for byte, read the minimal ticket with its defaults and creation entry, keep the
unknown keys of `HEPH-14`, and check every rule of [Tickets and bundles](#tickets-and-bundles) in temporary
folders.
