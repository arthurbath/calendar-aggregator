import AppKit
import ServiceManagement
import SwiftUI

@main
struct CalendarAggregatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            SyncPopover(model: delegate.model)
        } label: {
            if let image = Self.menuIcon {
                Image(nsImage: image).accessibilityLabel("Calendar Aggregator")
            } else {
                Label("Calendar Aggregator", systemImage: "calendar")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Calendar Aggregator Settings", id: "settings") {
            CalendarSettingsView(model: delegate.model)
        }
        .defaultSize(width: 540, height: 520)
    }

    private static let menuIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "calendar-sync", withExtension: "svg"),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }
}

struct SyncPopover: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingHandoff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(model.status, systemImage: statusIcon)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let date = model.lastSync {
                Text("Last sync \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.result {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = model.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.hasAccess {
                Button("Allow Calendar Access", action: model.requestAccess)
                    .disabled(model.requestingAccess)
            } else if model.legacyPresent {
                Button("Replace Previous Sync Job…") { confirmingHandoff = true }
                    .disabled(model.configurationProblem != nil)
                    .confirmationDialog("Replace the previous Calendar sync job?",
                                        isPresented: $confirmingHandoff, titleVisibility: .visible) {
                        Button("Replace and Start Sync", action: model.replaceLegacyJob)
                    } message: {
                        Text("Calendar Aggregator will save a copy of the old LaunchAgent and take over its 15-minute schedule.")
                    }
            }
            Divider()
            Toggle("Automatic Sync", isOn: Binding(get: { model.settings.automaticSync }, set: model.setAutomatic))
                .disabled(!model.settings.automaticSync && (!model.canSync || model.isSyncing))
            Toggle("Open at Login", isOn: Binding(get: { model.loginStatus == .enabled }, set: model.setOpenAtLogin))
            if model.loginStatus == .requiresApproval {
                Button("Open Login Items Settings", action: SMAppService.openSystemSettingsLoginItems)
            }
            Divider()
            HStack {
                Button("Sync Now", action: model.syncNow).disabled(!model.canSync)
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }.keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(model.isSyncing)
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: 350, alignment: .leading)
        .onAppear(perform: model.refresh)
    }

    private var statusIcon: String {
        if model.isSyncing { return "arrow.triangle.2.circlepath" }
        if model.problem != nil || model.configurationProblem != nil { return "exclamationmark.circle" }
        if model.settings.automaticSync && !model.legacyPresent { return "checkmark.circle" }
        return "clock"
    }
}
