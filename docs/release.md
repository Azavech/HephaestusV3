# Releases

A release of Hephaestus V3 is a GitHub release of this repository with the app's `.dmg` and its `release.json`. A
GitHub Actions workflow builds it when the owner asks for one. By the owner's choice (14 November 2026) there is no
install page, no Developer ID signature and no notarization: the app is signed ad-hoc, so macOS asks to confirm its
first opening. The workspace's install page and Developer ID rule are set aside for this app until the owner
decides otherwise. Since 21 November 2026 the app updates itself from these releases, as V2 did: its
[Updater](updater.md) reads the latest release's `release.json`, without signing in to GitHub: the owner made the
repository public for it.

```
Actions ▸ Release ▸ Run workflow (version X.Y.Z)
  └─ release.yml on a GitHub macOS runner (xcode-27)
       Xcode 27.2+ ─► tests ─► scripts/build-release.sh ─► tag vX.Y.Z, GitHub release with the .dmg and release.json
```

| Piece | What it is |
| --- | --- |
| `.github/workflows/release.yml` | The workflow ([Workflow](#workflow)). |
| `scripts/build-release.sh` | The build, the ad-hoc signatures, the `.dmg` and `release.json` ([Build script](#build-script)). |
| `build/` | The script's output, ignored by git: `build/DerivedData`, `build/release` (the app, the `.dmg` and `release.json`). |

## Setup

One repository secret, `AZDESIGN_DEPLOY_KEY`: the private half of an SSH key whose public half is a
**read-only deploy key** of `Azavech/AZDesign` ("HephaestusV3 release runner (read-only)"). The runner fetches the
private AZDesign package with it; it opens nothing else and can be revoked in AZDesign's settings on its own. To
replace it: `ssh-keygen -t ed25519 -N "" -f key`, `gh repo deploy-key add key.pub -R Azavech/AZDesign`, `gh secret
set AZDESIGN_DEPLOY_KEY -R Azavech/HephaestusV3 < key`, then delete both files.

## Running a release

Actions ▸ **Release** ▸ Run workflow, with the version (`X.Y.Z`, such as `1.0.0`), or:

```sh
gh workflow run release.yml -f version=1.0.0
```

The workflow runs only when asked, never on a push. One release runs at a time (`concurrency: release`).

## Workflow

`release.yml`, on `workflow_dispatch` with the input `version`, on `runs-on: xcode-27` (a GitHub macOS runner),
with `contents: write`:

| Step | Does |
| --- | --- |
| Check out | `actions/checkout@v5`, the whole history (the build number counts the commits). |
| Select Xcode | The newest `/Applications/Xcode_27*.app`, else `Xcode.app`; fails below 27.2, which reads the project's JSON format. |
| Reach AZDesign | Writes `AZDESIGN_DEPLOY_KEY` to `~/.ssh/azdesign_deploy` (mode 600), pins GitHub's ed25519 host key, uses the key for `github.com`, and checks it with `git ls-remote`; fails without the secret. |
| Check the release doesn't exist | `gh release view vX.Y.Z` must fail: a version is released once. |
| Test | `swift test` in `HephaestusV3Kit`, in `GuestAgent` and in `Updater`, at most 4 tests at a time (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`). |
| Build | `scripts/build-release.sh --version X.Y.Z`. |
| Publish the release | Tags `vX.Y.Z`, pushes the tag, creates the GitHub release titled `Hephaestus V3 X.Y.Z (<build>)`, marked latest, with the `.dmg` and `release.json`; its notes give the commit, how to open the app the first time, that the app then installs its updates itself, and the `.dmg`'s SHA-256. |

## Build script

`scripts/build-release.sh --version X.Y.Z [--build N]` (bash 3.2, `set -euo pipefail`, run from anywhere; status 0,
1 on failure, 2 for wrong arguments):

1. The version must be `X.Y.Z`; the build defaults to `git rev-list --count HEAD`.
2. `xcodebuild -scheme HephaestusV3 -configuration Release -destination generic/platform=macOS -scmProvider system
   CODE_SIGNING_ALLOWED=NO MARKETING_VERSION=X.Y.Z CURRENT_PROJECT_VERSION=<build>` into `build/DerivedData`; the app
   is copied to `build/release`. The agent and the Updater must be in `Contents/Helpers` and the app's version the one
   asked. The About window and the status bar show the version and the build.
3. Ad-hoc signatures (`codesign --sign -`): the helpers first, the agent (`--identifier fr.azavech.hephaestusv3.agent`)
   and the Updater (`--identifier fr.azavech.hephaestusv3.updater`), then the app with
   `HephaestusV3/HephaestusV3.entitlements` (the App Group and virtualization), then `codesign --verify --strict
   --deep`.
4. `HephaestusV3-X.Y.Z.dmg` (`hdiutil create -format UDZO`, volume **Hephaestus V3**), holding the app and a link to
   Applications.
5. `build/release/release.json` ([release.json](#releasejson)), written with `jq`. The script prints `dmg=`,
   `sha256=` and `manifest=` and writes them, with `build=`, to `$GITHUB_OUTPUT`.

## release.json

The asset the [Updater](updater.md#assets-and-releasejson) of every installed copy reads: UTF-8 JSON with these
members, in this order, every one required; a reader ignores members it doesn't know. UpdateData decodes it as
`ReleaseManifest`. V2's manifest, which described its zip, here describes the `.dmg`.

| Member | JSON type | Rule | Example |
| --- | --- | --- | --- |
| `version` | string | `X.Y.Z` without leading zeros; the tag without `v`, and the app's `CFBundleShortVersionString`. | `"1.0.44"` |
| `build` | integer | ≥ 1; the app's `CFBundleVersion`, the commit count. | `80` |
| `sha256` | string | The `.dmg`'s SHA-256: 64 lowercase hexadecimal digits. | see below |
| `size` | integer | ≥ 1; the `.dmg`'s size in bytes. | `48211932` |
| `minimumSystemVersion` | string | The app's `LSMinimumSystemVersion`, `^[0-9]+(\.[0-9]+){0,2}$`. | `"27.0"` |
| `published` | string | When the file was written: `YYYY-MM-DDTHH:MM:SSZ`, UTC. | `"2026-11-22T09:14:05Z"` |
| `notes` | string | `Hephaestus V3 X.Y.Z (<build>), built from <short commit>.` | see below |

```json
{
  "version": "1.0.44",
  "build": 80,
  "sha256": "50d858e0985ecc7f60418aaf0cc5ab587f42c2570a884095a9e8ccacd0f6545c",
  "size": 48211932,
  "minimumSystemVersion": "27.0",
  "published": "2026-11-22T09:14:05Z",
  "notes": "Hephaestus V3 1.0.44 (80), built from 1a2b3c4."
}
```

UpdateDataTests decode this example and check its rules.

## Installing

Download the `.dmg` from the release, open it, and drag Hephaestus V3 onto Applications. macOS refuses to open an
app that isn't notarized on its first opening: Control-click it ▸ Open, or System Settings ▸ Privacy & Security ▸
Open Anyway, or `xattr -dr com.apple.quarantine /Applications/HephaestusV3.app`.

An ad-hoc signed copy can't use the App Group container: macOS refuses it ("Operation not permitted") without
asking. The data folder is therefore in Application Support ([Data › Data folder](data.md#data-folder)).

## Updates

From the first release that has the Updater, the copy in `/Applications` installs the later releases itself
([Updater](updater.md), [UI › Updates](ui/updates.md)): it finds the latest release 10 seconds after it opens and
every 30 minutes, downloads its `.dmg`, checks its size, SHA-256, bundle id, version and signature, and swaps
`/Applications/HephaestusV3.app` when it quits or restarts, keeping no copy of the previous version. It removes the
quarantine attribute itself, so macOS doesn't ask again. The releases before it (1.0.43 and earlier) have neither
the Updater nor `release.json`: the first one with them is installed by hand, as above.

It reads GitHub without signing in, so the repository must stay public: were it private, every check would end in
"GitHub doesn't show Azavech/HephaestusV3 to visitors: the repository is private or doesn't exist.", shown in
Settings ▸ Updates and the About window, and checks again at its interval.
