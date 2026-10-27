import SwiftUI

struct UsageMetricsView: View {
    let reading: AccountReading
    let now: Date
    var expanded = false

    var body: some View {
        let fresh = reading.isFresh(at: now)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reading.usageMetrics ?? []) { metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(fresh ? "" : "上次记录 · ")\(metric.label) 已用 \(metric.displayValue)")
                        .foregroundStyle(fresh ? .primary : .secondary)
                    if expanded {
                        Text("\(metric.startsAt.formatted(date: .abbreviated, time: .shortened)) — \(metric.endsAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Text("采样于 \(metric.observedAt.formatted(date: .abbreviated, time: .standard))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
