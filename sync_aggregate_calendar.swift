//
// Sync Aggregate Calendar
//
// This script merges events from multiple calendars into a single
// destination calendar called "Aggregate".
//
// Source calendars:
//   - Calendar (iCloud)  -> full event details
//   - Partiful (iCloud)  -> full event details
//   - Calendar (Google)  -> full event details
//   - Calendar (USGBC)   -> busy blocks only ("Work"), all-day events excluded,
//                           excludes organizer noreply@adp.com
//
// Destination calendar:
//   - Aggregate (Google)
//
// Sync behavior:
//   - Window: today through the next 365 days
//   - Deletes all events in the Aggregate calendar within that window
//   - Rebuilds them from the source calendars
//   - Used by a launchd job that runs every 15 minutes
//
// Recompile command (run in Terminal):
// swiftc "/Users/Art/Library/Mobile Documents/com~apple~CloudDocs/Software/Sync Aggregate Calendar/sync_aggregate_calendar.swift" -o ~/bin/sync_aggregate_calendar
//
// Run command:
// ~/bin/sync_aggregate_calendar
//

import Foundation
import EventKit

let store = EKEventStore()

enum MergeMode {
    case full
    case busy
}

struct SourceSpec {
    let title: String
    let sourceTitle: String
    let mode: MergeMode
    let includeAllDayEvents: Bool
    let excludedOrganizerEmails: Set<String>
}

let sourceSpecs: [SourceSpec] = [
    .init(
        title: "Calendar",
        sourceTitle: "iCloud",
        mode: .full,
        includeAllDayEvents: true,
        excludedOrganizerEmails: []
    ),
    .init(
        title: "Partiful",
        sourceTitle: "iCloud",
        mode: .full,
        includeAllDayEvents: true,
        excludedOrganizerEmails: []
    ),
    .init(
        title: "Calendar",
        sourceTitle: "Google",
        mode: .full,
        includeAllDayEvents: true,
        excludedOrganizerEmails: []
    ),
    .init(
        title: "Calendar",
        sourceTitle: "USGBC",
        mode: .busy,
        includeAllDayEvents: false,
        excludedOrganizerEmails: ["noreply@adp.com"]
    )
]

