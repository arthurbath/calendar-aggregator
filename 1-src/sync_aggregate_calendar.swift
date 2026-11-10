//
// Calendar Scripts: Aggregate Calendar Sync
// Uses the shared CalendarSyncEngine.swift.
//
// This macOS script incrementally merges events from multiple
// Calendar.app calendars into a single destination calendar.
//
// Edit the USER CONFIGURATION section first. That section is where you
// set:
//   - which Calendar.app source calendars to read from
//   - which Calendar.app destination calendar to write to
//   - which calendars should be copied in full vs. shown as "busy" blocks
//   - filters such as all-day-event exclusion and organizer-email exclusion
//
// This works specifically with Calendar.app on Mac through EventKit.
// The calendar names and account/source names must match what
// Calendar.app shows.
import Foundation
import EventKit

// =============================================================================
// USER CONFIGURATION
// =============================================================================
//
// Edit this section first when adapting the script to another Mac,
// account, or set of Calendar.app calendars.
//
// Calendar matching notes:
// - `title` must exactly match the calendar name shown in Calendar.app on Mac.
// - `sourceTitle` must exactly match the account/source name shown in
//   Calendar.app on Mac (for example "iCloud", "Google", or another
//   account name).
//
// Source behavior notes:
// - Use `.full` to copy the event title, location, timing, and all
//   metadata the script stores for change tracking.
// - Use `.busy` to hide source details and create a generic busy block instead.
// - Set `includeAllDayEvents` to `false` to skip all-day events from
//   that source.
// - Add lowercase email addresses to `excludedOrganizerEmails` to
//   ignore events from specific organizers on that source calendar.
//
// Destination behavior notes:
// - The destination calendar is where the merged "Aggregate" events
//   are written.
// - Only events created by this script are modified or removed.
//   Other events in the destination calendar are left alone.
//
// Advanced note:
// - Leave `managedByValue` alone unless you intentionally want the
//   script to stop recognizing previously synced events and recreate
//   them.

let sourceSpecs: [SourceSpec] = [
    // Personal calendar: copy events in full.
    .init(
        title: "Personal",
        sourceTitle: "iCloud",
        mode: .full,
        includeAllDayEvents: true,
        excludedOrganizerEmails: []
    ),

    // Shared calendar: copy events in full.
    .init(
        title: "Family",
        sourceTitle: "Google",
        mode: .full,
        includeAllDayEvents: true,
        excludedOrganizerEmails: []
    ),

    // Work calendar: publish only generic busy blocks.
    .init(
        title: "Work",
        sourceTitle: "Exchange",
        mode: .busy,
        includeAllDayEvents: false,
        excludedOrganizerEmails: ["noreply@example.com"]
    )
]

// Destination calendar that receives the merged events.
let destinationCalendar = CalendarReference(title: "Aggregate", sourceTitle: "iCloud")

// Busy-mode events use this title instead of the source event title.
let busyEventTitle = "Busy"

// Number of days ahead to sync, starting from the beginning of today.
let syncDays = 365

// Internal marker written into destination event notes so the script can tell
// which events it owns on later runs.
let managedByValue = "sync_aggregate_calendar_v2"

let store = EKEventStore()
let settings = SyncSettings(destination: destinationCalendar, sources: sourceSpecs, syncDays: syncDays,
                            busyEventTitle: busyEventTitle, managedByValue: managedByValue)

func completeSync(granted: Bool, error: Error?) {
    do {
        if let error { throw error }
        guard granted else { throw SyncError("Calendar access was not granted.") }
        let report = try runCalendarSync(store: store, settings: settings)
        report.logLines.forEach { print($0) }
        exit(0)
    } catch {
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents(completion: completeSync)
} else {
    store.requestAccess(to: .event, completion: completeSync)
}
RunLoop.main.run()
