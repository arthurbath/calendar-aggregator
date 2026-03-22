//
// Enforce Exchange Calendar Alerts
//
// This macOS script scans one Calendar.app calendar for events that occur
// between now and the next 30 days and ensures each event has a 5-minute
// alert. For Exchange calendars, Calendar.app allows only one alert per
// event, so the default behavior is to replace any non-matching alert with
// a 5-minute alert.
//
// Edit the USER CONFIGURATION section first.
//
// Recompile script (local, ignored by git):
// ./.local/recompile_enforce_exchange_alerts.sh
//
// Run command:
// "$HOME/bin/enforce_exchange_alerts"
//

import Foundation
import EventKit

let store = EKEventStore()

struct CalendarReference {
    let title: String
    let sourceTitle: String
}

// =============================================================================
// USER CONFIGURATION
// =============================================================================
//
// Calendar matching notes:
// - `title` must exactly match the calendar name shown in Calendar.app on Mac.
// - `sourceTitle` must exactly match the account/source name shown in
//   Calendar.app on Mac.
//
// Alert behavior notes:
// - Exchange events can have only one alert, so when
//   `replaceExistingAlertsWhenMissing` is `true`, the script removes any
//   existing non-matching alerts before adding the required one.
// - `requiredAlertOffsetSeconds` is relative to the event start date. Use
//   `-300` for "5 minutes before".
// - All-day events are skipped by default because a "5 minutes before" alert
//   usually does not make sense for an all-day block.

let targetCalendar = CalendarReference(title: "Calendar", sourceTitle: "USGBC")
let lookAheadDays = 30
let requiredAlertOffsetSeconds: TimeInterval = -300
let replaceExistingAlertsWhenMissing = true
let includeAllDayEvents = false
let dryRun = false

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

func stableIdentifier(for event: EKEvent) -> String {
    let externalID = event.calendarItemExternalIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !externalID.isEmpty {
        return externalID
    }
    return event.calendarItemIdentifier
}

func isRecurringSeriesEvent(_ event: EKEvent) -> Bool {
    if let recurrenceRules = event.recurrenceRules, !recurrenceRules.isEmpty {
        return true
    }
    return event.occurrenceDate != nil
}

func hasRequiredAlert(_ event: EKEvent) -> Bool {
    for alarm in event.alarms ?? [] {
        if let absoluteDate = alarm.absoluteDate {
            let offset = absoluteDate.timeIntervalSince(event.startDate)
            if abs(offset - requiredAlertOffsetSeconds) < 1 {
                return true
            }
            continue
        }

        if abs(alarm.relativeOffset - requiredAlertOffsetSeconds) < 1 {
            return true
        }
    }

    return false
}

func applyRequiredAlert(to event: EKEvent) {
    if replaceExistingAlertsWhenMissing {
        for alarm in event.alarms ?? [] {
            event.removeAlarm(alarm)
        }
    }

    event.addAlarm(EKAlarm(relativeOffset: requiredAlertOffsetSeconds))
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
            runEnforcement()
        }
    } else {
        store.requestAccess(to: .event) { granted, error in
            if let error = error {
                fail("ERROR: \(error.localizedDescription)")
            }
            guard granted else {
                fail("ERROR: Calendar access was not granted.")
            }
            runEnforcement()
        }
    }
}

func runEnforcement() {
    let calendarSystem = Calendar.current
    let start = Date()
    let end = calendarSystem.date(byAdding: .day, value: lookAheadDays, to: start)!

    let calendar = findCalendar(title: targetCalendar.title, sourceTitle: targetCalendar.sourceTitle)

    guard calendar.allowsContentModifications else {
        fail("ERROR: Calendar '\(targetCalendar.title)' from '\(targetCalendar.sourceTitle)' does not allow content modifications.")
    }

    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
    let events = store.events(matching: predicate).sorted { lhs, rhs in
        lhs.startDate < rhs.startDate
    }

    var seenRecurringSeries = Set<String>()

    var scannedCount = 0
    var updatedCount = 0
    var alreadyCorrectCount = 0
    var replacedExistingAlertCount = 0
    var addedMissingAlertCount = 0
    var skippedAllDayCount = 0
    var skippedCanceledCount = 0
    var skippedPastEndCount = 0
    var skippedRecurringDuplicateCount = 0
    var skippedExistingNonMatchingAlertCount = 0
    var failedUpdateCount = 0

    for event in events {
        scannedCount += 1

        if event.status == .canceled {
            skippedCanceledCount += 1
            continue
        }

        if event.endDate <= start {
            skippedPastEndCount += 1
            continue
        }

        if event.isAllDay && !includeAllDayEvents {
            skippedAllDayCount += 1
            continue
        }

        let isRecurring = isRecurringSeriesEvent(event)
        if isRecurring {
            let seriesKey = stableIdentifier(for: event)
            if seenRecurringSeries.contains(seriesKey) {
                skippedRecurringDuplicateCount += 1
                continue
            }
            seenRecurringSeries.insert(seriesKey)
        }

        if hasRequiredAlert(event) {
            alreadyCorrectCount += 1
            continue
        }

        let existingAlertCount = (event.alarms ?? []).count
        if existingAlertCount > 0 && !replaceExistingAlertsWhenMissing {
            skippedExistingNonMatchingAlertCount += 1
            continue
        }

        if dryRun {
            updatedCount += 1
            if existingAlertCount == 0 {
                addedMissingAlertCount += 1
            } else {
                replacedExistingAlertCount += 1
            }
            continue
        }

        applyRequiredAlert(to: event)

        let span: EKSpan = isRecurring ? .futureEvents : .thisEvent

        do {
            try store.save(event, span: span, commit: false)
            updatedCount += 1
            if existingAlertCount == 0 {
                addedMissingAlertCount += 1
            } else {
                replacedExistingAlertCount += 1
            }
        } catch {
            failedUpdateCount += 1
            fputs(
                "WARN: Could not update '\(event.title ?? "[untitled]")' starting \(iso(event.startDate)): \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    if !dryRun {
        do {
            try store.commit()
        } catch {
            fail("ERROR committing alert updates: \(error.localizedDescription)")
        }
    }

    print(dryRun ? "Dry run complete." : "Alert enforcement complete.")
    print("Calendar: \(targetCalendar.title) @ \(targetCalendar.sourceTitle)")
    print("Window: \(iso(start)) -> \(iso(end))")
    print("Scanned events: \(scannedCount)")
    print("Updated events: \(updatedCount)")
    print("Added missing 5-minute alerts: \(addedMissingAlertCount)")
    print("Replaced non-matching alerts: \(replacedExistingAlertCount)")
    print("Already correct: \(alreadyCorrectCount)")
    print("Skipped all-day events: \(skippedAllDayCount)")
    print("Skipped canceled events: \(skippedCanceledCount)")
    print("Skipped already-ended events: \(skippedPastEndCount)")
    print("Skipped duplicate recurring occurrences: \(skippedRecurringDuplicateCount)")
    print("Skipped non-matching existing alerts: \(skippedExistingNonMatchingAlertCount)")
    print("Failed updates: \(failedUpdateCount)")
    exit(failedUpdateCount == 0 ? 0 : 2)
}

requestAccessAndRun()
RunLoop.main.run()
