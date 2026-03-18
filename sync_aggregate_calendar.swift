//
// Sync Aggregate Calendar V2
//
// This script incrementally merges events from multiple calendars into a
// single destination calendar called "Aggregate".
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
// V2 behavior:
//   - Window: today through the next 365 days
//   - Incremental sync instead of full rebuild
//   - Creates missing events
//   - Updates changed events in place
//   - Deletes destination events whose source event disappeared
//   - Avoids duplicates by tracking source identifiers in event notes
//   - Distinguishes recurring event occurrences by occurrence date
//
// Recompile command (run in Terminal):
// swiftc "/Users/Art/Library/Mobile Documents/com~apple~CloudDocs/Software/Sync Aggregate Calendar/sync_aggregate_calendar_v2.swift" -o ~/bin/sync_aggregate_calendar
//
// Run command:
// ~/bin/sync_aggregate_calendar
//

import Foundation
import EventKit
import CryptoKit

let store = EKEventStore()

enum MergeMode: String {
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

struct NormalizedEvent {
    let sourceSpec: SourceSpec
    let sourceEvent: EKEvent
    let sourceKey: String
    let fingerprint: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let title: String
    let location: String?
    let notes: String
}

struct ManagedMetadata {
    let sourceKey: String
    let fingerprint: String
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

let managedByValue = "sync_aggregate_calendar_v2"

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

func sha256(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func sanitized(_ string: String?) -> String {
    (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    return raw.isEmpty ? nil : raw
}

func shouldExcludeEvent(_ event: EKEvent, for spec: SourceSpec) -> Bool {
    guard !spec.excludedOrganizerEmails.isEmpty else { return false }
    guard let email = organizerEmail(for: event) else { return false }
    return spec.excludedOrganizerEmails.contains(email)
}

func normalizedTitle(for sourceEvent: EKEvent, mode: MergeMode) -> String {
    switch mode {
    case .full:
        return sanitized(sourceEvent.title).isEmpty ? "[untitled]" : sanitized(sourceEvent.title)
    case .busy:
        return "Work"
    }
}

func normalizedLocation(for sourceEvent: EKEvent, mode: MergeMode) -> String? {
    switch mode {
    case .full:
        let loc = sanitized(sourceEvent.location)
        return loc.isEmpty ? nil : loc
    case .busy:
        return nil
    }
}

func occurrenceDiscriminator(for event: EKEvent) -> String {
    let date = event.occurrenceDate ?? event.startDate
    return iso(date)
}

func buildSourceKey(for sourceEvent: EKEvent, spec: SourceSpec) -> String {
    let externalID = sanitized(sourceEvent.calendarItemExternalIdentifier)
    let localID = sanitized(sourceEvent.calendarItemIdentifier)
    let occurrence = occurrenceDiscriminator(for: sourceEvent)

    if !externalID.isEmpty {
        return "acct=\(spec.sourceTitle)|cal=\(spec.title)|ext=\(externalID)|occ=\(occurrence)"
    }

    return "acct=\(spec.sourceTitle)|cal=\(spec.title)|loc=\(localID)|occ=\(occurrence)"
}

func buildFingerprint(
    for sourceEvent: EKEvent,
    spec: SourceSpec,
    title: String,
    location: String?,
    organizerEmail: String?
) -> String {
    let payload = [
        "mode=\(spec.mode.rawValue)",
        "start=\(iso(sourceEvent.startDate))",
        "end=\(iso(sourceEvent.endDate))",
        "allDay=\(sourceEvent.isAllDay)",
        "title=\(title)",
        "location=\(location ?? "")",
        "organizer=\(organizerEmail ?? "")"
    ].joined(separator: "\n")

    return sha256(payload)
}

func normalizedNotes(
    for sourceEvent: EKEvent,
    spec: SourceSpec,
    sourceKey: String,
    fingerprint: String
) -> String {
    let organizer = organizerEmail(for: sourceEvent) ?? ""
    let externalIdentifier = sanitized(sourceEvent.calendarItemExternalIdentifier)
    let occurrence = occurrenceDiscriminator(for: sourceEvent)

    switch spec.mode {
    case .full:
        return """
managedBy=\(managedByValue)
sourceCalendar=\(spec.title)
sourceAccount=\(spec.sourceTitle)
sourceKey=\(sourceKey)
sourceIdentifier=\(sourceEvent.calendarItemIdentifier)
sourceExternalIdentifier=\(externalIdentifier)
sourceFingerprint=\(fingerprint)
mode=full
isAllDay=\(sourceEvent.isAllDay)
occurrence=\(occurrence)
organizerEmail=\(organizer)
syncedAt=\(iso(Date()))
"""
    case .busy:
        return """
managedBy=\(managedByValue)
sourceCalendar=\(spec.title)
sourceAccount=\(spec.sourceTitle)
sourceKey=\(sourceKey)
sourceIdentifier=\(sourceEvent.calendarItemIdentifier)
sourceExternalIdentifier=\(externalIdentifier)
sourceFingerprint=\(fingerprint)
mode=busy
redacted=true
isAllDay=\(sourceEvent.isAllDay)
occurrence=\(occurrence)
organizerEmail=\(organizer)
syncedAt=\(iso(Date()))
"""
    }
}

func parseManagedMetadata(from notes: String?) -> ManagedMetadata? {
    guard let notes else { return nil }

    var managedBy: String?
    var sourceKey: String?
    var fingerprint: String?

    for rawLine in notes.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("managedBy=") {
            managedBy = String(line.dropFirst("managedBy=".count))
        } else if line.hasPrefix("sourceKey=") {
            sourceKey = String(line.dropFirst("sourceKey=".count))
        } else if line.hasPrefix("sourceFingerprint=") {
            fingerprint = String(line.dropFirst("sourceFingerprint=".count))
        }
    }

    guard managedBy == managedByValue, let sourceKey, let fingerprint else {
        return nil
    }

    return ManagedMetadata(sourceKey: sourceKey, fingerprint: fingerprint)
}

func normalizeEvent(_ sourceEvent: EKEvent, spec: SourceSpec) -> NormalizedEvent {
    let normalizedTitleValue = normalizedTitle(for: sourceEvent, mode: spec.mode)
    let normalizedLocationValue = normalizedLocation(for: sourceEvent, mode: spec.mode)
    let organizer = organizerEmail(for: sourceEvent)
    let sourceKey = buildSourceKey(for: sourceEvent, spec: spec)
    let fingerprint = buildFingerprint(
        for: sourceEvent,
        spec: spec,
        title: normalizedTitleValue,
        location: normalizedLocationValue,
        organizerEmail: organizer
    )
    let notes = normalizedNotes(
        for: sourceEvent,
        spec: spec,
        sourceKey: sourceKey,
        fingerprint: fingerprint
    )

    return NormalizedEvent(
        sourceSpec: spec,
        sourceEvent: sourceEvent,
        sourceKey: sourceKey,
        fingerprint: fingerprint,
        startDate: sourceEvent.startDate,
        endDate: sourceEvent.endDate,
        isAllDay: sourceEvent.isAllDay,
        title: normalizedTitleValue,
        location: normalizedLocationValue,
        notes: notes
    )
}

func apply(_ normalized: NormalizedEvent, to destinationEvent: EKEvent) {
    destinationEvent.startDate = normalized.startDate
    destinationEvent.endDate = normalized.endDate
    destinationEvent.isAllDay = normalized.isAllDay
    destinationEvent.title = normalized.title
    destinationEvent.location = normalized.location
    destinationEvent.notes = normalized.notes
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
    let calendarSystem = Calendar.current
    let start = calendarSystem.startOfDay(for: Date())
    let end = calendarSystem.date(byAdding: .day, value: syncDays, to: start)!

    let destination = findCalendar(title: destinationTitle, sourceTitle: destinationSourceTitle)

    var normalizedBySourceKey: [String: NormalizedEvent] = [:]

    var skippedAllDayCount = 0
    var skippedOrganizerCount = 0
    var duplicateSourceKeyCount = 0

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

            let normalized = normalizeEvent(sourceEvent, spec: spec)

            if normalizedBySourceKey[normalized.sourceKey] != nil {
                duplicateSourceKeyCount += 1
            }

            normalizedBySourceKey[normalized.sourceKey] = normalized
        }
    }

