# Releases and the install page

Hephaestus V3 is installed from one HTTPS page, as the workspace's rule wants: the Mac app as a Developer ID
signed, notarized `.dmg`. There is no updater: a new version is installed from the page, over the old one. A
GitHub Actions workflow builds a release when the owner asks for one, publishes it as a GitHub release, and
deploys the page with GitHub Pages.

```
Actions ▸ Release ▸ Run workflow (version X.Y.Z)
  └─ release.yml on a GitHub macOS runner (xcode-27)
       Xcode 27.2+ ─► tests ─► scripts/build-release.sh ─► tag vX.Y.Z, GitHub release with the .dmg
                               (build, sign, notarize,      └─► GitHub Pages: build/site (index.html + .dmg)
                                staple, .dmg, page)
```

| Piece | What it is |
| --- | --- |
| `.github/workflows/release.yml` | The workflow ([Workflow](#workflow)). |
| `scripts/build-release.sh` | The build, signing, notarization, `.dmg` and page ([Build script](#build-script)). |
| `site/index.html` | The page's template ([Install page](#install-page)). |
| `build/` | The script's output, ignored by git: `build/DerivedData`, `build/release` (the app and the `.dmg`), `build/site`. |

## Setting it up once

These steps are the owner's: each needs the Apple developer account or the GitHub account, and the values are
secrets that never go in the repository or in a message.

1. **Developer ID certificate.** In Xcode ▸ Settings ▸ Accounts, team USWJAJULN9, Manage Certificates, add a
   **Developer ID Application** certificate (only the account holder, or an admin allowed to, can). Export it
   with its private key from Keychain Access as a `.p12`, with a password.
2. **Developer ID provisioning profile.** In the developer portal (Certificates, Identifiers & Profiles), a
   **Developer ID** profile for the App ID `fr.azavech.hephaestusv3`, whose App Group
   (`group.fr.azavech.hephaestusv3`) and Virtualization capabilities are on, with that certificate. Download it.
   macOS lets a Developer ID app use a `group.` App Group only with a profile that grants it.
3. **Notary key.** In App Store Connect ▸ Users and Access ▸ Integrations, an App Store Connect API key (the
   Developer role is enough for notarization): its key ID, issuer ID and `.p8` file.
4. **AZDesign token.** A fine-grained GitHub token whose only permission is read access to the contents of
   `Azavech/AZDesign`: the runner fetches the package with it.
5. **Repository secrets** (HephaestusV3 ▸ Settings ▸ Secrets and variables ▸ Actions):

   | Secret | Value |
   | --- | --- |
   | `MACOS_CERTIFICATE_P12_BASE64` | `base64 -i certificate.p12` |
   | `MACOS_CERTIFICATE_PASSWORD` | the `.p12`'s password |
   | `MACOS_PROVISIONING_PROFILE_BASE64` | `base64 -i <profile>.provisionprofile` |
   | `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | the API key's IDs |
   | `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_<id>.p8` |
   | `AZDESIGN_READ_TOKEN` | the token of step 4 |

6. **GitHub Pages.** HephaestusV3 ▸ Settings ▸ Pages ▸ Source: **GitHub Actions**. On a private repository,
   Pages needs a paid GitHub plan, and the page is public: anyone with its address can download the app. It asks
   search engines not to index it (`noindex`).

## Running a release

Actions ▸ **Release** ▸ Run workflow, with the version (`X.Y.Z`, such as `1.0.0`), or from a terminal:

```sh
gh workflow run release.yml -f version=1.0.0
```

The workflow runs only when asked, never on a push: each phase of V3 is pushed, and not every push is a release.
One release runs at a time (`concurrency: release`, never cancelled).

## Workflow

`release.yml`, on `workflow_dispatch` with the input `version`, on `runs-on: xcode-27` (the GitHub macOS runner
V2 used), with `contents: write` (the tag and the release), `pages: write` and `id-token: write` (the page), in the
`github-pages` environment. Its steps:

| Step | Does |
| --- | --- |
| Check out | `actions/checkout@v5`, the whole history (the build number counts the commits). |
| Select Xcode | The newest `/Applications/Xcode_27*.app`, else `Xcode.app`; fails below 27.2, which reads the project's JSON format. |
| Reach AZDesign | Rewrites `git@github.com:Azavech/AZDesign` to HTTPS with `AZDESIGN_READ_TOKEN`; fails without it. |
| Check the release doesn't exist | `gh release view vX.Y.Z` must fail: a version is released once. |
| Test | `swift test` in `HephaestusV3Kit` and in `GuestAgent`, at most 4 tests at a time (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`). |
| Build, sign and notarize | `scripts/build-release.sh --version X.Y.Z` with the six signing and notary secrets. |
| Publish the release | Tags `vX.Y.Z`, pushes the tag, creates the GitHub release titled `Hephaestus V3 X.Y.Z (<build>)` with the `.dmg` and its SHA-256 in the notes. |
| Upload the install page, Deploy the install page | `actions/upload-pages-artifact@v4` with `build/site`, then `actions/deploy-pages@v4`. |

## Build script

`scripts/build-release.sh --version X.Y.Z [--build N] [--unsigned]` (bash 3.2, `set -euo pipefail`, run from
anywhere; status 0, 1 on failure, 2 for wrong arguments; it prints no secret):

1. **Arguments.** The version must be `X.Y.Z`; the build defaults to `git rev-list --count HEAD`. Without
   `--unsigned`, the six secrets must be set: `MACOS_CERTIFICATE_P12_BASE64 is not set; …`.
2. **Build.** `xcodebuild -scheme HephaestusV3 -configuration Release -destination generic/platform=macOS
   -scmProvider system CODE_SIGNING_ALLOWED=NO MARKETING_VERSION=X.Y.Z CURRENT_PROJECT_VERSION=<build>` into
   `build/DerivedData`, the app copied to `build/release`. The agent must be in `Contents/Helpers` and the app's
   `CFBundleShortVersionString` the version. The About window shows the version and the build.
3. **Identity.** A keychain of its own with a random password, the `.p12` imported for `codesign`, put first in
   the search list, restored and deleted at exit. The identity is the `Developer ID Application: … (USWJAJULN9)`
   one: a certificate of another team fails (`the certificate holds no Developer ID Application identity of team
   USWJAJULN9`).
4. **Profile.** The profile must be team USWJAJULN9's, for `USWJAJULN9.fr.azavech.hephaestusv3`, and a Developer
   ID profile (`ProvisionsAllDevices`); it becomes `Contents/embedded.provisionprofile`.
5. **Entitlements.** `HephaestusV3/HephaestusV3.entitlements` plus `com.apple.application-identifier` and
   `com.apple.developer.team-identifier`.
6. **Signing.** The agent first (`--identifier fr.azavech.hephaestusv3.agent`), then the app with the
   entitlements, both `--timestamp --options runtime`, never `--deep`; then `codesign --verify --strict --deep`
   and the team checked.
7. **Notarization.** `notarytool submit --wait --timeout 1h` with the API key: the app (zipped with `ditto`),
   stapled; then the `.dmg`, signed, notarized, stapled and validated. A status other than `Accepted` prints the
   notary log and fails.
8. **Disk image.** `HephaestusV3-X.Y.Z.dmg`, `hdiutil create -format UDZO`, volume **Hephaestus V3**, holding the
   app and a link to Applications.
9. **Page.** `site/index.html` with its placeholders filled, the `.dmg` beside it and `.nojekyll`, in
   `build/site`; the script prints `dmg=` and `sha256=` and writes them, with `build=`, to `$GITHUB_OUTPUT`.

`--unsigned` skips steps 3 to 7 to check the pipeline on a Mac without the secrets: its `.dmg` isn't for
installing, and its page says **unsigned**.

## Install page

`site/index.html`: one static page, the workspace's design in HTML (AZDesign's Alucard palette in light mode,
Dracula in dark, the system font), `noindex, nofollow`, and the placeholders `{{VERSION}}`, `{{BUILD}}`,
`{{DATE}}`, `{{DMG}}`, `{{SIZE}}`, `{{SIGNED}}` and `{{SHA256}}`:

- **Hephaestus V3**, then "Version X.Y.Z (build), date".
- **Mac**: **Download for Mac** (the `.dmg`), its name, size and **notarized**, "macOS 27 or later." (macOS 27
  runs on Apple silicon only, so the virtual machines need nothing more), and three steps: open the disk image, drag Hephaestus V3 onto
  Applications, open it.
- **iPhone and iPad**: Hephaestus V3 is a Mac app; nothing to install there. (The workspace's `itms-services`
  links come with the first iPhone or iPad app.)
- **Checking the download**: the SHA-256, and the `shasum -a 256` command that prints it.

The page holds only the latest release: each deployment replaces it. Earlier `.dmg`s stay on their GitHub
releases.

Defaults chosen at design time: the run on demand only, the version as the workflow's input and the build as the
commit count, refusing to release a version twice, failing rather than signing ad-hoc (V2 fell back to ad-hoc),
the separate AZDesign token, the page's content and `noindex`, the `.dmg` on the page itself.
