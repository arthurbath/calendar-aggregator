#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
personalized_dir=${PERSONALIZED_DIR:-"$repo_dir/2-personalized"}
source_file="$personalized_dir/clear_calendar.swift"
dist_dir=${DIST_DIR:-"$repo_dir/4-dist"}
dist_app_dir="$dist_dir/apps"
app_name="Clear Calendar"
signing_identity=${SIGNING_IDENTITY:-"Art Bath Personal Code Signing"}
signing_identifier="garden.bath.clear-calendar"

if [[ ! -f "$source_file" ]]; then
    print -u2 "Missing $source_file"
    print -u2 "Copy 1-src/clear_calendar.swift into 2-personalized/ and edit it before compiling."
    exit 1
fi

mkdir -p "$dist_app_dir"

if ! security find-identity -v -p codesigning | grep -Fq '"'"$signing_identity"'"'; then
    print -u2 "Missing code-signing identity: $signing_identity"
    print -u2 "The identity and its private key must be available in the login keychain."
    exit 1
fi

temporary_app=$(mktemp "$dist_app_dir/.${app_name}.XXXXXX")
trap 'rm -f "$temporary_app"' EXIT

swiftc "$source_file" -o "$temporary_app"
codesign --force --sign "$signing_identity" --identifier "$signing_identifier" --timestamp=none "$temporary_app"
codesign --verify --strict --verbose=2 "$temporary_app"
codesign -dvvv -r- "$temporary_app"
mv -f "$temporary_app" "$dist_app_dir/$app_name"
trap - EXIT
