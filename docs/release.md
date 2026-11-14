# Releases

A release of Hephaestus V3 is a GitHub release of this repository with the app's `.dmg`. A GitHub Actions
workflow builds it when the owner asks for one. By the owner's choice (14 November 2026) there is no install page,
no updater, no Developer ID signature and no notarization: the app is signed ad-hoc, so macOS asks to confirm its
first opening. The workspace's install page and Developer ID rule are set aside for this app until the owner
decides otherwise.

```
Actions ▸ Release ▸ Run workflow (version X.Y.Z)
  └─ release.yml on a GitHub macOS runner (xcode-27)
       Xcode 27.2+ ─► tests ─► scripts/build-release.sh ─► tag vX.Y.Z, GitHub release with the .dmg
```

| Piece | What it is |
| --- | --- |
| `.github/workflows/release.yml` | The workflow ([Workflow](#workflow)). |
| `scripts/build-release.sh` | The build, the ad-hoc signatures and the `.dmg` ([Build script](#build-script)). |
| `build/` | The script's output, ignored by git: `build/DerivedData`, `build/release` (the app and the `.dmg`). |

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

`release.yml`, on `workflow_dispatch` with the input `version`, on `runs-on: xcode-27` (the GitHub macOS runner V2
used), with `contents: write`:

| Step | Does |
| --- | --- |
| Check out | `actions/checkout@v5`, the whole history (the build number counts the commits). |
| Select Xcode | The newest `/Applications/Xcode_27*.app`, else `Xcode.app`; fails below 27.2, which reads the project's JSON format. |
| Reach AZDesign | Writes `AZDESIGN_DEPLOY_KEY` to `~/.ssh/azdesign_deploy` (mode 600), pins GitHub's ed25519 host key, uses the key for `github.com`, and checks it with `git ls-remote`; fails without the secret. |
| Check the release doesn't exist | `gh release view vX.Y.Z` must fail: a version is released once. |
| Test | `swift test` in `HephaestusV3Kit` and in `GuestAgent`, at most 4 tests at a time (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`). |
| Build | `scripts/build-release.sh --version X.Y.Z`. |
| Publish the release | Tags `vX.Y.Z`, pushes the tag, creates the GitHub release titled `Hephaestus V3 X.Y.Z (<build>)` with the `.dmg`; its notes give the commit, how to open the app the first time, and the `.dmg`'s SHA-256. |

## Build script

`scripts/build-release.sh --version X.Y.Z [--build N]` (bash 3.2, `set -euo pipefail`, run from anywhere; status 0,
1 on failure, 2 for wrong arguments):

1. The version must be `X.Y.Z`; the build defaults to `git rev-list --count HEAD`.
2. `xcodebuild -scheme HephaestusV3 -configuration Release -destination generic/platform=macOS -scmProvider system
   CODE_SIGNING_ALLOWED=NO MARKETING_VERSION=X.Y.Z CURRENT_PROJECT_VERSION=<build>` into `build/DerivedData`; the app
   is copied to `build/release`. The agent must be in `Contents/Helpers` and the app's version the one asked. The
   About window shows the version and the build.
3. Ad-hoc signatures (`codesign --sign -`): the agent first (`--identifier fr.azavech.hephaestusv3.agent`), then the
   app with `HephaestusV3/HephaestusV3.entitlements` (the App Group and virtualization), then `codesign --verify
   --strict --deep`.
4. `HephaestusV3-X.Y.Z.dmg` (`hdiutil create -format UDZO`, volume **Hephaestus V3**), holding the app and a link to
   Applications. The script prints `dmg=` and `sha256=` and writes them, with `build=`, to `$GITHUB_OUTPUT`.

## Installing

Download the `.dmg` from the release (signed in to GitHub: the repository is private), open it, and drag Hephaestus
V3 onto Applications. macOS refuses to open an app that isn't notarized on its first opening: Control-click it ▸
Open, or System Settings ▸ Privacy & Security ▸ Open Anyway, or `xattr -dr com.apple.quarantine
/Applications/HephaestusV3.app`.

Not checked yet: whether macOS asks for access to the App Group container (the data folder) from an ad-hoc signed
copy, which has no provisioning profile granting the group.
