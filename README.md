# Calendar Scripts

These Swift scripts automate Calendar.app tasks on macOS:
- `1-src/sync_aggregate_calendar.swift`: Merges multiple source calendars into one destination calendar.
- `1-src/clear_calendar.swift`: Removes all events from the destination calendar.
- `1-src/enforce_alerts.swift`: Ensures upcoming events across one or more calendars have their required alerts.

## Configure & Compile

The numbered folders reflect the intended setup order:

1. `1-src/`: Generic example scripts.
1. `2-personalized/`: Your private configured copies.
1. `3-compilers/`: Build scripts that compile from `2-personalized/`.
1. `4-dist/`: Generated apps and LaunchAgent plists.

1. Copy the script you want from `1-src/` into `2-personalized/`.
1. Edit the `USER CONFIGURATION` section in that personalized copy.
1. Run the script's matching compiler script in `3-compilers/`. The compiler scripts write executables to `4-dist/apps/`. The sync and alert compilers also generate LaunchAgent plist files in `4-dist/launchd/` for interval-based runs.

## Install on macOS

1. Copy the compiled executables from `4-dist/apps/` to `~/Applications/`.
1. If you want a script to run on an interval, copy its generated plist from `4-dist/launchd/` to `~/Library/LaunchAgents/`, then load it:
```bash
launchctl unload "$HOME/Library/LaunchAgents/<label>.plist" 2>/dev/null
launchctl load "$HOME/Library/LaunchAgents/<label>.plist"
```

The generated plists expect the installed executables to live in `~/Applications/` and write logs to `~/Library/Logs/`.

On first run, macOS will ask for Calendar access.
