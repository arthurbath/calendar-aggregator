#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
personalized_dir=${PERSONALIZED_DIR:-"$repo_dir/2-personalized"}
source_file="$personalized_dir/sync_aggregate_calendar.swift"
dist_dir=${DIST_DIR:-"$repo_dir/4-dist"}
dist_app_dir="$dist_dir/apps"
launchd_dir="$dist_dir/launchd"
app_name="Sync Aggregate Calendar"
install_app_dir=${INSTALL_APP_DIR:-"$HOME/Applications"}
log_dir=${INSTALL_LOG_DIR:-"$HOME/Library/Logs"}
label="garden.bath.sync-aggregate-calendar"
plist_path="$launchd_dir/$label.plist"
start_interval=${START_INTERVAL_SECONDS:-900}

if [[ ! -f "$source_file" ]]; then
    print -u2 "Missing $source_file"
    print -u2 "Copy 1-src/sync_aggregate_calendar.swift into 2-personalized/ and edit it before compiling."
    exit 1
fi

mkdir -p "$dist_app_dir" "$launchd_dir"
swiftc "$source_file" -o "$dist_app_dir/$app_name"

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$install_app_dir/$app_name</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>$start_interval</integer>
    <key>StandardOutPath</key>
    <string>$log_dir/sync_aggregate_calendar.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/sync_aggregate_calendar.log</string>
</dict>
</plist>
EOF
