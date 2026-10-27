import SwiftUI

struct QuotaInsightsView: View {
    @ObservedObject var store: AppStore
    @State private var settings = false
    @State private var inbox = false
    @State private var thresholds = "20, 10"
    @State private var expiryHours = 24
    @State private var quietStart = 22
    @State private var quietEnd = 8
    @State private var passive = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("账号筛选", selection: Binding(get: { store.insightPreferences.filter }, set: { filter in
                    var value = store.insightPreferences; value.filter = filter; store.updateInsightPreferences(value)
                })) {
                    ForEach(QuotaAccountFilter.allCases, id: \.rawValue) { filter in Text(filter.title).tag(filter) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Button {
                    inbox.toggle(); if inbox { store.markInsightsRead() }
                } label: {
                    Label(store.unreadInsightCount > 0 ? String(store.unreadInsightCount) : "提醒", systemImage: "bell")
                }
                .help("提醒记录")
                Button { if !settings { loadDraft() }; settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("关注与提醒设置")
            }
            if settings {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("余量阈值（%）"); TextField("20, 10", text: $thresholds).textFieldStyle(.roundedBorder) }
                    Picker("卡片到期前", selection: $expiryHours) {
                        ForEach([6, 12, 24, 48], id: \.self) { Text("\($0) 小时").tag($0) }
                    }
                    HStack {
                        Picker("静默开始", selection: $quietStart) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                        Picker("结束", selection: $quietEnd) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    }
                    Toggle("菜单栏提示", isOn: $passive)
                    Text("静默时段只保留提醒记录；开始与结束相同表示不静默。使用日历时区。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("保存提醒设置", action: saveDraft)
                }
                .font(.system(size: 11)).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if inbox {
                VStack(alignment: .leading, spacing: 8) {
                    if store.insightState.events.isEmpty { Text("暂无提醒").foregroundStyle(.secondary) }
                    ForEach(store.insightState.events.reversed()) { event in
                        if let account = store.accounts.first(where: { $0.id == event.accountID }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.insightMessage(event)).fontWeight(.medium)
                                Text(store.accountIdentityLabel(account) + " · " + account.displayService)
                                    .foregroundStyle(.secondary).lineLimit(2)
                                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func loadDraft() {
        let value = store.insightPreferences
        thresholds = value.thresholds.map(String.init).joined(separator: ", ")
        expiryHours = value.expiryHours; quietStart = value.quietStart; quietEnd = value.quietEnd
        passive = value.passiveNotices; error = nil
    }
    private func saveDraft() {
        let parts = thresholds.components(separatedBy: CharacterSet(charactersIn: ",， ")).filter { !$0.isEmpty }
        let numbers = parts.compactMap(Int.init)
        guard !numbers.isEmpty, numbers.count == parts.count, numbers.count <= 5,
              numbers.allSatisfy({ (1...99).contains($0) }) else { error = "阈值填写 1–99 的整数，最多 5 个。"; return }
        var value = store.insightPreferences
        value.thresholds = numbers; value.expiryHours = expiryHours; value.quietStart = quietStart; value.quietEnd = quietEnd
        value.passiveNotices = passive
        store.updateInsightPreferences(value); settings = false; error = nil
    }
}
