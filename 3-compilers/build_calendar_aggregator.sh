#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
source_dir="$repo_dir/macos/CalendarAggregator"
engine="$repo_dir/1-src/CalendarSyncEngine.swift"
artwork="$source_dir/Artwork"
app_name="Calendar Aggregator"
identifier="garden.bath.calendar-aggregator"
identity=${SIGNING_IDENTITY:-"Art Bath Personal Code Signing"}
destination=${1:-"$HOME/Library/Caches/$identifier/build/$app_name.app"}
destination=${destination:a}
target="$(uname -m)-apple-macos14.0"

certificate=$(security find-identity -v -p codesigning | awk -v identity="\"$identity\"" '
    index($0, identity) && !found { print $2; found = 1 }
')
if [[ ! "$certificate" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 "Personal code-signing identity unavailable: $identity"
    exit 78
fi
requirement="identifier \"$identifier\" and certificate leaf = H\"$certificate\""
verify() {
    codesign --verify --strict -R "=$requirement" "$1"
}

fingerprint=$(
    for source in "$engine" "$source_dir"/*.swift "$source_dir/Info.plist" "$artwork"/*(.) \
        "$artwork/$app_name.icon/icon.json" "$artwork/$app_name.icon/Assets/"*(.) "$0"; do
        shasum -a 256 < "$source"
    done
    print -r -- "$target $certificate"
)
fingerprint=$(print -r -- "$fingerprint" | shasum -a 256 | awk '{print $1}')
stamp="$destination/Contents/Resources/source-fingerprint"
if [[ -f "$stamp" && "$(<"$stamp")" == "$fingerprint" ]] && verify "$destination" 2>/dev/null; then
    print -r -- "$destination"
    exit 0
fi

mkdir -p "${destination:h}"
stage=$(mktemp -d "${destination:h}/.calendar-aggregator-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$app_name.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"

swiftc -module-cache-path "$stage/module-cache" -parse-as-library -target "$target" \
    "$engine" "$source_dir"/*.swift -o "$bundle/Contents/MacOS/$app_name"

xcrun actool "$artwork/$app_name.icon" --compile "$resources" \
    --output-partial-info-plist "$stage/icon-info.plist" --app-icon "$app_name" \
    --include-all-app-icons --target-device mac --minimum-deployment-target 14.0 \
    --platform macosx --output-format human-readable-text
/usr/libexec/PlistBuddy -c "Merge '$stage/icon-info.plist'" "$bundle/Contents/Info.plist"
cp "$artwork/calendar-sync.svg" "$artwork/Lucide-LICENSE.txt" "$resources/"
print -r -- "$fingerprint" > "$resources/source-fingerprint"

xattr -cr "$bundle"
codesign --force --sign "$certificate" --identifier "$identifier" --timestamp=none "$bundle"
verify "$bundle"
codesign -dvvv -r- "$bundle"

rollback="$stage/previous.app"
if [[ -e "$destination" ]]; then mv "$destination" "$rollback"; fi
if ! (mv "$bundle" "$destination" && verify "$destination"); then
    if [[ -e "$destination" ]]; then mv "$destination" "$bundle"; fi
    if [[ -d "$rollback" ]] && ! mv "$rollback" "$destination"; then
        trap - EXIT
        print -u2 "Previous build retained at $rollback"
    fi
    exit 1
fi
print -r -- "$destination"
