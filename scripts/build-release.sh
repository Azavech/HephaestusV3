#!/bin/bash
# Builds a release of Hephaestus V3 (docs/release.md): the app in Release, signed ad-hoc with its entitlements,
# in a .dmg, and the release.json that the Updater of every installed copy reads. No Developer ID and no
# notarization, by the owner's choice: macOS asks to confirm the first opening.
#
#   scripts/build-release.sh --version 1.0.0 [--build 42]
set -euo pipefail
cd "$(dirname "$0")/.."

version=""
build=""

fail() {
  echo "build-release.sh: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    *) echo "usage: scripts/build-release.sh --version X.Y.Z [--build N]" >&2; exit 2 ;;
  esac
done
echo "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail "--version must be X.Y.Z, such as 1.0.0"
[ -n "$build" ] || build=$(git rev-list --count HEAD)
echo "$build" | grep -Eq '^[1-9][0-9]*$' || fail "--build must be a positive number"

out=build/release
derived=build/DerivedData
rm -rf "$out"
mkdir -p "$out"

# 1. The app, built unsigned: it needs no account.
xcodebuild -quiet -project HephaestusV3.xcodeproj -scheme HephaestusV3 -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" -scmProvider system \
  CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" build
app="$out/HephaestusV3.app"
ditto "$derived/Build/Products/Release/HephaestusV3.app" "$app"
[ -x "$app/Contents/Helpers/HephaestusAgent" ] || fail "the guest agent is missing from the app"
[ -x "$app/Contents/Helpers/HephaestusUpdater" ] || fail "the Updater is missing from the app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] || fail "the app's version is not $version"

# 2. Ad-hoc signatures: the helpers first, then the app with its entitlements (the App Group and virtualization).
codesign --force --sign - --identifier fr.azavech.hephaestusv3.agent "$app/Contents/Helpers/HephaestusAgent"
codesign --force --sign - --identifier fr.azavech.hephaestusv3.updater "$app/Contents/Helpers/HephaestusUpdater"
codesign --force --sign - --entitlements HephaestusV3/HephaestusV3.entitlements "$app"
codesign --verify --strict --deep "$app"

# 3. The disk image: the app and a link to Applications.
dmg="$out/HephaestusV3-$version.dmg"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/HephaestusV3.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Hephaestus V3" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"

# 4. release.json: what the Updater reads of the release (docs/release.md › release.json).
sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
size=$(stat -f %z "$dmg")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
manifest="$out/release.json"
jq -n --arg version "$version" --argjson build "$build" --arg sha256 "$sha" --argjson size "$size" \
  --arg minimum "$minimum" --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg notes "Hephaestus V3 $version ($build), built from $(git rev-parse --short HEAD)." \
  '{version: $version, build: $build, sha256: $sha256, size: $size, minimumSystemVersion: $minimum, published: $published, notes: $notes}' \
  > "$manifest"

echo "dmg=$dmg"
echo "sha256=$sha"
echo "manifest=$manifest"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "dmg=$dmg"; echo "sha256=$sha"; echo "build=$build"; echo "manifest=$manifest"; } >> "$GITHUB_OUTPUT"
fi
