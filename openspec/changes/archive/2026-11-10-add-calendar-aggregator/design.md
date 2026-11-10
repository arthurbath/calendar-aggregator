## Context

The existing executable writes to one calendar from multiple sources. Its source key and fingerprint in each copied event allow later runs to reconcile copies without touching independently created events.

## Decisions

- Use the same engine for the app and the generic Swift script. Preserve the source keys, fingerprints, and ownership marker of the existing configuration.
- Store settings as a local, atomic JSON file. Store EventKit calendar identifiers for newly selected calendars. Resolve older settings by exact calendar and account names and require a unique match.
- Import the configured values from a personalized legacy Swift source through a local conversion command. Import places the values in the settings editor for review.
- Start with automatic sync paused on a fresh setup. Require full Calendar access and a valid configuration before enabling sync. Require confirmation to retire the old LaunchAgent, retain its plist for recovery, and block both manual and scheduled runs while that agent is installed or loaded.
- Update only the selected destination. Changing the destination leaves previously copied events in the former destination.
- Sign the app bundle with the personal code-signing identity under `garden.bath.calendar-aggregator`. The Clear Calendar script retains its own identity and workflow.
