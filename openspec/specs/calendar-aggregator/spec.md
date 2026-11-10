# calendar-aggregator Specification

## Purpose
TBD - created by archiving change add-calendar-aggregator. Update Purpose after archive.
## Requirements
### Requirement: Configure aggregate calendar sync

Calendar Aggregator SHALL persist a writable destination and one or more source calendars selected from Calendar accounts. For each source it SHALL allow the user to reveal event titles or supply a replacement title, and to include or exclude all-day events. It SHALL preserve organizer filters and the sync window in saved settings when the user edits unrelated options.

#### Scenario: Save settings for two source accounts

- **WHEN** the user selects a personal and a work calendar, sets a replacement title for work events, excludes all-day events from that source, and saves
- **THEN** the settings survive relaunch and the next sync uses the work title and all-day rules for that source only

#### Scenario: Destination is invalid

- **WHEN** the selected destination disappears, is read-only, or is also selected as a source
- **THEN** the app refuses to sync and identifies the configuration problem

### Requirement: Reconcile copied events

The app SHALL reconcile events within the configured window using the legacy ownership and source keys. It SHALL preserve independently created events, remove stale copies within the window, and write only to the selected destination. Replacement-title copies SHALL omit the original title and location.

#### Scenario: Change a title rule

- **WHEN** the user saves a different title rule and syncs again
- **THEN** the existing copies receive the new titles without duplicating those events

#### Scenario: Change the destination calendar

- **WHEN** the user saves a different destination and syncs
- **THEN** sync writes to the new destination and leaves the previous destination alone

### Requirement: Run and monitor sync from the menu bar

Calendar Aggregator SHALL use Lucide's calendar-sync icon in the macOS menu bar. It SHALL offer Sync Now, Automatic Sync, status including the last successful sync, and Open at Login. Automatic sync SHALL run on startup and every 15 minutes while enabled. Runs SHALL be serialized and require full Calendar access.

The popover SHALL place Sync Now with sync status, followed by a Configuration section above Automatic Sync and Open at Login. Configuration SHALL show the number of configured source calendars and the destination name and account. The popover SHALL open a separate window for edits and place Quit in a gear menu.

#### Scenario: Show the last successful event count

- **WHEN** a sync succeeds for the current configuration
- **THEN** the Configuration section shows the number of events added, updated, or already current within the sync window
- **AND** the count survives relaunch and is withheld after a configuration change until another sync succeeds

#### Scenario: A sync is already running

- **WHEN** a timer fires or the user requests another sync during a run
- **THEN** the app starts no overlapping run

### Requirement: Retire the legacy scheduler safely

The app SHALL block sync while the existing aggregate LaunchAgent is present or loaded. After the user grants Calendar access, saves valid settings, and confirms the handoff, the app SHALL retain the old plist for recovery and unload the legacy job before permitting its own sync.

#### Scenario: Handoff fails

- **WHEN** the legacy job cannot be unloaded or its plist cannot be moved to recovery
- **THEN** the app reports the failure and does not begin syncing alongside the legacy job
