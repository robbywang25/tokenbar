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
        // Evaluate ranking, urgency, and freshness again at every entry date.
        // Exact threshold/expiry entries do not wait for a host refresh. Minute
        // entries keep the derived daily pace current while any reading is fresh.
        let freshness = snapshot.accounts.compactMap(\.freshUntil).filter { $0 > now && $0 < nextRead }
        let urgency = snapshot.urgencyBoundaryDates(after: now, before: nextRead)
        var dates = Set([now] + freshness + urgency)
        let lastFresh = min(nextRead, snapshot.accounts.compactMap(\.freshUntil).max() ?? now)
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
        let percentages: [Double] = [63, 78, 42, 18, 91, 55]
        let daysRemaining: [Double] = [2.625, 1.5, 4.5, 3, 6.5, 4]
        let accounts = emails.enumerated().map { index, email in
            TokenBarWidgetAccount(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                email: email, provider: providers[index], plan: index == 0 ? "Pro" : nil,
                status: .connected, observedAt: date.addingTimeInterval(-20), freshUntil: date.addingTimeInterval(100),
                metrics: [
                    TokenBarWidgetMetric(id: "weekly", label: "每周", value: "\(Int(percentages[index]))%", remainingPercent: percentages[index],
                                         resetsAt: date.addingTimeInterval(daysRemaining[index] * 86_400)),
                    TokenBarWidgetMetric(id: index == 0 ? "credits" : "secondary", label: index == 0 ? "点数" : "5 小时",
                                         value: index == 0 ? "44700 点" : "86%", remainingPercent: index == 0 ? nil : 86,
                                         resetsAt: index == 0 ? nil : date.addingTimeInterval(Double(index + 1) * 1_800))
                ],
                resetCards: index == 0 ? 2 : index == 4 ? 0 : nil,
                urgencyWindow: QuotaUrgencyWindow(label: "每周", remainingPercent: percentages[index],
                    startsAt: date.addingTimeInterval((daysRemaining[index] - 7) * 86_400),
                    resetsAt: date.addingTimeInterval(daysRemaining[index] * 86_400))
            )
        }
        return TokenBarWidgetEntry(date: date, snapshot: TokenBarWidgetSnapshot(generatedAt: date, accounts: accounts))
    }
}
