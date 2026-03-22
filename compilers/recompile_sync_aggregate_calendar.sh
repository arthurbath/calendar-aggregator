#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
source_file="$repo_dir/src/sync_aggregate_calendar.swift"
dist_dir=${DIST_DIR:-"$repo_dir/dist"}
dist_bin_dir="$dist_dir/bin"
launchd_dir="$dist_dir/launchd"
install_bin_dir=${INSTALL_BIN_DIR:-"$HOME/bin"}
log_dir=${INSTALL_LOG_DIR:-"$HOME/Library/Logs"}
label="com.art.sync_aggregate_calendar"
plist_path="$launchd_dir/$label.plist"
start_interval=${START_INTERVAL_SECONDS:-900}

mkdir -p "$dist_bin_dir" "$launchd_dir"
swiftc "$source_file" -o "$dist_bin_dir/sync_aggregate_calendar"

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$install_bin_dir/sync_aggregate_calendar</string>
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