    let destPredicate = store.predicateForEvents(withStart: start, end: end, calendars: [destination])
    let destinationEvents = store.events(matching: destPredicate).sorted { $0.startDate < $1.startDate }

    var managedDestinationBySourceKey: [String: EKEvent] = [:]
    var duplicateManagedDestinationCount = 0

    for destEvent in destinationEvents {
        if let metadata = parseManagedMetadata(from: destEvent.notes) {
            if managedDestinationBySourceKey[metadata.sourceKey] != nil {
                do {
                    try store.remove(destEvent, span: .thisEvent, commit: false)
                    duplicateManagedDestinationCount += 1
                } catch {
                    fail("ERROR removing duplicate managed destination event '\(destEvent.title ?? "[untitled]")': \(error.localizedDescription)")
                }
            } else {
                managedDestinationBySourceKey[metadata.sourceKey] = destEvent
            }
        } else {
            // Leave non-managed events alone.
        }
    }

    let sourceKeys = Set(normalizedBySourceKey.keys)
    let managedKeys = Set(managedDestinationBySourceKey.keys)

    let keysToCreate = sourceKeys.subtracting(managedKeys)
    let keysToDelete = managedKeys.subtracting(sourceKeys)
    let keysToCheckForUpdate = sourceKeys.intersection(managedKeys)

