import AppKit
import SwiftUI

/// A short, passive callout anchored to the status item, never Notification Center.
@MainActor
final class ExpiryNoticeController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    var isVisible: Bool { panel?.isVisible == true }

    func show(_ notice: ExpiryNotice, below anchor: NSRect, on screen: NSScreen) {
        dismissImmediately()
        let size = NSSize(width: 318, height: 88)
        let margin: CGFloat = 12
        let x = min(max(anchor.midX - size.width / 2, screen.visibleFrame.minX + margin), screen.visibleFrame.maxX - size.width - margin)
        let target = NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: target.offsetBy(dx: 0, dy: 8), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ExpiryNoticeView(notice: notice))
        panel.alphaValue = 0
        self.panel = panel
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) }
            catch { return }
            guard let self, self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 0
            } completionHandler: { panel.orderOut(nil) }
        }
    }

    func dismissImmediately() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ExpiryNoticeView: View {
    let notice: ExpiryNotice
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(notice.accountName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("剩余 \(notice.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.red)
                }
                Text("\(notice.serviceLabel) · \(notice.windowLabel)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Text("\(timeRemaining)后重置")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 15).frame(width: 318, height: 88)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
    private var timeRemaining: String {
        let minutes = max(1, Int(ceil(notice.resetsAt.timeIntervalSinceNow / 60)))
        if minutes >= 60 { return "约 \(Int(ceil(Double(minutes) / 60))) 小时" }
        return "约 \(minutes) 分钟"
    }
}
