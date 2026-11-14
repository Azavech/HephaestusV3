#!/bin/zsh
# Fills each HephaestusV3Kit target's String Catalog (Sources/<Target>/Localizable.xcstrings) with the strings
# its code uses, and marks the ones it no longer uses as stale. Then lists the lines that hand a string
# to SwiftUI without the target's bundle, which would be looked up in the app's catalog instead.
#
#   scripts/sync-strings.sh             builds HephaestusV3Kit into HephaestusV3Kit/.build/strings first
#   scripts/sync-strings.sh <derived>   uses an existing build: a DerivedData folder of HephaestusV3Kit or HephaestusV3
#
# Xcode fills catalogs as it builds in the IDE; command-line builds only write the .stringsdata files
# this script reads. Exits with 1 when a line misses its bundle.
set -euo pipefail
root=${0:A:h:h}
kit=$root/HephaestusV3Kit
derived=${1:-}

if [[ -z $derived ]]; then
    derived=$kit/.build/strings
    (cd $kit && xcodebuild -quiet -scheme HephaestusV3Kit -destination 'platform=macOS' -derivedDataPath $derived build)
fi

for catalog in $kit/Sources/*/Localizable.xcstrings; do
    target=${catalog:h:t}
    data=( $derived/Build/Intermediates.noindex/**/(${target}|${target}-t).build/Objects-normal/*/*.stringsdata(N) )
    if (( ${#data} == 0 )); then
        print -u2 "No .stringsdata for $target in $derived: build it first."
        exit 2
    fi
    xcrun xcstringstool sync $catalog --stringsdata $data
    print "$target: $(xcrun xcstringstool print $catalog | wc -l | tr -d ' ') strings"
done

# SwiftUI calls that take a string to localize, written without `bundle: #bundle`, and any
# `LocalizedStringKey`: a string handed to them is looked up in the app's main bundle, not the target's
# catalog. Pass a `String` from `String(localized: "…", bundle: #bundle)` instead.
apis='(Text|Button|Label|Toggle|Section|Picker|Menu|TextField|SecureField|LabeledContent|ContentUnavailableView|Link|GroupBox|DisclosureGroup|Stepper|Tab|ControlGroup)\("|\.(help|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|badge|alert|confirmationDialog)\("|String\(localized: "|LocalizedStringResource\("|LocalizedStringKey'
missing=$(grep -rnE "$apis" $kit/Sources --include='*.swift' | grep -v 'bundle:' | grep -v '#Preview(' | grep -v '"""$' | grep -vE ':[0-9]+:\s*//' || true)
if [[ -n $missing ]]; then
    print "\nStrings looked up without the target's bundle:"
    print -r -- ${missing//$kit\//}
    exit 1
fi
