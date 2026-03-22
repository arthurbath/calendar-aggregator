//
// Calendar Scripts: Cleanup Aggregate Calendar
//
// This script deletes all events from today through the next 365 days
// from the configured destination calendar in Calendar.app on Mac.
import Foundation
import EventKit

let store = EKEventStore()

let destinationTitle = "Aggregate"
let destinationSourceTitle = "iCloud"
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

func requestAccessAndRun() {
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { granted, error in
            if let error = error {
                fail("ERROR: \(error.localizedDescription)")
            }
            guard granted else {
                fail("ERROR: Calendar access was not granted.")
            }
            runCleanup()
        }
    } else {
        store.requestAccess(to: .event) { granted, error in
            if let error = error {
                fail("ERROR: \(error.localizedDescription)")
            }
            guard granted else {
                fail("ERROR: Calendar access was not granted.")
            }
            runCleanup()
        }
    }
}

func runCleanup() {
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: syncDays, to: start)!

    let destination = findCalendar(title: destinationTitle, sourceTitle: destinationSourceTitle)
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [destination])
    let existingEvents = store.events(matching: predicate)

    var deletedCount = 0

    for event in existingEvents {
        do {
            try store.remove(event, span: .thisEvent, commit: false)
            deletedCount += 1
        } catch {
            fail("ERROR removing event '\(event.title ?? "[untitled]")': \(error.localizedDescription)")
        }
    }

    do {
        try store.commit()
    } catch {
        fail("ERROR committing deletions: \(error.localizedDescription)")
    }

    print("Cleanup complete.")
    print("Deleted from \(destinationTitle): \(deletedCount)")
    print("Window: \(iso(start)) -> \(iso(end))")
    exit(0)
}

requestAccessAndRun()
RunLoop.main.run()
