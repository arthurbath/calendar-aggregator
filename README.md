# Calendar Aggregator

Calendar Aggregator is a macOS menu bar app that syncs events from multiple source calendars into one destination. For each source, choose whether to show event titles or replace them, and whether to include all-day events.

## Build and Set Up

Build the signed app with:

```sh
./3-compilers/build_calendar_aggregator.sh
```

The build is written to `~/Library/Caches/garden.bath.calendar-aggregator/build/Calendar Aggregator.app`. Copy the app into Applications before enabling Open at Login.

Open Calendar Aggregator from the menu bar and grant full Calendar access. In **Configuration**, choose **Edit** to select your destination and source calendars, set the rules for each source, and save.

For a fresh setup, turn on **Automatic Sync**. If the previous job is installed, choose **Replace Previous Sync Job** instead. The app starts its 15-minute schedule after retiring the old job and saving its plist under `~/Library/Application Support/Calendar Aggregator/Legacy LaunchAgents/`.

## Supporting Utilities

### Clear Calendar

[Clear Calendar](1-src/clear_calendar.swift) is a manual development utility for resetting a destination calendar. It removes events from the calendar named in its private configuration, including events added directly to that calendar.

### Legacy Sync Command

The [standalone sync command](1-src/sync_aggregate_calendar.swift) uses the same sync engine as the app and remains available for existing command-line setups. Use the menu bar app for regular sync.

### Build the Utilities

The numbered folders show the setup order for the standalone tools:

1. `1-src/`: Generic example scripts.
1. `2-personalized/`: Your private configured copies.
1. `3-compilers/`: Build scripts that compile from `2-personalized/`.
1. `4-dist/`: Generated apps and LaunchAgent plists.

1. Copy the script you want from `1-src/` into `2-personalized/`.
1. Edit the `USER CONFIGURATION` section in that personalized copy.
1. Run the script's matching compiler script in `3-compilers/`. The compiler scripts write executables to `4-dist/apps/`. The sync compiler also generates a LaunchAgent plist in `4-dist/launchd/` for interval-based runs.

### Install a Standalone Utility

1. Copy the compiled executables from `4-dist/apps/` to `~/Applications/`.
1. For an existing setup that uses the legacy sync schedule, copy its generated plist from `4-dist/launchd/` to `~/Library/LaunchAgents/`, then load it:
```bash
launchctl unload "$HOME/Library/LaunchAgents/<label>.plist" 2>/dev/null
launchctl load "$HOME/Library/LaunchAgents/<label>.plist"
```

The legacy LaunchAgent runs the executable in `~/Applications/` and writes logs to `~/Library/Logs/`.

On first run, macOS will ask for Calendar access.
