//
// Calendar Scripts: Enforce Alerts
//
// This macOS script scans one or more Calendar.app calendars for events that
// occur between now and the next N days and ensures each calendar's required
// alert is present on every event.
//
// The script is provider-agnostic. It first tries to add the required alert
// alongside any existing alerts. If Calendar.app rejects that save, it retries
// by replacing the event's existing alerts with the required one.
//
// Edit the USER CONFIGURATION section first.
import Foundation
import EventKit

let store = EKEventStore()

struct CalendarReference: Hashable {
    let title: String
    let sourceTitle: String
}

struct AlertRule {
    let title: String
    let sourceTitle: String
    let requiredAlertMinutesBeforeStart: Int
    let excludeAllDayEvents: Bool
    let replaceExistingAlerts: Bool

    var calendar: CalendarReference {
        CalendarReference(title: title, sourceTitle: sourceTitle)
    }
}

struct RuleStats {
    var scannedCount = 0
    var updatedCount = 0
    var alreadyCorrectCount = 0
    var addedToEmptyEventCount = 0
    var addedAlongsideExistingAlertCount = 0
    var replacedExistingAlertCount = 0
    var dryRunWouldAttemptAlongsideExistingAlertCount = 0
    var dryRunWouldReplaceExistingAlertCount = 0
    var skippedAllDayCount = 0
    var skippedCanceledCount = 0
    var skippedPastEndCount = 0
    var failedUpdateCount = 0

    mutating func absorb(_ other: RuleStats) {
        scannedCount += other.scannedCount
        updatedCount += other.updatedCount
        alreadyCorrectCount += other.alreadyCorrectCount
        addedToEmptyEventCount += other.addedToEmptyEventCount
        addedAlongsideExistingAlertCount += other.addedAlongsideExistingAlertCount
        replacedExistingAlertCount += other.replacedExistingAlertCount
        dryRunWouldAttemptAlongsideExistingAlertCount += other.dryRunWouldAttemptAlongsideExistingAlertCount
        dryRunWouldReplaceExistingAlertCount += other.dryRunWouldReplaceExistingAlertCount
        skippedAllDayCount += other.skippedAllDayCount
        skippedCanceledCount += other.skippedCanceledCount
        skippedPastEndCount += other.skippedPastEndCount
        failedUpdateCount += other.failedUpdateCount
    }
}

// =============================================================================
// USER CONFIGURATION
// =============================================================================
//
// Calendar matching notes:
// - `title` must exactly match the calendar name shown in Calendar.app on Mac.
// - `sourceTitle` must exactly match the account/source name shown in
//   Calendar.app on Mac (for example "iCloud", "Google", "Exchange", or
//   another account name).
//
// Alert behavior notes:
// - `requiredAlertMinutesBeforeStart` is the required alert timing for that
//   calendar. Use `5` for "5 minutes before".
// - Set `excludeAllDayEvents` to `true` to skip all-day events for that
//   calendar.
// - Set `replaceExistingAlerts` to `true` when you want the calendar to keep
//   only the required alert on each event. This is safer for providers that do
//   not reliably preserve multiple alerts, such as some Exchange calendars.
// - If Calendar.app allows multiple alerts on the event, the script keeps the
//   existing alerts and adds the required one when `replaceExistingAlerts` is
//   `false`.
// - If Calendar.app rejects an additional alert, the script retries by
//   replacing the event's existing alerts with the required one.
// - All-day events are often excluded because a minutes-before-start alert may
//   not make sense for an all-day block.

let alertRules: [AlertRule] = [
    .init(
        title: "Work",
        sourceTitle: "Exchange",
        requiredAlertMinutesBeforeStart: 5,
        excludeAllDayEvents: true,
        replaceExistingAlerts: true
    ),
    .init(
        title: "Personal",
        sourceTitle: "iCloud",
        requiredAlertMinutesBeforeStart: 10,
        excludeAllDayEvents: false,
        replaceExistingAlerts: false
    ),
    .init(
        title: "Family",
        sourceTitle: "Google",
        requiredAlertMinutesBeforeStart: 15,
        excludeAllDayEvents: true,
        replaceExistingAlerts: false
    )
]

