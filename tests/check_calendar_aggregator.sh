#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/calendar-aggregator-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
engine="$repo_dir/1-src/CalendarSyncEngine.swift"
cp "$repo_dir/1-src/sync_aggregate_calendar.swift" "$scratch/main.swift"
swiftc -module-cache-path "$scratch/cache" "$engine" "$scratch/main.swift" -o "$scratch/sync"

swiftc -module-cache-path "$scratch/cache" -parse-as-library "$engine" \
    "$repo_dir/macos/CalendarAggregator/LocalSettings.swift" "$repo_dir/tests/CalendarAggregatorChecks.swift" \
    -o "$scratch/checks"
"$scratch/checks" "$scratch" "$@"
