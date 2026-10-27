import SwiftUI
import WidgetKit
#if canImport(TokenBarWidgetShared)
import TokenBarWidgetShared
#endif

struct TokenBarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TokenBarWidgetSnapshot
}

struct TokenBarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokenBarWidgetEntry {
        TokenBarWidgetPreview.entry()
    }

    func getSnapshot(in context: Context, completion: @escaping (TokenBarWidgetEntry) -> Void) {
        if context.isPreview {
            completion(TokenBarWidgetPreview.entry())
        } else {
            let now = Date()
            completion(TokenBarWidgetEntry(date: now, snapshot: readSnapshot(at: now)))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenBarWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = readSnapshot(at: now)
        let nextRead = now.addingTimeInterval(15 * 60)
        let entries = TokenBarWidgetTimeline.dates(snapshot: snapshot, after: now, before: nextRead)
            .map { TokenBarWidgetEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(nextRead)))
    }

    private func readSnapshot(at now: Date) -> TokenBarWidgetSnapshot {
        do {
            let directory = try TokenBarWidgetSnapshotStore.containerDirectory()
            return try TokenBarWidgetSnapshotStore.read(directory: directory)
        } catch {
            // An unreadable or invalid shared file is unavailable, never a zero balance.
            return TokenBarWidgetSnapshot(generatedAt: now, accounts: [])
        }
    }
}

enum TokenBarWidgetTimeline {
    static func dates(snapshot: TokenBarWidgetSnapshot, after now: Date, before nextRead: Date) -> [Date] {
        // Display freshness and ranking retention are independent. Queue the
        // exact one-hour ranking deadlines even beyond the next requested read:
        // WidgetKit may delay that read, but can still apply this saved entry.
        // Each account contributes at most one ranking deadline, not an hour of
        // minute ticks. Live urgency keeps its original fresh-only cadence.
        let liveAccounts = snapshot.accounts.filter { $0.isFresh(at: now) }
        let freshness = liveAccounts.compactMap(\.freshUntil).filter { $0 > now && $0 < nextRead }
        let urgency = snapshot.urgencyBoundaryDates(after: now, before: nextRead)
        let ranking = snapshot.accounts.filter { $0.isWithinRankingGrace(at: now) }
            .compactMap(\.rankingExpiresAt).filter { $0 > now }
        let cardExpirations = snapshot.resetCardBoundaryDates(after: now)
        var dates = Set([now] + freshness + urgency + ranking + cardExpirations)
        let lastFresh = min(nextRead, liveAccounts.compactMap(\.freshUntil).max() ?? now)
        var tick = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        while tick < lastFresh {
            dates.insert(tick)
            tick = tick.addingTimeInterval(60)
        }
        return dates.sorted()
    }
}

struct TokenBarQuotaWidget: Widget {
    let kind = TokenBarWidgetConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TokenBarWidgetProvider()) { entry in
            TokenBarWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
                .widgetURL(TokenBarWidgetConstants.deepLink)
        }
        .configurationDisplayName("TokenBar 额度")
        .description("查看账号余量和最近采集时间。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#if !TOKENBAR_WIDGET_PREVIEW
@main
struct TokenBarWidgetBundle: WidgetBundle {
    var body: some Widget { TokenBarQuotaWidget() }
}
#endif

/// Gallery and source previews use synthetic data only.
enum TokenBarWidgetPreview {
    static func entry(at date: Date = Date()) -> TokenBarWidgetEntry {
        let emails = ["agent-one@example.com", "agent-two@example.com", "agent-three@example.com",
                      "agent-four@example.com", "agent-five@example.com", "agent-six@example.com"]
        let providers = ["Codex", "Claude", "Grok", "Cursor", "Codex", "GrokBot"]
        let percentages: [Double] = [63, 78, 42, 0, 91, 55]
        let daysRemaining: [Double] = [2.625, 1.5, 4.5, 3, 6.5, 4]
        let accounts = emails.enumerated().map { index, email in
            let cursor = index == 3
            let reset = date.addingTimeInterval(daysRemaining[index] * 86_400)
            let primary = TokenBarWidgetMetric(id: cursor ? "auto" : "weekly", label: cursor ? "Auto" : "每周",
                value: cursor ? "98%" : "\(Int(percentages[index]))%", remainingPercent: cursor ? 98 : percentages[index], resetsAt: reset)
            let secondary = TokenBarWidgetMetric(id: index == 0 ? "credits" : cursor ? "other-api" : "secondary",
                label: index == 0 ? "点数" : cursor ? "其他 (API)" : "5 小时",
                value: index == 0 ? "44700 点" : cursor ? "0%" : "86%", remainingPercent: index == 0 ? nil : cursor ? 0 : 86,
                resetsAt: index == 0 ? nil : cursor ? reset : date.addingTimeInterval(Double(index + 1) * 1_800))
            return TokenBarWidgetAccount(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                email: email, provider: providers[index], plan: index == 0 ? "Pro" : nil,
                status: .connected, observedAt: date.addingTimeInterval(-20), freshUntil: date.addingTimeInterval(100),
                metrics: [primary, secondary],
                resetCards: index == 0 ? 2 : index == 4 ? 0 : nil,
                urgencyWindow: QuotaUrgencyWindow(label: cursor ? "其他 (API)" : "每周", remainingPercent: percentages[index],
                    startsAt: date.addingTimeInterval((daysRemaining[index] - (cursor ? 30 : 7)) * 86_400), resetsAt: reset)
            )
        }
        return TokenBarWidgetEntry(date: date, snapshot: TokenBarWidgetSnapshot(generatedAt: date, accounts: accounts))
    }
}
