# Calendar Scripts

This repo contains Swift scripts for maintaining a merged "Aggregate"
calendar in Calendar.app on macOS using EventKit.

The main script, `sync_aggregate_calendar.swift`, reads events from
multiple Calendar.app source calendars and incrementally syncs them into
a single Calendar.app destination calendar. It is designed for setups
where some calendars should be copied in full and others should appear
only as generic busy blocks.

The helper script, `cleanup_aggregate_calendar.swift`, deletes events
from the Calendar.app destination calendar across the configured sync
window. It is useful if you want to reset the aggregate calendar before
testing or after changing sync logic.

The utility script, `enforce_exchange_alerts.swift`, scans a single
Calendar.app calendar for events in the next 30 days and ensures each
event has a 5-minute alert. It is intended for Exchange calendars where
you want a background job to enforce a consistent alert policy.

This is specifically a Calendar.app-for-Mac workflow. The configured
calendar names and account/source names must match what Calendar.app
shows on that Mac.

## What The Sync Script Does

`sync_aggregate_calendar.swift`:

- reads events from each configured Calendar.app source calendar between
  today and `syncDays` days in the future
- skips source events you have configured to exclude, such as all-day
  events or events from specific organizer email addresses
- normalizes each event into either:
  - a full copy of the event details, or
  - a generic busy block with a custom title such as `"Work"`
- writes only to the configured Calendar.app destination calendar
- tracks which destination events it owns by storing metadata in the event notes
- updates existing managed events in place when source events change
- deletes managed destination events whose source events disappeared
- leaves non-managed destination events alone

The script also distinguishes recurring-event occurrences by occurrence
date, which helps it treat each instance as a separate sync target.

## Configuration

Open [`sync_aggregate_calendar.swift`](./sync_aggregate_calendar.swift)
and start at the `USER CONFIGURATION` section near the top.

These are the fields you are expected to edit:

- `sourceSpecs`: the source calendars to read from
- `destinationCalendar`: the calendar that receives merged events
- `busyEventTitle`: the title to use for `.busy` sources
- `syncDays`: how far ahead to sync

Each `sourceSpecs` entry supports:

- `title`: the calendar name exactly as shown in Calendar.app on Mac
- `sourceTitle`: the account/source name exactly as shown in Calendar.app on Mac
- `mode`: `.full` to copy event details, `.busy` to redact them into a
  generic block
- `includeAllDayEvents`: whether all-day events from that source should
  be included
- `excludedOrganizerEmails`: organizer email addresses to skip for that source

`managedByValue` is also near the top, but it is an internal marker.
Do not change it unless you intentionally want the script to stop
matching events created by earlier runs.

## How It Works Internally

1. The script requests calendar access through EventKit.
2. It finds each configured Calendar.app source calendar and the
   destination calendar by exact `title` and `sourceTitle` match.
3. It loads events inside the sync window.
4. It builds a stable source key for each event using the calendar
   identity plus the source event identifier and occurrence date.
5. It builds a fingerprint from the event details that matter for syncing.
6. It scans the destination calendar for events previously managed by
   this script.
7. It computes which events need to be created, updated, deleted, or
   left unchanged.
8. It commits the batch and prints a summary.

Managed destination events are tagged in their notes with metadata such as:

- the source calendar and account
- the source key
- the source fingerprint
- the sync mode
- the organizer email
- the last sync timestamp

That metadata is what allows the script to run incrementally instead of
rebuilding the destination calendar from scratch every time.

## Build And Run

From this repo directory:

```bash
swiftc sync_aggregate_calendar.swift -o ~/bin/sync_aggregate_calendar
swiftc cleanup_aggregate_calendar.swift -o ~/bin/cleanup_aggregate_calendar
```

If you compile from outside the repo directory, use `$HOME` in the
quoted path rather than `~`, because `zsh` does not expand `~` inside
double quotes:

```bash
swiftc "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Software/Calendar Scripts/sync_aggregate_calendar.swift" -o "$HOME/bin/sync_aggregate_calendar"
swiftc "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Software/Calendar Scripts/cleanup_aggregate_calendar.swift" -o "$HOME/bin/cleanup_aggregate_calendar"
```

Run the sync:

```bash
~/bin/sync_aggregate_calendar
```

Run the cleanup helper:

```bash
~/bin/cleanup_aggregate_calendar
```

On first run, macOS will prompt for Calendar access. Grant access so
EventKit can read and write your Calendar.app events.

## Notes And Safety

- The sync script only modifies destination events that contain its
  `managedByValue` marker.
- Other events already present in the destination calendar are preserved.
- If two source events resolve to the same computed source key, the last
  one processed wins and the script reports a duplicate count.
- The cleanup helper is destructive for the destination calendar inside
  the sync window. Use it carefully.

## Exchange Alert Enforcer

`enforce_exchange_alerts.swift`:

- reads one configured Calendar.app calendar between now and
  `lookAheadDays` days in the future
- skips canceled events
- skips all-day events by default, because a 5-minute alert is usually
  not useful for all-day blocks
- treats recurring series once instead of modifying every future
  occurrence separately
- checks whether each event already has a 5-minute alert
- adds the alert if it is missing
- replaces a non-matching alert if
  `replaceExistingAlertsWhenMissing` is `true`

This script is designed around Exchange behavior in Calendar.app, where
events can have only one alert.

### Configure

Open [`enforce_exchange_alerts.swift`](./enforce_exchange_alerts.swift)
and edit the `USER CONFIGURATION` section:

- `targetCalendar`: the calendar name and account/source name exactly as
  shown in Calendar.app
- `lookAheadDays`: how far ahead to scan
- `requiredAlertOffsetSeconds`: the alert offset relative to event start
- `replaceExistingAlertsWhenMissing`: whether to replace a non-5-minute
  alert with the required 5-minute alert
- `includeAllDayEvents`: whether all-day events should also be forced to
  have the alert
- `dryRun`: print what would change without saving anything

### Build And Run

```bash
swiftc enforce_exchange_alerts.swift -o ~/bin/enforce_exchange_alerts
~/bin/enforce_exchange_alerts
```

If you compile from outside the repo directory:

```bash
swiftc "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Software/Calendar Scripts/enforce_exchange_alerts.swift" -o "$HOME/bin/enforce_exchange_alerts"
```

On first run, macOS will prompt for Calendar access. Grant access so
EventKit can inspect and update your Calendar.app events.

### Run Every 15 Minutes With launchd

An example LaunchAgent template is included at
[`launchd/com.art.enforce_exchange_alerts.plist.example`](./launchd/com.art.enforce_exchange_alerts.plist.example).

To use it:

1. Replace `REPLACE_WITH_YOUR_USERNAME` with your macOS username.
2. Save the file as
   `~/Library/LaunchAgents/com.art.enforce_exchange_alerts.plist`.
3. Load it:

```bash
launchctl unload ~/Library/LaunchAgents/com.art.enforce_exchange_alerts.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.art.enforce_exchange_alerts.plist
```

This LaunchAgent runs the compiled binary every 900 seconds
(15 minutes), and also once at load time.