let destinationTitle = "Aggregate"
let destinationSourceTitle = "Google"
let syncDays = 365

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func iso(_ date: Date?) -> String {
    guard let date else { return "[nil]" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func findCalendar(title: String, sourceTitle: String) -> EKCalendar {
    let matches = store.calendars(for: .event).filter {
        $0.title == title && $0.source.title == sourceTitle
    }

    if matches.isEmpty {
        fail("ERROR: Could not find calendar '\(title)' from source '\(sourceTitle)'.")
    }

    if matches.count > 1 {
        let details = matches.map { "\($0.title) | source=\($0.source.title)" }.joined(separator: "\n")
        fail("ERROR: Multiple matching calendars found:\n\(details)")
    }

    return matches[0]
}

func organizerEmail(for event: EKEvent) -> String? {
    guard let organizer = event.organizer else { return nil }

    let raw = organizer.url.absoluteString
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if raw.hasPrefix("mailto:") {
        return String(raw.dropFirst("mailto:".count))
    }

    return raw
}

func shouldExcludeEvent(_ event: EKEvent, for spec: SourceSpec) -> Bool {
    guard !spec.excludedOrganizerEmails.isEmpty else { return false }
    guard let email = organizerEmail(for: event) else { return false }

    return spec.excludedOrganizerEmails.contains(email)
}

func normalizedTitle(for sourceEvent: EKEvent, mode: MergeMode) -> String {
    switch mode {
    case .full:
        return sourceEvent.title ?? "[untitled]"
    case .busy:
        return "Work"
    }
}

func normalizedLocation(for sourceEvent: EKEvent, mode: MergeMode) -> String? {
    switch mode {
    case .full:
        return sourceEvent.location
    case .busy:
        return nil
    }
}

func normalizedNotes(for sourceEvent: EKEvent, spec: SourceSpec) -> String {
    let organizer = organizerEmail(for: sourceEvent) ?? ""

    switch spec.mode {
    case .full:
        return """
sourceCalendar=\(spec.title)
sourceAccount=\(spec.sourceTitle)
sourceIdentifier=\(sourceEvent.calendarItemIdentifier)
mode=full
isAllDay=\(sourceEvent.isAllDay)
organizerEmail=\(organizer)
syncedAt=\(iso(Date()))
"""
    case .busy:
        return """
sourceCalendar=\(spec.title)
sourceAccount=\(spec.sourceTitle)
sourceIdentifier=\(sourceEvent.calendarItemIdentifier)
mode=busy
redacted=true
isAllDay=\(sourceEvent.isAllDay)
organizerEmail=\(organizer)
syncedAt=\(iso(Date()))
"""
    }
}

func requestAccessAndRun() {
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { granted, error in
            if let error = error {
                fail("ERROR: \(error.localizedDescription)")
            }
            guard granted else {
                fail("ERROR: Calendar access was not granted.")
            }
            runSync()
        }
    } else {
        store.requestAccess(to: .event) { granted, error in
            if let error = error {
                fail("ERROR: \(error.localizedDescription)")
            }
            guard granted else {
                fail("ERROR: Calendar access was not granted.")
            }
            runSync()
        }
    }
}

func runSync() {
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: syncDays, to: start)!

    let destination = findCalendar(title: destinationTitle, sourceTitle: destinationSourceTitle)

    // Delete everything currently in the destination calendar in the sync window.
    let destPredicate = store.predicateForEvents(withStart: start, end: end, calendars: [destination])
    let existingDestinationEvents = store.events(matching: destPredicate)

    var removedCount = 0
    for event in existingDestinationEvents {
        do {
            try store.remove(event, span: .thisEvent, commit: false)
            removedCount += 1
        } catch {
            fail("ERROR removing destination event '\(event.title ?? "[untitled]")': \(error.localizedDescription)")
        }
    }

    // Rebuild from sources.
    var createdCount = 0
    var skippedAllDayCount = 0
    var skippedOrganizerCount = 0

    for spec in sourceSpecs {
        let sourceCalendar = findCalendar(title: spec.title, sourceTitle: spec.sourceTitle)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [sourceCalendar])
        let sourceEvents = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        for sourceEvent in sourceEvents {
            if sourceEvent.isAllDay && !spec.includeAllDayEvents {
                skippedAllDayCount += 1
                continue
            }

            if shouldExcludeEvent(sourceEvent, for: spec) {
                skippedOrganizerCount += 1
                continue
            }

            let newEvent = EKEvent(eventStore: store)
            newEvent.calendar = destination
            newEvent.startDate = sourceEvent.startDate
            newEvent.endDate = sourceEvent.endDate
            newEvent.isAllDay = sourceEvent.isAllDay
            newEvent.title = normalizedTitle(for: sourceEvent, mode: spec.mode)
            newEvent.location = normalizedLocation(for: sourceEvent, mode: spec.mode)
            newEvent.notes = normalizedNotes(for: sourceEvent, spec: spec)

            do {
                try store.save(newEvent, span: .thisEvent, commit: false)
                createdCount += 1
            } catch {
                fail("ERROR saving event '\(sourceEvent.title ?? "[untitled]")' from '\(spec.title)': \(error.localizedDescription)")
            }
        }
    }

    do {
        try store.commit()
    } catch {
        fail("ERROR committing changes: \(error.localizedDescription)")
    }

    print("Sync complete.")
    print("Removed from \(destinationTitle): \(removedCount)")
    print("Created in \(destinationTitle): \(createdCount)")
    print("Skipped all-day events: \(skippedAllDayCount)")
    print("Skipped organizer-filtered events: \(skippedOrganizerCount)")
    print("Window: \(iso(start)) -> \(iso(end))")
    exit(0)
}

requestAccessAndRun()
RunLoop.main.run()