import AppKit
import SwiftUI
import Combine

@main
enum TokenBarMain {
    @MainActor private static var retainedDelegate: TokenBarDelegate?
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = TokenBarDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class TokenBarDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let cloud = GodWorkspace()
    private var store: AppStore { cloud.store }
    private var observation: AnyCancellable?
    private var workspaceObservation: AnyCancellable?
    private let expiryNotice = ExpiryNoticeController()
    private let widgetPublisher = WidgetSnapshotPublisher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = nil
            button.imagePosition = .noImage
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = "—"
            button.toolTip = "查看所有 Agent 额度"
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("tokenbar.status")
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 440, height: 620)
        popover.contentViewController = NSHostingController(rootView: GodDashboardRoot(cloud: cloud) { [weak self] size in
            self?.popover.contentSize = size
        })
        workspaceObservation = cloud.$store.receive(on: RunLoop.main).sink { [weak self] store in
            self?.observeStore(store)
        }
        observeStore(store)
        Task {
            if CommandLine.arguments.contains("--demo") { store.loadDemo() }
            else if CommandLine.arguments.contains("--connect-local") { await store.connectLocalAccounts() }
            else { await store.refresh() }
            if CommandLine.arguments.contains("--show"), !popover.isShown { togglePopover() }
        }
    }

    private func observeStore(_ store: AppStore) {
        store.onWidgetSnapshotChange = { [weak self] snapshot in self?.widgetPublisher.submit(snapshot) }
        store.publishWidgetSnapshot()
        statusItem.button?.title = store.menuTitle
        statusItem.button?.toolTip = store.menuTooltip
        observation = store.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let title = self.store.menuTitle
                if self.statusItem.button?.title != title { self.statusItem.button?.title = title }
                self.statusItem.button?.toolTip = self.store.menuTooltip
                self.showExpiryNoticeIfNeeded()
            }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            expiryNotice.dismissImmediately()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                // Opening the panel is not keyboard navigation. Start with the
                // window itself focused, and let Tab enter the normal key loop.
                window.makeFirstResponder(nil)
            }
            Task { await store.refresh() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "tokenbar" && $0.host == "dashboard" }),
              statusItem != nil else { return }
        if !popover.isShown { togglePopover() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    func popoverDidClose(_ notification: Notification) { showExpiryNoticeIfNeeded() }

    private func showExpiryNoticeIfNeeded() {
        guard !popover.isShown, !expiryNotice.isVisible,
              let button = statusItem?.button, let window = button.window,
              let screen = window.screen,
              let notice = store.takeNextExpiryNotice() else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        expiryNotice.show(notice, below: rect, on: screen)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }
}
