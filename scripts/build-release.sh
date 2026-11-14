#!/bin/bash
# Builds a release of Hephaestus V3 (docs/release.md): the app in Release, signed with the team's Developer ID
# (USWJAJULN9 only) and its Developer ID provisioning profile, notarized and stapled, in a signed, notarized and
# stapled .dmg; then the install page in build/site.
#
#   scripts/build-release.sh --version 1.0.0 [--build 42] [--unsigned]
#
# Signing reads MACOS_CERTIFICATE_P12_BASE64, MACOS_CERTIFICATE_PASSWORD and MACOS_PROVISIONING_PROFILE_BASE64;
# notarization NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_KEY_P8_BASE64. All six are needed, or --unsigned, which
# builds an unsigned .dmg and page to check the pipeline on this Mac. Nothing secret is printed.
set -euo pipefail
cd "$(dirname "$0")/.."

team=USWJAJULN9
bundle_id=fr.azavech.hephaestusv3
version=""
build=""
unsigned=0

fail() {
  echo "build-release.sh: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --unsigned) unsigned=1; shift ;;
    *) echo "usage: scripts/build-release.sh --version X.Y.Z [--build N] [--unsigned]" >&2; exit 2 ;;
  esac
done
echo "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail "--version must be X.Y.Z, such as 1.0.0"
[ -n "$build" ] || build=$(git rev-list --count HEAD)
echo "$build" | grep -Eq '^[1-9][0-9]*$' || fail "--build must be a positive number"

if [ "$unsigned" -eq 0 ]; then
  for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD MACOS_PROVISIONING_PROFILE_BASE64 \
              NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_P8_BASE64; do
    [ -n "${!name:-}" ] || fail "$name is not set; set the six secrets of docs/release.md, or pass --unsigned"
  done
fi

out=build/release
derived=build/DerivedData
rm -rf "$out" build/site
mkdir -p "$out" build/site

# 1. The app, unsigned: this script signs it, so the build needs no account.
xcodebuild -quiet -project HephaestusV3.xcodeproj -scheme HephaestusV3 -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" -scmProvider system \
  CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" build
app="$out/HephaestusV3.app"
ditto "$derived/Build/Products/Release/HephaestusV3.app" "$app"
[ -x "$app/Contents/Helpers/HephaestusAgent" ] || fail "the guest agent is missing from the app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] || fail "the app's version is not $version"

dmg="$out/HephaestusV3-$version.dmg"
make_dmg() {
  local staging="$out/dmg"
  rm -rf "$staging"
  mkdir -p "$staging"
  ditto "$app" "$staging/HephaestusV3.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -quiet -volname "Hephaestus V3" -srcfolder "$staging" -ov -format UDZO "$dmg"
  rm -rf "$staging"
}

if [ "$unsigned" -eq 1 ]; then
  echo "build-release.sh: unsigned build: not for installing" >&2
  make_dmg
else
  work=$(mktemp -d)
  keychain="$work/signing.keychain-db"
  saved_keychains=$(security list-keychains -d user | tr -d '"')
  cleanup() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s $saved_keychains > /dev/null 2>&1 || true
    security delete-keychain "$keychain" > /dev/null 2>&1 || true
    rm -rf "$work"
  }
  trap cleanup EXIT

  # 2. The Developer ID identity, in a keychain of its own; only the team's.
  password=$(uuidgen)
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  (umask 077; printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$work/certificate.p12")
  security import "$work/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign > /dev/null
  rm -f "$work/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$keychain" $saved_keychains
  identity=$(security find-identity -v -p codesigning "$keychain" | grep "Developer ID Application: .*($team)\"" | head -1 | awk '{print $2}')
  [ -n "$identity" ] || fail "the certificate holds no Developer ID Application identity of team $team"

  # 3. The Developer ID provisioning profile: the App Group needs it.
  profile="$work/profile.provisionprofile"
  (umask 077; printf '%s' "$MACOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$profile")
  security cms -D -i "$profile" > "$work/profile.plist" 2> /dev/null || fail "the provisioning profile cannot be read"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$work/profile.plist")" = "$team" ] || fail "the provisioning profile is not team $team's"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$work/profile.plist")" = "$team.$bundle_id" ] \
    || fail "the provisioning profile is not for $bundle_id"
  /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$work/profile.plist" 2> /dev/null | grep -q true || fail "the provisioning profile is not a Developer ID profile"
  cp "$profile" "$app/Contents/embedded.provisionprofile"

  # 4. The entitlements: the app's file, with the identifiers the profile grants.
  entitlements="$work/entitlements.plist"
  cp HephaestusV3/HephaestusV3.entitlements "$entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team.$bundle_id" "$entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team" "$entitlements"

  # 5. The agent first, then the app, whose signature seals it. Never --deep.
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" \
    --identifier "$bundle_id.agent" "$app/Contents/Helpers/HephaestusAgent"
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" --entitlements "$entitlements" "$app"
  codesign --verify --strict --deep "$app"
  [ "$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$team" ] || fail "the app is not signed by team $team"

  # 6. Notarization: the app, stapled, then the .dmg holding it, stapled.
  (umask 077; printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$work/AuthKey.p8")
  notarize() {
    xcrun notarytool submit "$1" --key "$work/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
      --wait --timeout 1h --output-format json > "$work/notary.json"
    local status
    status=$(/usr/bin/plutil -extract status raw -o - "$work/notary.json" 2> /dev/null || echo unknown)
    if [ "$status" != "Accepted" ]; then
      local id
      id=$(/usr/bin/plutil -extract id raw -o - "$work/notary.json" 2> /dev/null || echo "")
      [ -z "$id" ] || xcrun notarytool log "$id" --key "$work/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
      fail "notarization of $(basename "$1") failed: $status"
    fi
  }
  ditto -c -k --sequesterRsrc --keepParent "$app" "$work/app.zip"
  notarize "$work/app.zip"
  xcrun stapler staple -q "$app"
  make_dmg
  codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$dmg"
  notarize "$dmg"
  xcrun stapler staple -q "$dmg"
  xcrun stapler validate -q "$dmg"
fi

# 7. The install page, with the .dmg beside it.
sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
bytes=$(stat -f %z "$dmg")
size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1000000 }')
date=$(date -u +%Y-%m-%d)
name=$(basename "$dmg")
cp "$dmg" "build/site/$name"
sed -e "s/{{VERSION}}/$version/g" -e "s/{{BUILD}}/$build/g" -e "s/{{DATE}}/$date/g" -e "s/{{DMG}}/$name/g" \
    -e "s/{{SHA256}}/$sha/g" -e "s/{{SIZE}}/$size/g" -e "s/{{SIGNED}}/$([ "$unsigned" -eq 1 ] && echo unsigned || echo notarized)/g" \
    site/index.html > build/site/index.html
touch build/site/.nojekyll

echo "dmg=$dmg"
echo "sha256=$sha"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "dmg=$dmg"; echo "sha256=$sha"; echo "build=$build"; } >> "$GITHUB_OUTPUT"
fi
