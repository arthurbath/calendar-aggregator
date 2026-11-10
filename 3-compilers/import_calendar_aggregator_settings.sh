#!/bin/zsh
set -euo pipefail
umask 077

repo_dir=${0:A:h:h}
if (( $# != 1 )); then
    print -u2 "Usage: ${0:t} /path/to/calendar-aggregator-settings.json"
    exit 64
fi
personalized="${PERSONALIZED_DIR:-$repo_dir/2-personalized}/sync_aggregate_calendar.swift"
if [[ ! -f "$personalized" ]]; then
    print -u2 "Personalized sync script not found at $personalized"
    exit 66
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/calendar-aggregator-import.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# Compile the configuration declarations without running the legacy EventKit job.
awk '
    /^let sourceSpecs:/ { copying = 1 }
    copying { print }
    copying && /^let managedByValue =/ { complete = 1; exit }
    END { if (!complete) exit 1 }
' "$personalized" > "$scratch/main.swift"
cat >> "$scratch/main.swift" <<'SWIFT'

let imported = SyncSettings(destination: destinationCalendar, sources: sourceSpecs, syncDays: syncDays,
                            busyEventTitle: busyEventTitle, managedByValue: managedByValue)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(imported))
SWIFT
sed -i '' '1i\
import Foundation
' "$scratch/main.swift"
swiftc -module-cache-path "$scratch/cache" \
    "$repo_dir/1-src/CalendarSyncEngine.swift" "$scratch/main.swift" -o "$scratch/export-settings"
"$scratch/export-settings" > "$scratch/settings.json"
# Require a new file so an export cannot overwrite the app's saved settings.
(setopt noclobber; cat "$scratch/settings.json" > "$1")
print "Import the exported file through Calendar Aggregator Settings, then review and save."
