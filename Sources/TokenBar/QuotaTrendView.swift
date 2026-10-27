import SwiftUI

/// The source owns the history. Rendering never connects a reset or a gap,
/// derives an account-wide series, or treats a missing observation as zero.
struct QuotaTrendView: View {
    let window: QuotaWindow
    let reading: AccountReading
    let now: Date

    var body: some View {
        let analysis = window.usageTrend?.analysis(window: window, reading: reading, now: now)
        let pace = analysis?.pace ?? QuotaUsageAnalysis.cyclePace(window: window, reading: reading, now: now)
        VStack(alignment: .leading, spacing: 7) {
            if let trend = window.usageTrend, let analysis, !analysis.points.isEmpty {
                history(trend, analysis: analysis)
            }
            if let pace {
                Text(paceDescription(pace))
                    .foregroundStyle(pace.status == "ahead" ? Color.orange : Color.secondary)
                    .accessibilityLabel(window.title + "，" + paceDescription(pace))
            }
        }
        .font(.system(size: 10))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func history(_ trend: QuotaUsageTrend, analysis: QuotaUsageAnalysis) -> some View {
        let stale = analysis.status == "stale" || !reading.isFresh(at: now)
        let color = stale ? Color.secondary : Color.accentColor
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(stale ? "历史趋势 · 等待更新" : "\(trend.rangeLabel)剩余额度")
                Spacer(minLength: 4)
                Text("0–100%").monospacedDigit()
            }
            .foregroundStyle(.secondary)

            ZStack {
                QuotaTrendGrid().stroke(.primary.opacity(0.07), lineWidth: 1)
                QuotaTrendLine(points: analysis.points, from: trend.from, to: trend.to)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                QuotaTrendDots(points: analysis.points, from: trend.from, to: trend.to)
                    .fill(color)
            }
            .padding(.vertical, 3)
            .frame(height: 88)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chartDescription(trend, analysis: analysis, stale: stale))

            HStack {
                Text(trend.from, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                Spacer(minLength: 4)
                Text(trend.to, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            }
            .monospacedDigit().foregroundStyle(.tertiary)

            Text(usageDescription(trend, analysis: analysis))
                .foregroundStyle(.secondary)

            if !stale, let forecast = analysis.forecast {
                Text(forecastDescription(forecast))
                    .foregroundStyle(forecast.beforeReset == true ? Color.orange : Color.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func usageDescription(_ trend: QuotaUsageTrend, analysis: QuotaUsageAnalysis) -> String {
        let coverage = number(analysis.coveragePercent, digits: 0)
        if let used = analysis.used {
            return "\(trend.rangeLabel)已用 \(number(used)) 个百分点 · 覆盖 \(coverage)%"
        }
        return "趋势积累中 · 覆盖 \(coverage)%"
    }

    private func forecastDescription(_ forecast: QuotaForecast) -> String {
        if forecast.beforeReset == false { return "按近期速度，预计可用至本次重置" }
        let duration: String
        if forecast.minutesLeft < 60 {
            duration = number(max(1, forecast.minutesLeft), digits: 0) + " 分钟"
        } else if forecast.minutesLeft < 24 * 60 {
            duration = number(forecast.minutesLeft / 60) + " 小时"
        } else {
            duration = number(forecast.minutesLeft / (24 * 60)) + " 天"
        }
        let reset = forecast.beforeReset == true ? "，早于重置" : ""
        return "按近期速度，约 \(duration)用完\(reset)"
    }

    private func paceDescription(_ pace: QuotaCyclePace) -> String {
        let label = pace.status == "ahead" ? "使用偏快" : pace.status == "behind" ? "使用偏慢" : "使用均衡"
        return "\(label) · 已用 \(number(pace.usedPercent, digits: 0))% / 周期已过 \(number(pace.elapsedPercent, digits: 0))%"
    }

    private func chartDescription(_ trend: QuotaUsageTrend, analysis: QuotaUsageAnalysis, stale: Bool) -> String {
        guard let first = analysis.points.first, let last = analysis.points.last else { return "暂无趋势" }
        let gaps = analysis.points.dropFirst().filter { !$0.connect }.count
        return "\(window.title)，\(stale ? "历史" : "")\(trend.rangeLabel)剩余额度，从 \(number(first.remaining))% 到 \(number(last.remaining))%，\(gaps) 处中断。" + usageDescription(trend, analysis: analysis)
    }

    private func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}

private struct QuotaTrendGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [0.0, 0.5, 1.0] {
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

struct QuotaTrendLine: Shape {
    let points: [QuotaBalancePoint]
    let from: Date
    let to: Date

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        for (index, point) in points.enumerated() {
            let position = Self.position(point, from: from, to: to, in: rect)
            if index == 0 || !point.connect { path.move(to: position) }
            else { path.addLine(to: position) }
        }
        return path
    }

    static func position(_ point: QuotaBalancePoint, from: Date, to: Date, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * min(1, max(0, point.at.timeIntervalSince(from) / to.timeIntervalSince(from))),
                y: rect.maxY - rect.height * min(100, max(0, point.remaining)) / 100)
    }
}

private struct QuotaTrendDots: Shape {
    let points: [QuotaBalancePoint]
    let from: Date
    let to: Date

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        // Keep isolated observations visible without filling gaps. Only segment
        // boundaries need dots; long dense histories retain a thin clear line.
        for (index, point) in points.enumerated() {
            let startsSegment = index == 0 || !point.connect
            let endsSegment = index == points.count - 1 || !points[index + 1].connect
            guard startsSegment || endsSegment else { continue }
            let center = QuotaTrendLine.position(point, from: from, to: to, in: rect)
            path.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        }
        return path
    }
}