    var createdCount = 0
    var updatedCount = 0
    var unchangedCount = 0
    var deletedCount = 0

    for key in keysToDelete {
        guard let destEvent = managedDestinationBySourceKey[key] else { continue }
        do {
            try store.remove(destEvent, span: .thisEvent, commit: false)
            deletedCount += 1
        } catch {
            fail("ERROR deleting orphaned destination event '\(destEvent.title ?? "[untitled]")': \(error.localizedDescription)")
        }
    }

    for key in keysToCreate {
        guard let normalized = normalizedBySourceKey[key] else { continue }

        let newEvent = EKEvent(eventStore: store)
        newEvent.calendar = destination
        apply(normalized, to: newEvent)

        do {
            try store.save(newEvent, span: .thisEvent, commit: false)
            createdCount += 1
        } catch {
            fail("ERROR creating destination event for source key '\(key)': \(error.localizedDescription)")
        }
    }

    for key in keysToCheckForUpdate {
        guard let normalized = normalizedBySourceKey[key] else { continue }
        guard let destEvent = managedDestinationBySourceKey[key] else { continue }

        guard let metadata = parseManagedMetadata(from: destEvent.notes) else {
            fail("ERROR: Managed destination event missing metadata for source key '\(key)'.")
        }

        if metadata.fingerprint == normalized.fingerprint {
            unchangedCount += 1
            continue
        }

        apply(normalized, to: destEvent)

        do {
            try store.save(destEvent, span: .thisEvent, commit: false)
            updatedCount += 1
        } catch {
            fail("ERROR updating destination event '\(destEvent.title ?? "[untitled]")': \(error.localizedDescription)")
        }
    }

    do {
        try store.commit()
    } catch {
        fail("ERROR committing changes: \(error.localizedDescription)")
    }

    print("Incremental sync complete.")
    print("Created in \(destinationTitle): \(createdCount)")
    print("Updated in \(destinationTitle): \(updatedCount)")
    print("Deleted from \(destinationTitle): \(deletedCount)")
    print("Unchanged in \(destinationTitle): \(unchangedCount)")
    print("Skipped all-day events: \(skippedAllDayCount)")
    print("Skipped organizer-filtered events: \(skippedOrganizerCount)")
    print("Duplicate source keys seen: \(duplicateSourceKeyCount)")
    print("Duplicate managed destination events removed: \(duplicateManagedDestinationCount)")
    print("Window: \(iso(start)) -> \(iso(end))")
    exit(0)
}

requestAccessAndRun()
RunLoop.main.run()