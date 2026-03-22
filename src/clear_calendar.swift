//
// Calendar Scripts: Clear Calendar
//
// This script deletes all events from the configured destination
// calendar in Calendar.app on Mac.
import Foundation
import EventKit

let store = EKEventStore()

// Customize these values to match the calendar you want to clear.
let destinationTitle = "Calendar"
let destinationSourceTitle = "iCloud"

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
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
    let destination = findCalendar(title: destinationTitle, sourceTitle: destinationSourceTitle)
    let predicate = store.predicateForEvents(
        withStart: Date.distantPast,
        end: Date.distantFuture,
        calendars: [destination]
    )
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

    print("Clear complete.")
    print("Deleted from \(destinationTitle): \(deletedCount)")
    exit(0)
}

requestAccessAndRun()
RunLoop.main.run()
