import Foundation
import EventKit
import CryptoKit

enum MergeMode: String, Codable {
    case full
    case busy
}

struct CalendarReference: Codable, Hashable {
    let title: String
    let sourceTitle: String
    var identifier: String? = nil

    var label: String { "\(title) · \(sourceTitle)" }
}

struct SourceSpec: Codable, Equatable {
    let title: String
    let sourceTitle: String
    var mode: MergeMode
    var includeAllDayEvents: Bool
    let excludedOrganizerEmails: Set<String>
    var identifier: String? = nil
    var replacementTitle: String? = nil

    var reference: CalendarReference {
        CalendarReference(title: title, sourceTitle: sourceTitle, identifier: identifier)
    }
}

struct SyncSettings: Codable, Equatable {
    var destination: CalendarReference?
    var sources: [SourceSpec] = []
    var syncDays = 365
    var busyEventTitle = "Busy"
    var managedByValue = "sync_aggregate_calendar_v2"
    var automaticSync = false

    func replacement(for spec: SourceSpec) -> String {
        sanitized(spec.replacementTitle ?? busyEventTitle)
    }
}

struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CalendarChoice: Identifiable {
    let id: String
    let reference: CalendarReference
    let writable: Bool

    init(id: String, title: String, account: String, writable: Bool) {
        self.id = id
        self.reference = CalendarReference(title: title, sourceTitle: account, identifier: id)
        self.writable = writable
    }

    init(_ calendar: EKCalendar) {
        self.init(id: calendar.calendarIdentifier, title: calendar.title,
                  account: calendar.source.title, writable: calendar.allowsContentModifications)
    }
}

struct CalendarSelection {
    let destination: CalendarChoice
    let sources: [CalendarChoice]

    init(settings: SyncSettings, choices: [CalendarChoice]) throws {
        guard let target = settings.destination else { throw SyncError("Choose a destination calendar.") }
        guard !settings.sources.isEmpty else { throw SyncError("Add at least one source calendar.") }
        guard settings.syncDays > 0, !sanitized(settings.managedByValue).isEmpty else {
            throw SyncError("The sync window or event ownership marker is invalid.")
        }
        func resolve(_ reference: CalendarReference) throws -> CalendarChoice {
            let matches = choices.filter { choice in
                if let id = reference.identifier { return choice.id == id }
                return choice.reference.title == reference.title && choice.reference.sourceTitle == reference.sourceTitle
            }
            guard let match = matches.first else { throw SyncError("Calendar unavailable: \(reference.label).") }
            guard matches.count == 1 else { throw SyncError("Choose a specific calendar for \(reference.label).") }
            return match
        }

        destination = try resolve(target)
        guard destination.writable else { throw SyncError("The destination calendar is read-only.") }
        sources = try settings.sources.map { spec in
            if spec.mode == .busy && settings.replacement(for: spec).isEmpty {
                throw SyncError("Enter a replacement title for \(spec.reference.label).")
            }
            return try resolve(spec.reference)
        }
        let sourceIDs = Set(sources.map(\.id))
        guard sourceIDs.count == sources.count else { throw SyncError("Select each source calendar only once.") }
        guard !sourceIDs.contains(destination.id) else {
            throw SyncError("Choose a destination that is different from the source calendars.")
        }
    }
}

struct SyncReport {
    let start: Date
    let end: Date
    let destinationTitle: String
    var created = 0
    var updated = 0
    var deleted = 0
    var unchanged = 0
    var skippedAllDay = 0
    var skippedOrganizer = 0
    var duplicateSourceKeys = 0
    var duplicateCopies = 0

    var logLines: [String] {
        [
            "Incremental sync complete.",
            "Created in \(destinationTitle): \(created)",
            "Updated in \(destinationTitle): \(updated)",
            "Deleted from \(destinationTitle): \(deleted)",
            "Unchanged in \(destinationTitle): \(unchanged)",
            "Skipped all-day events: \(skippedAllDay)",
            "Skipped organizer-filtered events: \(skippedOrganizer)",
            "Duplicate source keys seen: \(duplicateSourceKeys)",
            "Duplicate managed destination events removed: \(duplicateCopies)",
            "Window: \(iso(start)) -> \(iso(end))"
        ]
    }
}

