# Updater

Hephaestus V3 updates itself from the GitHub releases of `Azavech/HephaestusV3`, as V2 did from its own (the
owner's choice of 21 November 2026). A second executable, the **Updater**, runs beside the app: it checks the
latest release 10 seconds after it starts, then every `updateCheckIntervalMinutes` and when asked; it downloads and
verifies a newer build; and when the app quits it replaces `/Applications/HephaestusV3.app` and, for a restart,
opens the app again. The app and the Updater talk through distributed notifications. What the user sees, the About
window, the status bar's Version and Update items, Settings ▸ Updates and the restart rules, is in
[UI › Updates](ui/updates.md); how releases are built and what they carry is in [Release](release.md).

The Updater reads GitHub without signing in, as V2's did, so the owner made the repository public (21 November
2026). Were it private again, GitHub would answer 404, and every check would end in the error `GitHub doesn't show
Azavech/HephaestusV3 to visitors: the repository is private or doesn't exist.` ([Release feed](#release-feed)); the
checks go on at their interval and need nothing else once it is public.

| Part       | Where                                                                                                                                           | Does                                                                                                                                                                                                                                                                    |
|------------|-------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Updater    | `HephaestusV3.app/Contents/Helpers/HephaestusUpdater`, the Xcode target `HephaestusUpdater` (`HephaestusUpdater/main.swift`)                    | A process of its own: the checks, the download, the verification, the swap, the relaunch. Signed with the identifier `fr.azavech.hephaestusv3.updater`.                                                                                                                 |
| UpdateData | `Updater/Sources/UpdateData/`, the product `UpdateData` of the local package `Updater`, which the helper and HephaestusV3Kit's ToolsScenes link | What the Updater and the app share: versions, `release.json`, the feed, the download, the checks, the install, the notifications, the state machine, the app side's rules ([Swift shape](#swift-shape)). The Updater's `main.swift` only calls `UpdaterProcess.main()`. |
| App side   | `UpdateController` in ToolsScenes, held by `AppData` as `updates`                                                                               | Starts and watches the Updater, sends its requests, keeps its last status, restarts the app; the About window, the status bar and Settings ▸ Updates read it.                                                                                                           |

## Versions

| Item       | Source                                           | Form                                               | Example               |
|------------|--------------------------------------------------|----------------------------------------------------|-----------------------|
| version    | `CFBundleShortVersionString`                     | `X.Y.Z`                                            | `1.0.43`              |
| build      | `CFBundleVersion`                                | a decimal integer, the commit count of the release | `78`                  |
| Display    | the version and build of a release or of the app | `v<version>(<build>)`                              | `v1.0.43(78)`         |
| About line | the running app's                                | `Version <version> (<build>)`                      | `Version 1.0.43 (78)` |

- Only builds are compared: a release is newer when its build is greater than the running app's. Version strings
  are shown and checked for equality, never compared.
- A build of Xcode or of `xcodebuild` without `CURRENT_PROJECT_VERSION` reads build 0, the project's value: a
  development build, which doesn't update itself ([Starting the Updater](#starting-the-updater)). A release sets
  the commit count ([Release › Build script](release.md#build-script)).

## Starting the Updater

At launch, once the projects and `settings.yml` are read (`AppData.start()`), `UpdateController.start(dataFolder:)`
starts the Updater unless one of these holds. They are looked at once per launch, in order; the first that holds
is the reason the About window and Settings ▸ Updates show.

| # | Condition                                                                                                                            | Reason shown                                                                                                      |
|---|--------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| 1 | `CFBundleVersion` is missing, not a decimal integer, or `0`                                                                          | `Updates are off in development builds.`                                                                          |
| 2 | `HEPHAESTUS_DISABLE_UPDATER` is `1`                                                                                                  | `Updates are off: HEPHAESTUS_DISABLE_UPDATER is set.`                                                             |
| 3 | The running app isn't `/Applications/HephaestusV3.app` (a copy in Downloads, in `build/`, in DerivedData, or one macOS translocated) | `Updates are unavailable: Hephaestus V3 updates only its copy in /Applications. Move it there and open it again.` |
| 4 | `/Applications`, or the app itself, can't be written by the user (`FileManager.isWritableFile`)                                      | `Updates are unavailable: this account can't write to /Applications/HephaestusV3.app.`                            |
| 5 | `Contents/Helpers/HephaestusUpdater` is missing or not executable                                                                    | `Updates are unavailable: the Updater is missing from the app.`                                                   |

Row 3 is V3's: only the copy in `/Applications` updates itself, so that no other copy of the app is ever updated
or kept (the owner's rule). V2's condition on a release repository in the Info.plist is gone: the repository is
the app's own, `ReleaseFeed.repository`. Defaults chosen at design time.

### Command line

```text
HephaestusUpdater --app <path> --pid <app pid> --interval <minutes> --auto-update <true|false>
```

| Argument        | Required | Value                                                                                |
|-----------------|----------|--------------------------------------------------------------------------------------|
| `--app`         | yes      | The running app's absolute path (`Bundle.main.bundleURL.path`).                      |
| `--pid`         | yes      | The running app's process id.                                                        |
| `--interval`    | no       | `updateCheckIntervalMinutes`; 30 by default. Below 5 reads as 5, above 1440 as 1440. |
| `--auto-update` | no       | `autoUpdate`: `true` (the default) or `false`.                                       |

A wrong command line makes the Updater write `HephaestusUpdater: <reason>` to standard error and end with status
64. The arguments are read in order, then `--app` and `--pid` are checked; the first failure gives the reason:
`unknown argument <argument>`, `<name> is given twice`, `<name> needs a value`, `--app is required`, `--app needs
an absolute path`, `--pid is required`, `--pid needs a process id`, `--interval needs a number of minutes` (digits
after an optional `-`), `--auto-update needs true or false`.

### Launch and supervision

- The app starts the Updater with `ChildProcess.spawn` (ExternalTools): a process group of its own, so that a
  signal to the app's group doesn't reach it; the app's own environment, `HEPHAESTUS_*` variables included; and
  `/dev/null` for standard input, output and error.
- The Updater logs with `os.Logger`, subsystem `fr.azavech.hephaestusv3.updater`, category `updater`, and writes
  nothing else.
- When the Updater ends while the app runs and the app hasn't posted `app.quitting`, the app starts it again 5
  seconds later with the current settings. After the third such start in one launch it gives up, and the reason
  becomes `The Updater stopped unexpectedly.` A start that fails counts as an end.
- An app that didn't start an Updater ignores every Updater notification and posts none.

## Lifetime

- The Updater runs the main run loop and watches the app's process with a dispatch process source (`.exit`).
- When the app's process doesn't exist at start, the Updater ends with status 0.
- When the app's process ends, the Updater installs in state `installing` ([Installing](#installing)); in every
  other state it ends with status 0 at once, leaving a check or a download unfinished. A download takes its final
  name only once complete, so an unfinished one leaves nothing that a later check uses.
- Statuses: 0 the normal end, 1 a failed install ([Install failure](#install-failure)), 64 a wrong command line.

## Release feed

`ReleaseFeed`, on GitHub's REST API, **without signing in**, with an ephemeral `URLSession` (no cache, no cookies).

### Requests

Each request is a `GET` with a 30-second time limit and these headers: `Accept: application/vnd.github+json`,
`X-GitHub-Api-Version: 2022-11-28`, `User-Agent: HephaestusV3-Updater/<running version>`. No `Authorization`.

1. `https://api.github.com/repos/Azavech/HephaestusV3/releases/latest`.

| Answer                                      | Outcome                                                                                      |
|---------------------------------------------|----------------------------------------------------------------------------------------------|
| 200                                         | The release. Fields read: `tag_name`, `assets[].name`, `assets[].browser_download_url`.      |
| 200 that doesn't decode as a release        | `error`: `The update check failed: <description>.`                                           |
| 404                                         | No release yet, or a repository GitHub doesn't show to visitors: request 2 tells them apart. |
| 429, or 403 with `x-ratelimit-remaining: 0` | `error`: `GitHub's rate limit was reached; the next check tries again.`                      |
| Another status                              | `error`: `GitHub answered HTTP <status>.`                                                    |
| No answer (network, time limit)             | `error`: `The update check failed: <description>.`                                           |

2. After a 404 only: `https://api.github.com/repos/Azavech/HephaestusV3`, the repository's page.

| Answer                    | Outcome                                                                                                      |
|---------------------------|--------------------------------------------------------------------------------------------------------------|
| 200                       | The repository has no release yet: `upToDate`.                                                               |
| 404                       | `error`: `GitHub doesn't show Azavech/HephaestusV3 to visitors: the repository is private or doesn't exist.` |
| Another status, no answer | As for request 1.                                                                                            |

`<description>` is the error's `localizedDescription` without its final period, so that a message ends with one.
Request 2 is V3's: V2's repository was public, and its 404 meant no release (default chosen at design time).

### Assets and release.json

- The release must have exactly one asset named `release.json` with an HTTPS URL; otherwise `error`: `The latest
  release has no release.json asset.`
- The Updater downloads it (redirects followed, 30 seconds, at most 1 MiB) and decodes it as `ReleaseManifest`
  ([Release › release.json](release.md#releasejson)). A body that doesn't decode, a member that breaks its rule, or
  one over 1 MiB: `error`: `The release.json of the latest release is invalid.` Another status than 200: `GitHub
  answered HTTP <status>.`; no answer: `The update check failed: <description>.`
- The release must then have exactly one asset named `HephaestusV3-<version>.dmg`, `<version>` being the
  manifest's, with an HTTPS URL; otherwise `error`: `The latest release has no HephaestusV3-<version>.dmg asset.`

A release made before the Updater has no `release.json`: until the first release that has one, a check ends in
that error.

### Decision

The first row that holds gives the outcome; the running build is the app's `CFBundleVersion`, read once at start.

| # | Condition                                                                             | State       | Version and build | Message                                            |
|---|---------------------------------------------------------------------------------------|-------------|-------------------|----------------------------------------------------|
| 1 | The manifest's `build` ≤ the running build                                            | `upToDate`  | —                 | —                                                  |
| 2 | Its `minimumSystemVersion` is above the running macOS (by component, missing ones 0)  | `upToDate`  | the manifest's    | `v1.0.44(80) requires macOS 28.`                   |
| 3 | The build's cache folder holds `install-failed` ([Install failure](#install-failure)) | `error`     | the manifest's    | `Installing v1.0.44(80) failed: <the file's text>` |
| 4 | Otherwise                                                                             | `available` | the manifest's    | —                                                  |

In row 4, with `autoUpdate` on, the download starts at once; off, the Updater waits for `install`.

## Check schedule

- The first check runs 10 seconds after the Updater starts; then one every `--interval` minutes, counted from the
  end of the previous check, whether it was due or asked for. A failed check doesn't try again before then.
- A `check` notification first takes its `intervalMinutes` (into 5…1440) and `autoUpdate`, then asks for a check.
- A check runs in `idle`, `upToDate`, `available` and `error`. In `checking` none starts, and the status is posted
  again. In `downloading`, `ready` and `installing` no request is made and the status is posted again; a due check
  skipped then counts as a check.
- A check in `available` that finds the same build keeps it; one that finds a newer build takes it. A `check` that
  turns `autoUpdate` on in `available` finds the build again and downloads it. Turning it off stops neither a
  download nor a `ready` update; the app then waits for the user ([UI › Restart rules](ui/updates.md#restart-rules)).

## Download and verification

The state is `downloading`, with the manifest's version and build, from step 1 until the update is `ready` or a
step fails. A download starts with `autoUpdate` on when a check finds a newer build, or on `install`.

| # | Step                                                                                                                                                                                                                                                                                                                                                                                                             | Failure message                                             |
|---|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| 1 | The cache folder `~/Library/Caches/HephaestusV3/Updates/<build>/` is made; every other entry of `Updates/` is deleted, its copy of the app first forgotten in LaunchServices.                                                                                                                                                                                                                                    | `The update couldn't be saved: <description>.`              |
| 2 | `<build>/HephaestusV3-<version>.dmg` is used again when its size and SHA-256 are the manifest's; otherwise its URL is downloaded (redirects followed, 60 seconds per request, 30 minutes in all) to a temporary file, then moved there. An answer that isn't 2xx fails with `The server answered HTTP <status>.` The manifest's bytes go to `<build>/release.json`.                                              | `Downloading v1.0.44(80) failed: <description>.`            |
| 3 | The image's size is `size`.                                                                                                                                                                                                                                                                                                                                                                                      | `The downloaded update has the wrong size.`                 |
| 4 | Its SHA-256, in lowercase hexadecimal, is `sha256`.                                                                                                                                                                                                                                                                                                                                                              | `The downloaded update doesn't match its SHA-256 checksum.` |
| 5 | `<build>/expanded/` is deleted when there is one; the image is attached read-only and hidden at `<build>/mount` (`hdiutil attach -readonly -nobrowse -noautoopen -mountpoint`); its `HephaestusV3.app`, when there is one, is copied with `ditto` to `<build>/expanded/HephaestusV3.app`; the mounted copy is forgotten in LaunchServices; the image is detached (`-force` when it must be) and `mount` deleted. | `The downloaded update couldn't be unpacked.`               |
| 6 | `<build>/expanded/HephaestusV3.app` is a folder.                                                                                                                                                                                                                                                                                                                                                                 | `The downloaded update doesn't contain HephaestusV3.app.`   |
| 7 | Its Info.plist: `CFBundleIdentifier` is `fr.azavech.hephaestusv3`, `CFBundleShortVersionString` the manifest's `version`, `CFBundleVersion` its `build`.                                                                                                                                                                                                                                                         | `The downloaded update isn't Hephaestus V3 v1.0.44(80).`    |
| 8 | `codesign --verify --deep --strict` passes.                                                                                                                                                                                                                                                                                                                                                                      | `The downloaded update has an invalid code signature.`      |
| 9 | When the running app is signed with a Team ID, the update is signed with the same one (the Security framework's `kSecCodeInfoTeamIdentifier`). An ad-hoc signed app, as every release is, takes any signature that passed step 8.                                                                                                                                                                                | `The downloaded update is signed by another team.`          |

- After step 9 the state is `ready`; the Updater posts `status`, then `ready`.
- When a step fails, the build's folder is deleted, its copy of the app first forgotten in LaunchServices, then the
  state is `error`, with the step's message and the manifest's version and build. The next check starts from the
  feed again.
- The cache folder stays in `~/Library/Caches` under `HEPHAESTUS_DATA_DIR` too.

## Installing

The app tells the Updater it quits with `app.quitting`, whose `restart` is true when it quits to install the update
and open again, false on an ordinary quit.

### Restart for an update

1. macOS is told to keep the windows: the app sets its own `NSQuitAlwaysKeepsWindows` to true, with the mark
   `updateRestartKeepsWindows`, unless the user set that default for the app. It then posts `app.quitting` with
   `restart` true and `activate` true when it is the active app.
2. In `ready`, the Updater moves to `installing` and posts it. In any other state it posts its status again.
3. The app waits 5 seconds at most for `installing`. When it comes, the app quits (`NSApp.terminate`), which
   stops its chats, machines and tools as any quit does. When it doesn't, the app keeps running, removes the
   default and the mark, and shows `The Updater didn't answer; the update wasn't installed.` in an alert with OK,
   and in the About window ([UI › About window](ui/updates.md#about-window)).
4. The Updater waits for the app's process to end, 60 seconds at most. Still running then, it goes back to `ready`
   with the message `Hephaestus V3 didn't quit; the update waits for the next restart.`
5. The cached copy is forgotten in LaunchServices, then takes the app's place:
   `FileManager.replaceItemAt(/Applications/HephaestusV3.app, withItemAt: <build>/expanded/HephaestusV3.app)`. The
   previous version goes with the swap: no backup of it is kept.
6. `com.apple.quarantine` is removed from the installed app and everything in it (`removexattr`, links not
   followed; a missing attribute isn't an error).
7. The app opens again **by its path**: `/usr/bin/open`, `-g` when `activate` was false, one `--env NAME=value`
   per `HEPHAESTUS_*` variable of the Updater's environment, then `/Applications/HephaestusV3.app`. Never by its
   bundle id, which could open another copy. LaunchServices then registers the new version at that path.
8. `<build>/` is deleted, then the cached copy's path is forgotten in LaunchServices again (`lsregister -u` takes a
   path no longer there): LaunchServices can register the copy between step 5's forgetting and the swap, and keeps
   that record once the copy has moved. The Updater ends with status 0.

A failure of steps 6 to 8 is logged and doesn't change the status. At the next launch the app removes the
`NSQuitAlwaysKeepsWindows` it set, once macOS has restored the windows, so that later quits follow the user's
setting again. After the swap `/Applications/HephaestusV3.app` is the only copy: the cached one became it, the
previous one was deleted with the swap, and the cache folder goes.

### Install on quit

On an ordinary quit (⌘Q), the app posts `app.quitting` with `restart` false as it quits (on
`NSApplication.willTerminateNotification`), without waiting. In `ready`, the Updater moves to `installing`, waits
for the process to end (step 4) and runs steps 5, 6 and 8, without opening the app. In any other state it ends with
status 0 once the app has quit. The app posts `app.quitting` once per quit: the restart doesn't post it twice.

### Install failure

When step 5 fails, the Updater writes the error's `localizedDescription` to `<build>/install-failed`, opens the
unchanged app again as in step 7 when `restart` was true, and ends with status 1. Every later check reports that
build as `error` (row 3 of [Decision](#decision)) and never downloads it by itself. Try Again in the About window
sends `install`, which deletes `install-failed` and downloads it again.

macOS's App Management protection (System Settings ▸ Privacy & Security ▸ App Management) may refuse the swap, or
ask first, since an ad-hoc signed app has no Team ID to prove that the update is its own. A refusal is such a
failure: the message says "Operation not permitted", and allowing Hephaestus V3 there, then Try Again, installs
it. This hasn't been seen yet: no release with the Updater has been installed over another.

## IPC

Distributed notifications, `DistributedNotificationCenter.default()`, object `fr.azavech.hephaestusv3`, posted
with `deliverImmediately`. `userInfo` holds property-list values; a value that doesn't apply is left out. Every
notification carries `pid`, the app's process id: the app ignores the Updater notifications whose `pid` isn't its
own, and the Updater the app notifications whose `pid` isn't its `--pid`, so that two processes of the app (one
with `HEPHAESTUS_DATA_DIR`) never act on each other's. The Updater registers its observers before it posts its
first status.

| Name                                      | Direction     | `userInfo`                                                                     | Meaning                                                                                                                                                                       |
|-------------------------------------------|---------------|--------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `fr.azavech.hephaestusv3.updater.check`   | app → Updater | `pid`, `intervalMinutes` (Int), `autoUpdate` (Bool)                            | Take the two settings, then check now. A value missing or of another type is left as it was.                                                                                  |
| `fr.azavech.hephaestusv3.updater.install` | app → Updater | `pid`                                                                          | Download and verify the newer build the Updater knows: in `available`, or in `error` with a build (its `install-failed` deleted first). Otherwise the status is posted again. |
| `fr.azavech.hephaestusv3.updater.status`  | Updater → app | `pid`, `state` (String), `version` (String), `build` (Int), `message` (String) | The Updater's state; the last three only when it carries them. Posted at every change of state and whenever a request leaves it as it is.                                     |
| `fr.azavech.hephaestusv3.updater.ready`   | Updater → app | `pid`, `version`, `build`                                                      | The update is downloaded and verified; once per update, right after the status `ready`.                                                                                       |
| `fr.azavech.hephaestusv3.app.quitting`    | app → Updater | `pid`, `restart` (Bool), `activate` (Bool)                                     | The app quits now ([Installing](#installing)).                                                                                                                                |

The app posts `check` when the About window appears, on Check Now, and when Settings ▸ Updates changes a setting;
`install` on Install, a click on the Update item, Update Now, and Try Again after an error with a build;
`app.quitting` as [Installing](#installing) says.

## Updater states

`UpdateController.status` holds the last status received, `idle` without version, build or message before the
first. While the Updater doesn't run, `unavailableReason` holds the reason of [Starting the
Updater](#starting-the-updater), nil otherwise.

| State         | Meaning                                                 | Version and build                           | Message                                 |
|---------------|---------------------------------------------------------|---------------------------------------------|-----------------------------------------|
| `idle`        | Started; no check has ended yet.                        | —                                           | —                                       |
| `checking`    | A check runs.                                           | —                                           | —                                       |
| `upToDate`    | The last check found nothing to install.                | only when a newer build needs a newer macOS | only then                               |
| `available`   | A newer build, not downloaded.                          | the newer build                             | —                                       |
| `downloading` | The newer build is downloaded and verified.             | the newer build                             | —                                       |
| `ready`       | The newer build waits in the cache for the app to quit. | the newer build                             | only after the app didn't quit (step 4) |
| `installing`  | The app quits; the swap comes next.                     | the newer build                             | —                                       |
| `error`       | The last check, download or install failed.             | the build concerned, when there is one      | the reason                              |

| From                                     | Event                                                | To               |
|------------------------------------------|------------------------------------------------------|------------------|
| start                                    | the observers registered                             | `idle`           |
| `idle`, `upToDate`, `available`, `error` | a check due, or `check`                              | `checking`       |
| `checking`                               | no release, or rows 1 and 2 of [Decision](#decision) | `upToDate`       |
| `checking`                               | row 3, or a feed failure                             | `error`          |
| `checking`                               | row 4                                                | `available`      |
| `available`                              | `autoUpdate` on, or `install`                        | `downloading`    |
| `error` with a build                     | `install`                                            | `downloading`    |
| `downloading`                            | step 9 passed                                        | `ready`          |
| `downloading`                            | a step failed                                        | `error`          |
| `ready`                                  | `app.quitting`                                       | `installing`     |
| `installing`                             | the app still runs 60 seconds later                  | `ready`          |
| `installing`                             | the app quit: the swap done, or failed               | the process ends |

Any other notification leaves the state as it is and posts it again.

## LaunchServices

Only `/Applications/HephaestusV3.app` stays registered (the owner's rule): the Updater runs `lsregister -u` on
each copy of the app it made before that copy moves or goes, the copy in a build's `expanded/` folder (steps 1 and
5 and failures) and the one in the mounted image. Tests replace `lsregister`, `open` and `hdiutil`'s image by
fakes (`UpdateTools`), and never touch LaunchServices.

## Security

- The feed and the downloads use HTTPS only: `api.github.com` and the asset URLs GitHub gives.
- The disk image's SHA-256 and size come from `release.json` of the same release; the app's bundle id, version and
  build must be the manifest's, and its signature must pass `codesign --verify --deep --strict`.
- Releases are signed ad-hoc ([Release](release.md)): a running app without a Team ID takes any valid signature,
  so its updates rest on HTTPS and on the repository. Were releases signed with a Developer ID one day, only an
  update signed by the same team would install.
- Distributed notifications carry no sender. A process of the same user that posts them can at most start a
  check, a download and verification of the latest release, or have a verified update installed when the app
  quits. A forged `ready` can't make the app quit: it quits only after the Updater answers `installing`.
- The Updater runs as the user and never asks for an administrator's password; the app doesn't start it when the
  app can't be written.

## Swift shape

| Type (UpdateData)                                                                 | Kind          | Content                                                                                                                                          |
|-----------------------------------------------------------------------------------|---------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `AppVersion`                                                                      | struct        | `version`, `build`; `display`, `aboutLine`; `init?(infoPlist:)`, nil without a decimal `CFBundleVersion`; `running(_:)`, build 0 then.           |
| `ReleaseManifest`                                                                 | struct        | `Codable`: `version`, `build`, `sha256`, `size`, `minimumSystemVersion`, `published` (ISO-8601), `notes`; `validate()`, `diskImageName`.         |
| `GitHubRelease`, `FeedResult`                                                     | struct, enum  | The release's `tag_name` and assets; `.noRelease` or `.release(manifest, manifestData:, diskImageURL:)`.                                         |
| `ReleaseFeed`                                                                     | struct        | `repository` (`Azavech/HephaestusV3`), `latest() async throws(UpdaterError) -> FeedResult`.                                                      |
| `UpdateDecision`                                                                  | enum          | `decide(manifest:runningBuild:systemVersion:installFailedText:)`.                                                                                |
| `UpdateDownloader`                                                                | struct        | Steps 1 to 4; `defaultCacheRoot()`, `buildFolder`, `expandedApp(in:)`, `deleteBuildFolder`.                                                      |
| `UpdateVerifier`                                                                  | struct        | Steps 5 to 9; the bundle id and the Team ID reader can be given, for tests.                                                                      |
| `UpdateInstaller`                                                                 | struct        | Steps 5 to 8 of the restart, `relaunchArguments`, `install-failed`.                                                                              |
| `UpdateTools`, `DiskImage`                                                        | struct, enum  | The tools run (`run`, `unpack`, `unregister`), real in `.system`, fakes in tests; `DiskImage.copyApp` with `hdiutil` and `ditto`.                |
| `UpdaterState`, `UpdaterStatus`, `UpdaterRequest`, `UpdaterMessage`, `UpdaterIPC` | enums, struct | The states, the status and its `userInfo`, the requests and messages, the notification names and keys.                                           |
| `UpdaterMachine`                                                                  | actor         | The states and the schedule, with the feed, download, verification, install, clock and exit given.                                               |
| `UpdaterArguments`                                                                | struct        | The command line; `parse(_:)` throws `UsageError`.                                                                                               |
| `UpdaterProcess`                                                                  | enum          | `main()`: the Updater's process.                                                                                                                 |
| `UpdaterStartConditions`                                                          | enum          | `reason(infoPlist:environment:bundleURL:installedURL:)`, `updaterURL(bundleURL:)`.                                                               |
| `UpdateArea`, `UpdateItem`, `AutomaticRestart`, `UpdateInterval`                  | struct, enums | The About window's rows and Settings' status line, the Update item, the automatic restart, the interval choices ([UI › Updates](ui/updates.md)). |
| `UpdaterTexts`, `UpdaterError`                                                    | enum, struct  | The messages of this page, in English like the other data targets' messages.                                                                     |

ToolsScenes holds `UpdateController`, the About window (`AboutWindow.swift`), Settings ▸ Updates
(`UpdateSettingsView.swift`) and the status bar's items (`StatusBar.swift`); their texts are in its String Catalog.

## Tests

UpdateDataTests, in the `Updater` package (`cd Updater && swift test`), without the network, the real app or LaunchServices: versions; `release.json` and the example of
[Release › release.json](release.md#releasejson); the feed with a stubbed `URLProtocol` (a release, no release, a
repository not shown, the rate limit, statuses, no answer, missing and insecure assets, an invalid manifest, the
headers); every row of the decision; the command line; the notifications' `userInfo`; the start conditions; the
About window's rows, the Update item and the automatic restart; the download and every failure of verification,
with small bundles signed ad hoc under a test bundle id, and one real disk image made with `hdiutil`; the install
in temporary folders (the swap, no backup, no quarantine, the relaunch's arguments, `install-failed`); every
transition of the state machine with a clock the test moves. ToolsScenesTests: the restart alert's text, the
update texts, a controller outside `/Applications`. ProjectDataTests: the two settings.
