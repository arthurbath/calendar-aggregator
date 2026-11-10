import Foundation

struct SyncCoverage: Codable {
    let completedAt: Date
    let configurationRevision: UUID?
    let eventCount: Int

    func count(for settings: SyncSettings, lastSync: Date?) -> Int? {
        guard settings.destination != nil, completedAt == lastSync,
              configurationRevision == settings.configurationRevision else { return nil }
        return eventCount
    }
}

struct LocalSettings {
    let directory: URL

    static var standard: Self {
        Self(directory: URL.applicationSupportDirectory.appending(path: "Calendar Aggregator", directoryHint: .isDirectory))
    }

    var file: URL { directory.appending(path: "settings.json") }

    func load() throws -> SyncSettings {
        do {
            return try JSONDecoder().decode(SyncSettings.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return SyncSettings()
        }
    }

    func save(_ settings: SyncSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }
}

struct LegacyScheduler {
    private static let label = "garden.bath.sync-aggregate-calendar"
    let plist: URL
    let backupDirectory: URL
    let domain: String
    let launchctl: ([String]) throws -> Int32

    static func standard(settings: LocalSettings) -> Self {
        let plist = URL.homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist")
        return Self(plist: plist, backupDirectory: settings.directory.appending(path: "Legacy LaunchAgents"),
                    domain: "gui/\(getuid())", launchctl: invokeLaunchctl)
    }

    func isPresent() throws -> Bool {
        try isLoaded() || FileManager.default.fileExists(atPath: plist.path)
    }

    func retire(activate: () throws -> Void) throws {
        let files = FileManager.default
        let loaded = try isLoaded()
        let installed = files.fileExists(atPath: plist.path)
        guard !loaded || installed else {
            throw SyncError("The previous job is loaded, but its LaunchAgent file is missing.")
        }
        var backup: URL?
        if installed {
            try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let destination = backupDirectory.appending(path: "\(UUID().uuidString)-\(plist.lastPathComponent)")
            try files.moveItem(at: plist, to: destination)
            backup = destination
        }

        do {
            if loaded {
                let status = try launchctl(["bootout", service])
                guard status == 0 || status == 113 else {
                    throw SyncError("The previous Calendar sync job could not be unloaded.")
                }
            }
            guard try !isPresent() else { throw SyncError("The previous Calendar sync job is still active.") }
            try activate()
        } catch {
            if let backup {
                do {
                    try files.moveItem(at: backup, to: plist)
                    if loaded, try !isLoaded() {
                        guard try launchctl(["bootstrap", domain, plist.path]) == 0 else {
                            throw SyncError("The previous job could not be restarted.")
                        }
                    }
                } catch {
                    let recoveryPath = files.fileExists(atPath: backup.path) ? backup.path : plist.path
                    throw SyncError("Could not restore the previous job. Its LaunchAgent is at \(recoveryPath).")
                }
            }
            throw error
        }
    }

    private var service: String { "\(domain)/\(Self.label)" }

    private func isLoaded() throws -> Bool {
        switch try launchctl(["print", service]) {
        case 0: return true
        case 113: return false
        default: throw SyncError("Could not check the previous Calendar sync job.")
        }
    }

    private static func invokeLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
