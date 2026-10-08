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
final class TokenBarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = AppStore()
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "TokenBar 额度")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = "TokenBar"
            button.toolTip = "查看所有 Agent 额度"
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("tokenbar.status")
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 440, height: 620)
        popover.contentViewController = NSHostingController(rootView: DashboardView(store: store))
        observation = Publishers.CombineLatest3(store.$accounts, store.$readings, store.$now)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                let title = self.store.menuTitle
                if self.statusItem.button?.title != title { self.statusItem.button?.title = title }
            }
        Task {
            if CommandLine.arguments.contains("--demo") { store.loadDemo() }
            else if CommandLine.arguments.contains("--connect-local") { await store.connectLocalAccounts() }
            else { await store.refresh() }
            if CommandLine.arguments.contains("--show") { togglePopover() }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refresh() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }
}
