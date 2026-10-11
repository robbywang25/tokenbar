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
        // Expire the displayed observation even if the menu-bar host stops.
        // These entries reuse only the same local snapshot; no provider requests.
        let boundaries = Set(snapshot.accounts.compactMap(\.freshUntil).filter { $0 > now && $0 < nextRead }).sorted()
        let entries = ([now] + boundaries).map { TokenBarWidgetEntry(date: $0, snapshot: snapshot) }
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
        let accounts = emails.enumerated().map { index, email in
            TokenBarWidgetAccount(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                email: email, provider: providers[index], plan: index == 0 ? "Pro" : nil,
                status: .connected, observedAt: date.addingTimeInterval(-20), freshUntil: date.addingTimeInterval(100),
                metrics: [
                    TokenBarWidgetMetric(id: "weekly", label: "每周", value: "\(Int(percentages[index]))%", remainingPercent: percentages[index]),
                    TokenBarWidgetMetric(id: "secondary", label: index == 0 ? "点数" : "5 小时",
                                         value: index == 0 ? "44700 点" : "86%", remainingPercent: index == 0 ? nil : 86)
                ]
            )
        }
        return TokenBarWidgetEntry(date: date, snapshot: TokenBarWidgetSnapshot(generatedAt: date, accounts: accounts))
    }
}
