import Foundation
import WidgetKit
import TokenBarWidgetShared

/// Serial disk writes keep shared state in submission order without blocking
/// SwiftUI. WidgetKit may coalesce reload requests; the snapshot carries its own
/// freshness deadline and the extension supplies a stale timeline entry.
@MainActor
final class WidgetSnapshotPublisher {
    private let queue = DispatchQueue(label: "wang.robby.tokenbar.widget-snapshot", qos: .utility)
    private var sequence = 0
    private var lastReload: Date = .distantPast
    private var pendingReload: DispatchWorkItem?
    private var previousAccountIDs: [UUID]?
    private let minimumReloadInterval: TimeInterval = 60

    func submit(_ snapshot: TokenBarWidgetSnapshot) {
        guard Bundle.main.object(forInfoDictionaryKey: "TokenBarAppGroup") is String else { return }
        sequence += 1
        let submittedSequence = sequence
        let ids = snapshot.accounts.map(\.id)
        queue.async { [weak self] in
            do {
                let directory = try TokenBarWidgetSnapshotStore.containerDirectory()
                try TokenBarWidgetSnapshotStore.write(snapshot, directory: directory)
                Task { @MainActor [weak self] in
                    guard let self, self.sequence == submittedSequence else { return }
                    let structuralChange = self.previousAccountIDs != ids
                    self.previousAccountIDs = ids
                    self.requestReload(immediately: structuralChange)
                }
            } catch {
                // No fallback to account files or network access. A previously
                // rendered widget will become stale using its existing timeline.
            }
        }
    }

    private func requestReload(immediately: Bool) {
        let delay = minimumReloadInterval - Date().timeIntervalSince(lastReload)
        if immediately || delay <= 0 {
            pendingReload?.cancel()
            pendingReload = nil
            lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: TokenBarWidgetConstants.kind)
        } else if pendingReload == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingReload = nil
                self.requestReload(immediately: true)
            }
            pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}
