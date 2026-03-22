#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
source_file="$repo_dir/src/cleanup_aggregate_calendar.swift"
dist_dir=${DIST_DIR:-"$repo_dir/dist"}
dist_bin_dir="$dist_dir/bin"

mkdir -p "$dist_bin_dir"
swiftc "$source_file" -o "$dist_bin_dir/cleanup_aggregate_calendar"