struct NormalizedEvent {
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

func normalizedTitle(for sourceEvent: EKEvent, mode: MergeMode, replacement: String) -> String {
    switch mode {
    case .full:
        return sanitized(sourceEvent.title).isEmpty ? "[untitled]" : sanitized(sourceEvent.title)
    case .busy:
        return replacement
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
    fingerprint: String,
    managedByValue: String
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

func parseManagedMetadata(from notes: String?, managedByValue: String) -> ManagedMetadata? {
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

func normalizeEvent(_ sourceEvent: EKEvent, spec: SourceSpec, settings: SyncSettings) -> NormalizedEvent {
    let normalizedTitleValue = normalizedTitle(for: sourceEvent, mode: spec.mode, replacement: settings.replacement(for: spec))
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
        fingerprint: fingerprint,
        managedByValue: settings.managedByValue
    )

    return NormalizedEvent(
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

func runCalendarSync(store: EKEventStore, settings: SyncSettings, now: Date = Date()) throws -> SyncReport {
    let calendars = store.calendars(for: .event)
    let selection = try CalendarSelection(settings: settings, choices: calendars.map(CalendarChoice.init))
    let byID = Dictionary(calendars.map { ($0.calendarIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
    guard let destination = byID[selection.destination.id] else {
        throw SyncError("The destination calendar is unavailable.")
    }

    let calendarSystem = Calendar.current
    let start = calendarSystem.startOfDay(for: now)
    guard let end = calendarSystem.date(byAdding: .day, value: settings.syncDays, to: start) else {
        throw SyncError("The sync window is invalid.")
    }
    var report = SyncReport(start: start, end: end, destinationTitle: destination.title)
    // Discard uncommitted EventKit mutations if any stage fails.
    defer { store.reset() }

    var normalizedBySourceKey: [String: NormalizedEvent] = [:]

    for (spec, choice) in zip(settings.sources, selection.sources) {
        guard let sourceCalendar = byID[choice.id] else {
            throw SyncError("Source calendar unavailable: \(choice.reference.label).")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [sourceCalendar])
        let sourceEvents = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        for sourceEvent in sourceEvents {
            if sourceEvent.isAllDay && !spec.includeAllDayEvents {
                report.skippedAllDay += 1
                continue
            }

            if shouldExcludeEvent(sourceEvent, for: spec) {
                report.skippedOrganizer += 1
                continue
            }

            let normalized = normalizeEvent(sourceEvent, spec: spec, settings: settings)

            if normalizedBySourceKey[normalized.sourceKey] != nil {
                report.duplicateSourceKeys += 1
            }

            normalizedBySourceKey[normalized.sourceKey] = normalized
        }
    }

    let destPredicate = store.predicateForEvents(withStart: start, end: end, calendars: [destination])
    let destinationEvents = store.events(matching: destPredicate).sorted { $0.startDate < $1.startDate }

    var managedDestinationBySourceKey: [String: EKEvent] = [:]

    for destEvent in destinationEvents {
        if let metadata = parseManagedMetadata(from: destEvent.notes, managedByValue: settings.managedByValue) {
            if managedDestinationBySourceKey[metadata.sourceKey] != nil {
                do {
                    try store.remove(destEvent, span: .thisEvent, commit: false)
                    report.duplicateCopies += 1
                } catch {
                    throw SyncError("removing duplicate managed destination event '\(destEvent.title ?? "[untitled]")': \(error.localizedDescription)")
                }
            } else {
                managedDestinationBySourceKey[metadata.sourceKey] = destEvent
            }
        }
    }

    let sourceKeys = Set(normalizedBySourceKey.keys)
    let managedKeys = Set(managedDestinationBySourceKey.keys)

    let keysToCreate = sourceKeys.subtracting(managedKeys)
    let keysToDelete = managedKeys.subtracting(sourceKeys)
    let keysToCheckForUpdate = sourceKeys.intersection(managedKeys)

    for key in keysToDelete {
        guard let destEvent = managedDestinationBySourceKey[key] else { continue }
        do {
            try store.remove(destEvent, span: .thisEvent, commit: false)
            report.deleted += 1
        } catch {
            throw SyncError("deleting orphaned destination event '\(destEvent.title ?? "[untitled]")': \(error.localizedDescription)")
        }
    }

    for key in keysToCreate {
        guard let normalized = normalizedBySourceKey[key] else { continue }

        let newEvent = EKEvent(eventStore: store)
        newEvent.calendar = destination
        apply(normalized, to: newEvent)

        do {
            try store.save(newEvent, span: .thisEvent, commit: false)
            report.created += 1
        } catch {
            throw SyncError("creating destination event for source key '\(key)': \(error.localizedDescription)")
        }
    }

    for key in keysToCheckForUpdate {
        guard let normalized = normalizedBySourceKey[key] else { continue }
        guard let destEvent = managedDestinationBySourceKey[key] else { continue }

        guard let metadata = parseManagedMetadata(from: destEvent.notes, managedByValue: settings.managedByValue) else {
            throw SyncError("Managed destination event missing metadata for source key '\(key)'.")
        }

        if metadata.fingerprint == normalized.fingerprint {
            report.unchanged += 1
            continue
        }

        apply(normalized, to: destEvent)

        do {
            try store.save(destEvent, span: .thisEvent, commit: false)
            report.updated += 1
        } catch {
            throw SyncError("updating destination event '\(destEvent.title ?? "[untitled]")': \(error.localizedDescription)")
        }
    }

    do {
        try store.commit()
    } catch {
        throw SyncError("committing changes: \(error.localizedDescription)")
    }

    return report
}
