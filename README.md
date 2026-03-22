# Calendar Scripts

These Swift scripts automate Calendar.app tasks on macOS:

- `src/sync_aggregate_calendar.swift`: merges multiple source calendars into one destination calendar.
- `src/cleanup_aggregate_calendar.swift`: removes events from the destination calendar inside the sync window.
- `src/enforce_exchange_alerts.swift`: ensures upcoming events in one calendar have the required alert.

## Configure And Compile

Edit the `USER CONFIGURATION` section in the source file you want to use, then run its matching compiler script in `compilers/`.

The compiler scripts write binaries to `dist/bin/`. The sync and alert compilers also generate LaunchAgent plist files in `dist/launchd/` for interval-based runs.

## Install On macOS

Copy the compiled binaries from `dist/bin/` to `~/bin/`.

If you want a script to run on an interval, copy its generated plist from `dist/launchd/` to `~/Library/LaunchAgents/`, then load it:

```bash
launchctl unload "$HOME/Library/LaunchAgents/<label>.plist" 2>/dev/null
launchctl load "$HOME/Library/LaunchAgents/<label>.plist"
```

The generated plists expect the installed binaries to live in `~/bin/` and write logs to `~/Library/Logs/`.

On first run, macOS will ask for Calendar access. `cleanup_aggregate_calendar` is the destructive one, so it is usually best run manually.
