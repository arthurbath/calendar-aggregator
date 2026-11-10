import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum CalendarAggregatorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var configurationWindow: NSWindow?
    private var statusObservation: AnyCancellable?
    private var resizePending = false

    private lazy var popoverController = NSHostingController(rootView: SyncPopover(
        model: model, openConfiguration: { [weak self] in self?.showConfiguration() }
    ))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuIcon
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("Calendar Aggregator")
        item.button?.toolTip = "Calendar Aggregator"
        statusItem = item

        popoverController.sizingOptions = []
        popover.contentViewController = popoverController
        popover.behavior = .transient
        statusObservation = model.objectWillChange.sink { [weak self] _ in self?.scheduleResize() }
        model.start()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        model.refresh()
        measurePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverController.view.window?.makeKey()
    }

    @discardableResult
    private func measurePopover() -> Bool {
        let width = SyncPopover.width
        let fitting = popoverController.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
        let size = NSSize(width: width, height: ceil(fitting.height))
        guard size != popover.contentSize else { return false }
        popoverController.view.setFrameSize(size)
        popover.contentSize = size
        return true
    }

    private func scheduleResize() {
        guard !resizePending else { return }
        resizePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizePending = false
            guard self.popover.isShown, let button = self.statusItem?.button, self.measurePopover() else { return }
            // Re-anchor after resizing so the arrow stays attached to the status item.
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showConfiguration() {
        popover.performClose(nil)
        if configurationWindow == nil {
            let controller = NSHostingController(rootView: CalendarSettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Calendar Aggregator Configuration"
            window.setContentSize(NSSize(width: 540, height: 520))
            if !window.setFrameUsingName("settings") { window.center() }
            window.setFrameAutosaveName("settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            configurationWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        configurationWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === configurationWindow {
            configurationWindow = nil
        }
    }

    private static let menuIcon: NSImage? = {
        let artwork = Bundle.main.url(forResource: "calendar-sync", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
        guard let image = artwork ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: nil) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

struct SyncPopover: View {
    static let width: CGFloat = 300
    @ObservedObject var model: AppModel
    let openConfiguration: () -> Void
    @State private var confirmingHandoff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                statusMark
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = model.lastSync {
                        Text(completionText(date))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = model.problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
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
            Button("Sync Now", action: model.syncNow)
                .disabled(!model.canSync)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Divider()
            configurationSection
            Divider()
            optionToggle("Automatic Sync", isOn: Binding(get: { model.settings.automaticSync }, set: model.setAutomatic))
                .disabled(!model.settings.automaticSync && (!model.canSync || model.isSyncing))
            optionToggle("Open at Login", isOn: Binding(get: { model.loginStatus == .enabled }, set: model.setOpenAtLogin))
            if model.loginStatus == .requiresApproval {
                Button("Open Login Items Settings", action: SMAppService.openSystemSettingsLoginItems)
            }
            Divider()
            Menu {
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(model.isSyncing)
            } label: {
                Image(systemName: "gearshape").accessibilityLabel("App Menu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration").font(.headline).accessibilityAddTraits(.isHeader)
            metric("Source Calendars", value: model.settings.sources.count.formatted())
            metric("Destination Calendar", value: model.destination?.label ?? "Not Configured")
            if let count = model.syncedEventCount {
                metric("Events at Last Sync", value: count.formatted())
            }
            Button("Edit", action: openConfiguration)
                .accessibilityLabel("Edit Configuration")
                .keyboardShortcut(",")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func metric(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func optionToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusMark: some View {
        let mark: (symbol: String, color: Color, label: String)
        if model.isSyncing {
            mark = ("arrow.triangle.2.circlepath", .orange, "Syncing")
        } else if model.problem != nil || model.configurationProblem != nil {
            mark = ("exclamationmark.circle.fill", .red, "Needs Attention")
        } else if model.settings.automaticSync && !model.legacyPresent && model.syncedEventCount != nil {
            mark = ("checkmark.circle.fill", .green, "Operational")
        } else {
            mark = ("clock.fill", .orange, "Waiting")
        }
        return Image(systemName: mark.symbol)
            .foregroundStyle(mark.color).font(.headline).accessibilityLabel(mark.label)
    }

    private func completionText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy MMM d 'at' h:mm a"
        return "Completed \(formatter.string(from: date))"
    }
}
