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
| Tickets, bundles, attachments | `<project>/.hephaestus/ticket/`, `bundle/`, `attachments/` | — | Tickets (not yet read) |
| Chats | `<project>/.hephaestus/chats/` | — | Chat (not yet read) |

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
    ticket/  bundle/  attachments/    tickets (not read yet)
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
marked **kept** are V2's keys that V3 doesn't use yet ([Unknown keys](#unknown-keys)).

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
| — | `dashboardWidgets` | kept | no | absent | V2's Dashboard widgets. |
| — | `dashboardGraphWindow` | kept | no | absent | V2's time window of the Dashboard's graph widgets. |
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
| **Update** (`ProjectChange`) | Only the values the change sets: name; type; color (a tint, or `#RRGGBB` uppercased, or none); icon (trimmed, none when empty); docs folder (a relative path, not `.hephaestus` or inside it); GitHub page (validated, none when empty); Use parent settings; graph; the whole list of the project's own environments; all its changes to inherited environments. An environment or a change equal to a stored one is written back as it is, even when a hand edit made it break a rule (each stored environment keeps at most one equal environment: a copy is checked); any other is checked ([Validation](#validation)), its names trimmed, a change that sets nothing dropped. An own environment can't take a name another environment has, inherited ones included. | the project file, then `current-environments.yml` when a choice follows a rename or is forgotten |
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
read rules, defaults, schema, dates and quoting.
