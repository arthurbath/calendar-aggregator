import AppKit
import EventKit
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings = SyncSettings()
    @Published private(set) var choices: [CalendarChoice] = []
    @Published private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var requestingAccess = false
    @Published private(set) var legacyPresent = true
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private var lastSyncCoverage: SyncCoverage?
    @Published private(set) var problem: String?

    private let storage = LocalSettings.standard
    private let catalog = EKEventStore()
    private let logger = Logger(subsystem: "garden.bath.calendar-aggregator", category: "sync")
    private var schedulerProblem: String?
    private var settingsProblem: String?
    private var timer: Timer?
    private var started = false
    private let lastSyncKey = "lastSuccessfulSync"
    private let coverageKey = "lastSuccessfulSyncCoverage"

    var hasAccess: Bool { authorization == .fullAccess }

    var destination: CalendarReference? {
        guard let configured = settings.destination else { return nil }
        return choices.first { $0.id == configured.identifier }?.reference ?? configured
    }

    var syncedEventCount: Int? {
        lastSyncCoverage?.count(for: settings, lastSync: lastSync)
    }

    var configurationProblem: String? {
        guard hasAccess else { return "Calendar access is required." }
        if let settingsProblem { return settingsProblem }
        return validate(settings)
    }

    var canSync: Bool { !isSyncing && !legacyPresent && configurationProblem == nil }

    var status: String {
        if isSyncing { return "Syncing…" }
        if !hasAccess { return "Calendar Access Required" }
        if let schedulerProblem { return schedulerProblem }
        if legacyPresent { return "Previous Sync Job Active" }
        if let configurationProblem { return configurationProblem }
        return settings.automaticSync ? "Syncing Every 15 Minutes" : "Automatic Sync Paused"
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            settings = try storage.load()
        } catch {
            settingsProblem = "Could not read the saved configuration. Review and save it again."
        }
        lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        if let data = UserDefaults.standard.data(forKey: coverageKey) {
            lastSyncCoverage = try? PropertyListDecoder().decode(SyncCoverage.self, from: data)
        }
        refresh()
        timer = Timer(timeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutomatically() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        runAutomatically()
    }

    func refresh() {
        let previousAccess = hasAccess
        authorization = EKEventStore.authorizationStatus(for: .event)
        if previousAccess != hasAccess { catalog.reset() }
        choices = hasAccess ? catalog.calendars(for: .event).map(CalendarChoice.init).sorted {
            $0.reference.label.localizedStandardCompare($1.reference.label) == .orderedAscending
        } : []
        loginStatus = SMAppService.mainApp.status
        do {
            legacyPresent = try LegacyScheduler.standard(settings: storage).isPresent()
            schedulerProblem = nil
        } catch {
            legacyPresent = true
            schedulerProblem = error.localizedDescription
        }
    }

    func requestAccess() {
        guard !requestingAccess else { return }
        if authorization == .denied || authorization == .restricted || authorization == .writeOnly {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        requestingAccess = true
        Task {
            defer {
                refresh()
                requestingAccess = false
                runAutomatically()
            }
            do {
                _ = try await catalog.requestFullAccessToEvents()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func validate(_ draft: SyncSettings) -> String? {
        do {
            _ = try CalendarSelection(settings: draft, choices: choices)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func save(_ draft: SyncSettings) throws {
        refresh()
        guard hasAccess else { throw SyncError("Calendar access is required.") }
        let selection = try CalendarSelection(settings: draft, choices: choices)
        var updated = draft
        updated.destination = selection.destination.reference
        for (index, source) in selection.sources.enumerated() {
            updated.sources[index].identifier = source.id
        }
        updated.automaticSync = settings.automaticSync
        updated.configurationRevision = UUID()
        try persist(updated)
        settingsProblem = nil
    }

    func setAutomatic(_ enabled: Bool) {
        refresh()
        guard !enabled || (!legacyPresent && configurationProblem == nil) else { return }
        var updated = settings
        updated.automaticSync = enabled
        do {
            try persist(updated)
            if enabled { runAutomatically() }
        } catch {
            problem = error.localizedDescription
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }

    func replaceLegacyJob() {
        refresh()
        guard legacyPresent && schedulerProblem == nil && configurationProblem == nil else { return }
        do {
            var updated = settings
            updated.automaticSync = true
            try LegacyScheduler.standard(settings: storage).retire {
                try persist(updated)
            }
            refresh()
            runAutomatically()
        } catch {
            problem = error.localizedDescription
            refresh()
        }
    }

    func syncNow() {
        refresh()
        guard canSync else { return }
        let snapshot = settings
        isSyncing = true
        problem = nil
        Task {
            defer { isSyncing = false }
            do {
                let report = try await Task.detached(priority: .utility) {
                    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                        throw SyncError("Calendar access is required.")
                    }
                    guard try !LegacyScheduler.standard(settings: LocalSettings.standard).isPresent() else {
                        throw SyncError("The previous Calendar sync job is active.")
                    }
                    return try runCalendarSync(store: EKEventStore(), settings: snapshot)
                }.value
                let completed = Date()
                let coverage = SyncCoverage(completedAt: completed, configurationRevision: snapshot.configurationRevision,
                                            eventCount: report.syncedEventCount)
                lastSync = completed
                lastSyncCoverage = coverage
                UserDefaults.standard.set(completed, forKey: lastSyncKey)
                UserDefaults.standard.set(try? PropertyListEncoder().encode(coverage), forKey: coverageKey)
                logger.info("Sync complete: \(report.created) added, \(report.updated) updated, \(report.deleted + report.duplicateCopies) removed")
            } catch {
                problem = error.localizedDescription
                logger.error("Sync failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func runAutomatically() {
        if settings.automaticSync { syncNow() }
    }

    private func persist(_ updated: SyncSettings) throws {
        try storage.save(updated)
        settings = updated
        problem = nil
    }
}
