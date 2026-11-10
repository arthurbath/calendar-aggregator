## Why

The aggregate calendar job currently requires editing Swift and recompiling to change which event details it copies or where it writes them.

## What Changes

- Add Calendar Aggregator, a native menu bar app with the Lucide calendar-sync icon.
- Let users select source and destination calendars by account, control title visibility and all-day events per source, and save changes in the app.
- Provide on-demand and 15-minute sync, optional Open at Login, and a guarded transition from the existing LaunchAgent.

## Capabilities

### New Capabilities

- `calendar-aggregator`: Configures, runs, and monitors aggregate calendar sync from the menu bar.

### Modified Capabilities

None.

## Impact

Reuses the EventKit sync logic and existing event ownership markers. The standalone scripts remain usable, including the manual Clear Calendar tool. Building the app does not change the installed job.
