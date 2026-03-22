#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
personalized_dir=${PERSONALIZED_DIR:-"$repo_dir/personalized"}
source_file="$personalized_dir/cleanup_aggregate_calendar.swift"
dist_dir=${DIST_DIR:-"$repo_dir/dist"}
dist_bin_dir="$dist_dir/bin"

if [[ ! -f "$source_file" ]]; then
    print -u2 "Missing $source_file"
    print -u2 "Copy src/cleanup_aggregate_calendar.swift into personalized/ and edit it before compiling."
    exit 1
fi

mkdir -p "$dist_bin_dir"
swiftc "$source_file" -o "$dist_bin_dir/cleanup_aggregate_calendar"
