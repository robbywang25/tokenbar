import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuotaAnalysisView: View {
    @ObservedObject var store: AppStore
    @State private var selection: QuotaAnalysisSelection
    @State private var hasStoredSelection: Bool
    @State private var inspectionAt: Date?
    @State private var exporting = false
    @State private var exportDocument = QuotaCSVDocument(text: "")
    @State private var exportFilename = "TokenBar.csv"
    @State private var exportMessage: String?

    init(store: AppStore) {
        self.store = store
        let saved = QuotaAnalysisSelection.load(from: store.preferences)
        _selection = State(initialValue: saved ?? QuotaAnalysisSelection())
        _hasStoredSelection = State(initialValue: saved != nil)
    }

    private var rows: [QuotaAnalysisRow] {
        store.orderedAccounts.filter(\.enabled).flatMap { account -> [QuotaAnalysisRow] in
            guard let reading = store.readings[account.id] else { return [] }
            return reading.visibleWindows.compactMap { window in
                QuotaAnalysisRow(account: account, reading: reading, window: window,
                    accountLabel: store.accountIdentityLabel(account), product: store.quotaProduct(for: account, reading: reading))
            }
        }
    }
    private var selected: QuotaAnalysisRow? { selection.selected(in: rows) }
    private var comparisonCandidates: [QuotaAnalysisRow] {
        guard let selected else { return [] }
        return rows.filter { selected.isComparable(to: $0) }
    }
    private var comparison: QuotaAnalysisRow? {
        comparisonCandidates.first { $0.account.id.uuidString == selection.comparisonID }
    }
    private var timeZone: TimeZone {
        store.calendarTimeZoneID == "local" ? .autoupdatingCurrent : TimeZone(identifier: store.calendarTimeZoneID) ?? .autoupdatingCurrent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            if let selected {
                analysis(selected, comparison: comparison)
            } else {
                Text(selection.accountID.isEmpty ? "选择账号和额度窗口查看历史。" : "这个账号或额度窗口当前未提供读数。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
            Divider()
            recap
            if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: restoreInitialSelection)
        .onDisappear { store.isPresentingFileExporter = false }
        .onChange(of: exporting) { _, active in
            if !active { store.isPresentingFileExporter = false }
        }
        .onChange(of: selection) { _, value in value.save(to: store.preferences) }
        .onChange(of: store.trendRange) { _, _ in inspectionAt = nil }
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            // Failed reads do not remove account records. Do not discard a
            // remembered window merely because a transient response omitted it.
            if !selection.accountID.isEmpty && !ids.contains(where: { $0.uuidString == selection.accountID }) {
                selection = QuotaAnalysisSelection(); inspectionAt = nil
            } else if !selection.comparisonID.isEmpty && !ids.contains(where: { $0.uuidString == selection.comparisonID }) {
                selection.comparisonID = ""
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: exportFilename) { result in
            store.isPresentingFileExporter = false
            switch result {
            case .success: exportMessage = "CSV 已导出。"
            case .failure: exportMessage = "CSV 未能导出，请重试。"
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    accountPicker.frame(minWidth: 220)
                    windowPicker.frame(minWidth: 190)
                }
                VStack(alignment: .leading, spacing: 10) { accountPicker; windowPicker }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    rangePicker.frame(width: 260)
                    comparisonPicker.frame(minWidth: 210)
                }
                VStack(alignment: .leading, spacing: 10) { rangePicker; comparisonPicker }
            }
        }
        .controlSize(.regular)
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("账号").font(.caption).foregroundStyle(.secondary)
            Picker("分析账号", selection: Binding(get: {
                store.accounts.contains(where: { $0.enabled && $0.id.uuidString == selection.accountID }) ? selection.accountID : ""
            }, set: selectAccount)) {
                Text("选择账号").tag("")
                ForEach(store.orderedAccounts.filter(\.enabled)) { account in
                    Text(store.accountIdentityLabel(account) + " · " + account.displayService)
                        .lineLimit(1).truncationMode(.middle).tag(account.id.uuidString)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var windowPicker: some View {
        let choices = rows.filter { $0.account.id.uuidString == selection.accountID }
        return VStack(alignment: .leading, spacing: 4) {
            Text("额度窗口").font(.caption).foregroundStyle(.secondary)
            Picker("分析额度窗口", selection: Binding(get: {
                choices.contains(where: { $0.semantics.selectionKey == selection.windowKey }) ? selection.windowKey : ""
            }, set: { value in
                selection.windowKey = value; selection.comparisonID = ""; inspectionAt = nil
            })) {
                Text("选择窗口").tag("")
                ForEach(choices) { row in Text(row.displayWindowTitle).tag(row.semantics.selectionKey) }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .disabled(choices.isEmpty)
        }
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("历史时段").font(.caption).foregroundStyle(.secondary)
            Picker("历史时段", selection: Binding(get: { store.trendRange }, set: store.setTrendRange)) {
                ForEach([QuotaHistoryRange.hour, .day, .week], id: \.rawValue) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    private var comparisonPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("对比同产品、同窗口账号").font(.caption).foregroundStyle(.secondary)
            Picker("对比账号", selection: Binding(get: { comparison?.account.id.uuidString ?? "" }, set: { selection.comparisonID = $0 })) {
                Text("不对比").tag("")
                ForEach(comparisonCandidates) { row in
                    Text(row.accountLabel).lineLimit(1).truncationMode(.middle).tag(row.account.id.uuidString)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .disabled(comparisonCandidates.isEmpty)
        }
    }

    @ViewBuilder
    private func analysis(_ row: QuotaAnalysisRow, comparison: QuotaAnalysisRow?) -> some View {
        if let trend = row.trend(for: store.trendRange) {
            let result = trend.analysis(window: row.window, reading: row.reading, now: store.now)
            if !result.points.isEmpty {
                summary(row, value: row.summary(for: store.trendRange, now: store.now))
                plot(row, trend: trend, result: result, comparison: comparison)
                inspection(result.points)
                if let other = comparison {
                    let otherResult = other.summary(for: store.trendRange, now: store.now)
                    HStack(spacing: 16) {
                        Label(row.accountLabel + " · 实线", systemImage: "minus").foregroundStyle(Color.accentColor)
                        Label(other.accountLabel + " · 虚线", systemImage: "minus").foregroundStyle(Color.orange)
                    }
                    .font(.caption).lineLimit(2)
                    Text("百分比相对于各自套餐；对比账号" + (otherResult.observedAt == nil ? "暂无该时段记录。" : "最新采样于 " + dateText(otherResult.observedAt!) + "。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                unavailableHistory
            }
        } else {
            unavailableHistory
        }
    }

    private var unavailableHistory: some View {
        Text(store.isRefreshing ? "正在读取所选时段…" : "此来源暂未提供所选时段的历史。")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }

    private func summary(_ row: QuotaAnalysisRow, value: QuotaRecapSummary) -> some View {
        HStack(alignment: .top, spacing: 24) {
            metric("已观测消耗", value.used.map { number($0) + " 个百分点" } ?? "未提供")
            metric("有效记录", value.coverageSeconds.map { number($0 / 60, digits: 0) + " 分钟" } ?? "未提供")
            metric("数据覆盖", value.coveragePercent.map { number($0, digits: 0) + "%" } ?? "未提供")
            Spacer(minLength: 0)
            Text(QuotaRecapCSV.statusLabel(value.status)).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    private func plot(_ row: QuotaAnalysisRow, trend: QuotaUsageTrend, result: QuotaUsageAnalysis,
                      comparison: QuotaAnalysisRow?) -> some View {
        let secondary = comparison.flatMap { other -> QuotaUsageAnalysis? in
            guard let otherTrend = other.trend(for: store.trendRange) else { return nil }
            return otherTrend.analysis(window: other.window, reading: other.reading, now: store.now)
        }
        let otherPoints: [QuotaBalancePoint] = secondary?.points.filter { $0.at >= trend.from && $0.at <= trend.to } ?? []
        // calendarModel applies account-epoch guards and unifies source
        // observations with the local durable archive before deduplication.
        let markers = row.resetMarkers(in: store.calendarModel(at: store.now).events,
            from: trend.from, to: trend.to, now: store.now)
        let chartLabel = "\(row.displayWindowTitle)，\(store.trendRange.title)剩余额度趋势，\(result.points.count) 个真实采样点，缺口保持断线。"
        let primaryStale: Bool = result.status == "stale"
        let comparisonStale: Bool = secondary?.status == "stale"
        return VStack(spacing: 5) {
            HStack { Text("剩余额度"); Spacer(); Text("0–100%") }.font(.caption).foregroundStyle(.secondary)
            QuotaAnalysisPlot(primary: result.points, secondary: otherPoints, resetDates: markers,
                from: trend.from, to: trend.to, primaryStale: primaryStale, secondaryStale: comparisonStale)
            .frame(height: 200).padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(chartLabel))
            HStack {
                Text(dateText(trend.from)); Spacer(); Text(dateText(trend.to))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if !markers.isEmpty {
                Text("竖线为这个额度窗口已记录的重置时点。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func inspection(_ points: [QuotaBalancePoint]) -> some View {
        let index = inspectionIndex(points)
        let point = points[index]
        return VStack(alignment: .leading, spacing: 4) {
            Text("采样 " + dateText(point.at) + " · 剩余 " + number(point.remaining) + "%")
                .font(.caption).monospacedDigit().accessibilityLabel("采样点，" + dateText(point.at) + "，剩余 " + number(point.remaining) + "%")
            Slider(value: Binding(get: { Double(inspectionIndex(points)) }, set: { value in
                inspectionAt = points[min(points.count - 1, max(0, Int(value.rounded())))].at
            }), in: 0...Double(max(1, points.count - 1)), step: 1)
            .accessibilityLabel("查看真实采样点").disabled(points.count < 2)
        }
    }

    private var recap: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用量复盘").font(.headline)
                Spacer()
                Button("导出 CSV", action: prepareExport).disabled(rows.isEmpty || exporting)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 10) {
                ForEach(rows) { row in recapRow(row) }
            }
            Text("仅统计已有连续采样；不同账号、窗口和单位分别记录。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recapRow(_ row: QuotaAnalysisRow) -> some View {
        let value = row.summary(for: store.trendRange, now: store.now)
        return Button {
            selection.accountID = row.account.id.uuidString; selection.windowKey = row.semantics.selectionKey
            selection.comparisonID = ""; inspectionAt = nil
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.account.displayService + " · " + row.displayWindowTitle).font(.system(size: 12, weight: .semibold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(row.accountLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                HStack {
                    Text("消耗 " + (value.used.map { number($0) + " 个百分点" } ?? "未提供"))
                    Spacer(minLength: 8)
                    Text("覆盖 " + (value.coveragePercent.map { number($0, digits: 0) + "%" } ?? "未提供"))
                }.font(.caption).monospacedDigit()
                Text(value.observedAt.map { "最近采样 " + dateText($0) } ?? "暂无所选时段采样")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain).accessibilityLabel(row.accountLabel + "，" + row.displayWindowTitle + "，查看用量分析")
    }

    private func restoreInitialSelection() {
        guard !hasStoredSelection else { return }
        hasStoredSelection = true
        if let row = rows.first {
            selection.accountID = row.account.id.uuidString; selection.windowKey = row.semantics.selectionKey
        }
        selection.save(to: store.preferences)
    }
    private func selectAccount(_ id: String) {
        selection.accountID = id
        selection.windowKey = rows.first(where: { $0.account.id.uuidString == id })?.semantics.selectionKey ?? ""
        selection.comparisonID = ""; inspectionAt = nil
    }
    private func inspectionIndex(_ points: [QuotaBalancePoint]) -> Int {
        guard let inspectionAt else { return points.count - 1 }
        return points.indices.min(by: { abs(points[$0].at.timeIntervalSince(inspectionAt)) < abs(points[$1].at.timeIntervalSince(inspectionAt)) }) ?? points.count - 1
    }
    private func prepareExport() {
        let snapshot = rows, range = store.trendRange, now = store.now
        exportDocument = QuotaCSVDocument(text: QuotaRecapCSV.make(rows: snapshot, range: range, now: now))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        exportFilename = "TokenBar-" + range.rawValue + "-" + formatter.string(from: now) + ".csv"
        exportMessage = nil
        store.isPresentingFileExporter = true
        exporting = true
    }
    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = store.trendRange == .hour ? "HH:mm" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}

private struct QuotaCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct QuotaAnalysisGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for part in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = rect.minY + rect.height * part
            path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
private struct QuotaAnalysisResetLines: Shape {
    let dates: [Date]
    let from: Date
    let to: Date
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        for date in dates {
            let x = rect.minX + rect.width * date.timeIntervalSince(from) / to.timeIntervalSince(from)
            path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}
private struct QuotaAnalysisDots: Shape {
    let points: [QuotaBalancePoint]
    let from: Date
    let to: Date
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        for (index, point) in points.enumerated() {
            if index > 0 && point.connect && index < points.count - 1 && points[index + 1].connect { continue }
            let center = QuotaTrendLine.position(point, from: from, to: to, in: rect)
            path.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        }
        return path
    }
}

private struct QuotaAnalysisPlot: View {
    let primary: [QuotaBalancePoint]
    let secondary: [QuotaBalancePoint]
    let resetDates: [Date]
    let from: Date
    let to: Date
    let primaryStale: Bool
    let secondaryStale: Bool
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let grid = QuotaAnalysisGrid().path(in: rect)
            context.stroke(grid, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)
            let resets = QuotaAnalysisResetLines(dates: resetDates, from: from, to: to).path(in: rect)
            context.stroke(resets, with: .color(Color.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            let secondaryColor = secondaryStale ? Color.secondary.opacity(0.65) : Color.orange
            let primaryColor = primaryStale ? Color.secondary : Color.accentColor
            let secondaryLine = QuotaTrendLine(points: secondary, from: from, to: to).path(in: rect)
            let secondaryDots = QuotaAnalysisDots(points: secondary, from: from, to: to).path(in: rect)
            context.stroke(secondaryLine, with: .color(secondaryColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            context.fill(secondaryDots, with: .color(secondaryColor))
            let primaryLine = QuotaTrendLine(points: primary, from: from, to: to).path(in: rect)
            let primaryDots = QuotaAnalysisDots(points: primary, from: from, to: to).path(in: rect)
            context.stroke(primaryLine, with: .color(primaryColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            context.fill(primaryDots, with: .color(primaryColor))
        }
    }
}
