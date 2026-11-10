import AppKit
import EventKit
import Foundation

@main
enum CalendarAggregatorChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let storage = LocalSettings(directory: root.appending(path: "support"))
        let work = CalendarChoice(id: "work", title: "Calendar", account: "Work", writable: false)
        let target = CalendarChoice(id: "aggregate", title: "Aggregate", account: "Personal", writable: true)
        var spec = SourceSpec(title: "Calendar", sourceTitle: "Work", mode: .busy, includeAllDayEvents: false,
                              excludedOrganizerEmails: ["ignored@example.test"], identifier: work.id)
        var settings = SyncSettings(destination: target.reference, sources: [spec], busyEventTitle: "Work")

        let empty = try storage.load()
        precondition(empty.sources.isEmpty && !empty.automaticSync)
        try storage.save(settings)
        let reloaded = try storage.load()
        precondition(reloaded == settings)
        let selection = try CalendarSelection(settings: reloaded, choices: [work, target])
        precondition(selection.destination.id == target.id && selection.sources.map(\.id) == [work.id])

        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Private title"
        event.location = "Private location"
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(900)
        let legacy = normalizeEvent(event, spec: spec, settings: settings)
        precondition(legacy.title == "Work" && legacy.location == nil)
        precondition(!legacy.notes.contains("Private title") && !legacy.notes.contains("Private location"))
        let metadata = parseManagedMetadata(from: legacy.notes, managedByValue: settings.managedByValue)
        precondition(metadata?.sourceKey == legacy.sourceKey)
        precondition(parseManagedMetadata(from: "Notes from a manually added event",
                                         managedByValue: settings.managedByValue) == nil)
        spec.replacementTitle = "  In a meeting  "
        let replaced = normalizeEvent(event, spec: spec, settings: settings)
        precondition(replaced.title == "In a meeting" && replaced.sourceKey == legacy.sourceKey)
        precondition(replaced.fingerprint != legacy.fingerprint)
        spec.mode = .full
        let revealed = normalizeEvent(event, spec: spec, settings: settings)
        precondition(revealed.title == "Private title" && revealed.location == "Private location")
        precondition(revealed.sourceKey == legacy.sourceKey)

        settings.destination = work.reference
        rejects { try CalendarSelection(settings: settings, choices: [work, target]) }
        settings.destination = target.reference
        let replacement = CalendarChoice(id: "different", title: "Aggregate", account: "Personal", writable: true)
        rejects { try CalendarSelection(settings: settings, choices: [work, replacement]) }
        settings.destination = CalendarReference(title: "Aggregate", sourceTitle: "Personal")
        rejects { try CalendarSelection(settings: settings, choices: [work, target, replacement]) }
        settings.destination = target.reference
        settings.sources[0].replacementTitle = " "
        rejects { try CalendarSelection(settings: settings, choices: [work, target]) }

        try checkSyncCoverage()
        try checkHandoff(at: root)
        if CommandLine.arguments.count > 2 {
            let artwork = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let image = NSImage(contentsOf: artwork.appending(path: "calendar-sync.svg"))
            precondition(image?.isValid == true && image?.size == NSSize(width: 24, height: 24))
            precondition(FileManager.default.fileExists(atPath: artwork.appending(path: "Assets.car").path))
        }
        print("Calendar settings, event normalization, and legacy scheduler checks passed.")
    }

    private static func rejects<T>(_ action: () throws -> T) {
        do {
            _ = try action()
            preconditionFailure("Expected validation to reject the operation.")
        } catch {}
    }

    private static func checkSyncCoverage() throws {
        let completed = Date(timeIntervalSince1970: 1_800_000_000.125)
        var report = SyncReport(start: completed, end: completed, destinationTitle: "Aggregate")
        report.created = 3
        report.updated = 2
        report.unchanged = 40
        report.deleted = 7
        report.duplicateCopies = 1

        // Settings saved before counts were introduced have no configuration revision.
        var settings = SyncSettings(destination: CalendarReference(title: "Aggregate", sourceTitle: "Personal"))
        let coverage = SyncCoverage(completedAt: completed, configurationRevision: settings.configurationRevision,
                                    eventCount: report.syncedEventCount)
        let data = try PropertyListEncoder().encode(coverage)
        let reloaded = try PropertyListDecoder().decode(SyncCoverage.self, from: data)
        precondition(reloaded.count(for: settings, lastSync: completed) == 45)
        precondition(reloaded.count(for: settings, lastSync: completed.addingTimeInterval(900)) == nil)
        settings.automaticSync = true
        precondition(reloaded.count(for: settings, lastSync: completed) == 45)
        settings.configurationRevision = UUID()
        precondition(reloaded.count(for: settings, lastSync: completed) == nil)
    }

    private static func checkHandoff(at root: URL) throws {
        let plist = root.appending(path: "legacy.plist")
        let backups = root.appending(path: "backups")
        let bytes = Data("legacy configuration".utf8)
        try bytes.write(to: plist)
        var loaded = true
        var refuseUnload = true
        var activated = false
        let scheduler = LegacyScheduler(plist: plist, backupDirectory: backups, domain: "gui/test") { arguments in
            switch arguments[0] {
            case "print": return loaded ? 0 : 113
            case "bootout":
                if refuseUnload { return 1 }
                loaded = false
                return 0
            case "bootstrap":
                precondition(FileManager.default.fileExists(atPath: plist.path))
                loaded = true
                return 0
            default: preconditionFailure("Unexpected launchctl command.")
            }
        }
        rejects { try scheduler.retire { activated = true } }
        let restoredAfterUnloadFailure = try Data(contentsOf: plist)
        precondition(!activated && loaded && restoredAfterUnloadFailure == bytes)

        refuseUnload = false
        rejects { try scheduler.retire { throw SyncError("Could not write settings.") } }
        let restoredAfterSaveFailure = try Data(contentsOf: plist)
        precondition(!activated && loaded && restoredAfterSaveFailure == bytes)

        try scheduler.retire {
            let present = try scheduler.isPresent()
            precondition(!present)
            activated = true
        }
        let retained = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        precondition(activated && !loaded && !FileManager.default.fileExists(atPath: plist.path) && retained.count == 1)
        let backup = try Data(contentsOf: retained[0])
        precondition(backup == bytes)
    }
}