let lookAheadDays = 30
let dryRun = false

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func makeError(_ message: String) -> NSError {
    NSError(
        domain: "CalendarScripts.EnforceAlerts",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

func iso(_ date: Date?) -> String {
    guard let date else { return "[nil]" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func describeCalendar(_ calendar: CalendarReference) -> String {
    "\(calendar.title) @ \(calendar.sourceTitle)"
}

func describeRequiredAlert(minutesBeforeStart: Int) -> String {
    if minutesBeforeStart == 0 {
        return "at start"
    }

    let unit = minutesBeforeStart == 1 ? "minute" : "minutes"
    return "\(minutesBeforeStart) \(unit) before start"
}

func describeAllDayBehavior(excludeAllDayEvents: Bool) -> String {
    excludeAllDayEvents ? "exclude all-day events" : "include all-day events"
}

func describeExistingAlertBehavior(replaceExistingAlerts: Bool) -> String {
    replaceExistingAlerts ? "replace existing alerts" : "add alongside existing alerts when possible"
}

func requiredAlertOffsetSeconds(for rule: AlertRule) -> TimeInterval {
    TimeInterval(-rule.requiredAlertMinutesBeforeStart * 60)
}

func validateConfiguration() {
    guard !alertRules.isEmpty else {
        fail("ERROR: Configure at least one alert rule in alertRules.")
    }

    var seenCalendars = Set<CalendarReference>()

    for rule in alertRules {
        guard rule.requiredAlertMinutesBeforeStart >= 0 else {
            fail(
                "ERROR: requiredAlertMinutesBeforeStart must be zero or greater for \(describeCalendar(rule.calendar))."
            )
        }

        guard seenCalendars.insert(rule.calendar).inserted else {
            fail("ERROR: Duplicate alert rule configured for \(describeCalendar(rule.calendar)).")
        }
    }
}

func findCalendar(reference: CalendarReference) -> EKCalendar {
    let matches = store.calendars(for: .event).filter {
        $0.title == reference.title && $0.source.title == reference.sourceTitle
    }

    if matches.isEmpty {
        fail("ERROR: Could not find calendar '\(reference.title)' from source '\(reference.sourceTitle)'.")
    }

    if matches.count > 1 {
        let details = matches.map { "\($0.title) | source=\($0.source.title)" }.joined(separator: "\n")
        fail("ERROR: Multiple matching calendars found:\n\(details)")
    }

    return matches[0]
}

func hasRequiredAlert(_ event: EKEvent, requiredAlertOffsetSeconds: TimeInterval) -> Bool {
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

func clearExistingAlerts(from event: EKEvent) {
    for alarm in event.alarms ?? [] {
        event.removeAlarm(alarm)
    }
}

func addRequiredAlert(to event: EKEvent, requiredAlertOffsetSeconds: TimeInterval) {
    event.addAlarm(EKAlarm(relativeOffset: requiredAlertOffsetSeconds))
}

func saveReplacementAlertOnFreshEvent(
    calendarItemIdentifier: String,
    requiredAlertOffsetSeconds: TimeInterval,
    span: EKSpan
) throws {
    let retryStore = EKEventStore()

    guard let freshEvent = retryStore.calendarItem(withIdentifier: calendarItemIdentifier) as? EKEvent else {
        throw makeError("Could not reload event for replacement retry.")
    }

    clearExistingAlerts(from: freshEvent)
    addRequiredAlert(to: freshEvent, requiredAlertOffsetSeconds: requiredAlertOffsetSeconds)
    try retryStore.save(freshEvent, span: span, commit: true)
}

func warnUpdateFailure(for event: EKEvent, errors: [String]) {
    let detail = errors.joined(separator: " | ")
    fputs(
        "WARN: Could not update '\(event.title ?? "[untitled]")' starting \(iso(event.startDate)): \(detail)\n",
        stderr
    )
}

func processRule(
    _ rule: AlertRule,
    calendar: EKCalendar,
    start: Date,
    end: Date
) -> RuleStats {
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
    let events = store.events(matching: predicate).sorted { lhs, rhs in
        lhs.startDate < rhs.startDate
    }

    let requiredAlertOffsetSeconds = requiredAlertOffsetSeconds(for: rule)
    var stats = RuleStats()

    for event in events {
        stats.scannedCount += 1

        if event.status == .canceled {
            stats.skippedCanceledCount += 1
            continue
        }

        if event.endDate <= start {
            stats.skippedPastEndCount += 1
            continue
        }

        if event.isAllDay && rule.excludeAllDayEvents {
            stats.skippedAllDayCount += 1
            continue
        }

        if hasRequiredAlert(event, requiredAlertOffsetSeconds: requiredAlertOffsetSeconds) {
            stats.alreadyCorrectCount += 1
            continue
        }

        let existingAlertCount = (event.alarms ?? []).count

        if dryRun {
            stats.updatedCount += 1
            if existingAlertCount == 0 {
                stats.addedToEmptyEventCount += 1
            } else if rule.replaceExistingAlerts {
                stats.dryRunWouldReplaceExistingAlertCount += 1
            } else {
                stats.dryRunWouldAttemptAlongsideExistingAlertCount += 1
            }
            continue
        }

        if existingAlertCount == 0 || rule.replaceExistingAlerts {
            if existingAlertCount > 0 {
                clearExistingAlerts(from: event)
            }
            addRequiredAlert(to: event, requiredAlertOffsetSeconds: requiredAlertOffsetSeconds)

            do {
                try store.save(event, span: .thisEvent, commit: true)
                stats.updatedCount += 1
                stats.addedToEmptyEventCount += 1
                if existingAlertCount > 0 {
                    stats.addedToEmptyEventCount -= 1
                    stats.replacedExistingAlertCount += 1
                }
            } catch {
                stats.failedUpdateCount += 1
                warnUpdateFailure(for: event, errors: [error.localizedDescription])
            }

            continue
        }

        addRequiredAlert(to: event, requiredAlertOffsetSeconds: requiredAlertOffsetSeconds)

        do {
            try store.save(event, span: .thisEvent, commit: true)
            stats.updatedCount += 1
            stats.addedAlongsideExistingAlertCount += 1
        } catch let preserveError {
            do {
                try saveReplacementAlertOnFreshEvent(
                    calendarItemIdentifier: event.calendarItemIdentifier,
                    requiredAlertOffsetSeconds: requiredAlertOffsetSeconds,
                    span: .thisEvent
                )
                stats.updatedCount += 1
                stats.replacedExistingAlertCount += 1
            } catch {
                stats.failedUpdateCount += 1
                warnUpdateFailure(
                    for: event,
                    errors: [
                        "add-alongside failed: \(preserveError.localizedDescription)",
                        "replacement retry failed: \(error.localizedDescription)"
                    ]
                )
            }
        }
    }

    return stats
}

func printStats(_ stats: RuleStats, for rule: AlertRule, windowStart: Date, windowEnd: Date) {
    print("Calendar: \(describeCalendar(rule.calendar))")
    print("Required alert: \(describeRequiredAlert(minutesBeforeStart: rule.requiredAlertMinutesBeforeStart))")
    print("All-day behavior: \(describeAllDayBehavior(excludeAllDayEvents: rule.excludeAllDayEvents))")
    print("Existing-alert behavior: \(describeExistingAlertBehavior(replaceExistingAlerts: rule.replaceExistingAlerts))")
    print("Window: \(iso(windowStart)) -> \(iso(windowEnd))")
    print("Scanned events: \(stats.scannedCount)")
    print(dryRun ? "Would update events: \(stats.updatedCount)" : "Updated events: \(stats.updatedCount)")
    print("Already correct: \(stats.alreadyCorrectCount)")
    print(
        dryRun
            ? "Would add alert to events with no alerts: \(stats.addedToEmptyEventCount)"
            : "Added alert to events with no alerts: \(stats.addedToEmptyEventCount)"
    )
    print(
        dryRun
            ? "Would replace existing alerts: \(stats.dryRunWouldReplaceExistingAlertCount)"
            : "Replaced existing alerts: \(stats.replacedExistingAlertCount)"
    )
    print(
        dryRun
            ? "Would try to add alongside existing alerts: \(stats.dryRunWouldAttemptAlongsideExistingAlertCount)"
            : "Added alert alongside existing alerts: \(stats.addedAlongsideExistingAlertCount)"
    )

    print("Skipped all-day events: \(stats.skippedAllDayCount)")
    print("Skipped canceled events: \(stats.skippedCanceledCount)")
    print("Skipped already-ended events: \(stats.skippedPastEndCount)")
    print("Failed updates: \(stats.failedUpdateCount)")
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
    validateConfiguration()

    let calendarSystem = Calendar.current
    let start = Date()
    let end = calendarSystem.date(byAdding: .day, value: lookAheadDays, to: start)!

    let resolvedCalendars = alertRules.map { rule in
        let calendar = findCalendar(reference: rule.calendar)
        guard calendar.allowsContentModifications else {
            fail("ERROR: Calendar '\(rule.title)' from '\(rule.sourceTitle)' does not allow content modifications.")
        }
        return (rule, calendar)
    }

    var overallStats = RuleStats()
    var failedCalendarCount = 0

    for (index, entry) in resolvedCalendars.enumerated() {
        let stats = processRule(entry.0, calendar: entry.1, start: start, end: end)
        overallStats.absorb(stats)

        if stats.failedUpdateCount > 0 {
            failedCalendarCount += 1
        }

        printStats(stats, for: entry.0, windowStart: start, windowEnd: end)

        if index < resolvedCalendars.count - 1 {
            print("")
        }
    }

    print("")
    print(dryRun ? "Dry run complete." : "Alert enforcement complete.")
    print("Calendars configured: \(resolvedCalendars.count)")
    print("Window: \(iso(start)) -> \(iso(end))")
    print("Overall summary")
    print("Scanned events: \(overallStats.scannedCount)")
    print(dryRun ? "Would update events: \(overallStats.updatedCount)" : "Updated events: \(overallStats.updatedCount)")
    print("Already correct: \(overallStats.alreadyCorrectCount)")
    print("Failed updates: \(overallStats.failedUpdateCount)")

    exit(failedCalendarCount == 0 ? 0 : 2)
}

requestAccessAndRun()
RunLoop.main.run()
