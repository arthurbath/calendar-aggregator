# Calendar Scripts

These Swift scripts automate Calendar.app tasks on macOS:

- `src/sync_aggregate_calendar.swift`: merges multiple source calendars into one destination calendar.
- `src/clear_calendar.swift`: removes all events from the destination calendar.
- `src/enforce_exchange_alerts.swift`: ensures upcoming events in one calendar have the required alert.

The files in `src/` are generic examples. To use a script, copy it into `personalized/`, edit the copy there, and leave your private calendar names and account details out of `src/`.

## Configure And Compile

Copy the script you want from `src/` into `personalized/`, edit the `USER CONFIGURATION` section in that personalized copy, then run its matching compiler script in `compilers/`.

The compiler scripts write executables to `dist/apps/`. The sync and alert compilers also generate LaunchAgent plist files in `dist/launchd/` for interval-based runs.

## Install On macOS

Copy the compiled executables from `dist/apps/` to `~/Applications/`.

If you want a script to run on an interval, copy its generated plist from `dist/launchd/` to `~/Library/LaunchAgents/`, then load it:

```bash
launchctl unload "$HOME/Library/LaunchAgents/<label>.plist" 2>/dev/null
launchctl load "$HOME/Library/LaunchAgents/<label>.plist"
```

The generated plists expect the installed executables to live in `~/Applications/` and write logs to `~/Library/Logs/`.

On first run, macOS will ask for Calendar access. `clear_calendar` is the destructive one, so it is usually best run manually.
