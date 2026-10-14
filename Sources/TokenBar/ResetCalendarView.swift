import SwiftUI

struct ResetCalendarView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedDate: Date
    @AppStorage("resetCalendarTimeZone.v1") private var timeZoneID = "local"

    private var timeZone: TimeZone {
        timeZoneID == "local" ? .autoupdatingCurrent : TimeZone(identifier: timeZoneID) ?? .autoupdatingCurrent
    }
    private var calendar: Calendar { ResetCalendarDates.calendar(timeZone: timeZone) }
    private var model: ResetCalendarModel {
        ResetCalendarModel(accounts: store.accounts, readings: store.readings, now: store.now) {
            store.accountIdentityLabel($0)
        }
    }

    var body: some View {
        let model = model
        let monthEvents = model.events(inMonth: selectedDate, calendar: calendar)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(formatted(selectedDate, "yyyy 年 M 月")).font(.headline)
                Spacer()
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上一个月").help("上一个月")
                Button("今天") { selectedDate = store.now }
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一个月").help("下一个月")
            }
            .buttonStyle(.borderless)
            HStack {
                Text(monthSummary(monthEvents)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    Picker("日历时区", selection: $timeZoneID) {
                        Text("本机时间").tag("local")
                        Text("UTC").tag("UTC")
                        Text("北京时间").tag("Asia/Shanghai")
                        Text("新加坡时间").tag("Asia/Singapore")
                        Text("奥克兰时间").tag("Pacific/Auckland")
                        Text("洛杉矶时间").tag("America/Los_Angeles")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(timeZoneID == "local" ? "本机时间" : timeZoneLabel)
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(timeZone.identifier).accessibilityLabel("日历时区")
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                        Text(day).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }.accessibilityHidden(true)
                let days = ResetCalendarDates.monthDays(containing: selectedDate, calendar: calendar)
                ForEach(0..<6, id: \.self) { week in
                    GridRow(alignment: .top) {
                        ForEach(Array(days.dropFirst(week * 7).prefix(7)), id: \.self) { day in
                            dayCell(day, events: model.events(on: day, calendar: calendar))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("仅展示平台已提供的日期")
                if let missing = model.missingLabel { Text(missing) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: timeZoneID) { oldValue, _ in
            let oldZone = oldValue == "local" ? TimeZone.autoupdatingCurrent : TimeZone(identifier: oldValue) ?? .autoupdatingCurrent
            let oldCalendar = ResetCalendarDates.calendar(timeZone: oldZone)
            let day = oldCalendar.dateComponents([.year, .month, .day], from: selectedDate)
            selectedDate = calendar.date(from: day) ?? selectedDate
        }
    }

    private var timeZoneLabel: String {
        timeZone.localizedName(for: .shortGeneric, locale: Locale(identifier: "zh_CN")) ?? timeZone.identifier
    }

    private func moveMonth(_ amount: Int) {
        selectedDate = ResetCalendarDates.movingMonth(selectedDate, by: amount, calendar: calendar)
    }

    private func formatted(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func monthSummary(_ events: [ResetCalendarEvent]) -> String {
        guard !events.isEmpty else { return "本月暂无已知重置" }
        let pending = events.filter { $0.status != .scheduled }.count
        return "本月 \(events.count) 项重置" + (pending > 0 ? "，\(pending) 项待核实" : "")
    }

    private func dayCell(_ date: Date, events: [ResetCalendarEvent]) -> some View {
        let today = calendar.isDate(date, inSameDayAs: store.now)
        let inMonth = calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 5) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 12, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? Color.accentColor : inMonth ? .primary : .secondary)
                    .frame(height: 20)
                ForEach(events) { event in inlineEvent(event) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .topLeading)
        .background(today ? Color.accentColor.opacity(0.035) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(today ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(formatted(date, "yyyy 年 M 月 d 日") + (today ? "，今天" : ""))
    }

    private func inlineEvent(_ event: ResetCalendarEvent) -> some View {
        let color: Color = event.status == .scheduled ? .accentColor : .secondary
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(formatted(event.resetsAt, "HH:mm"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .fixedSize()
                Text(event.service).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(color)
            Text(event.accountName).font(.system(size: 11))
                .foregroundStyle(event.status == .scheduled ? .primary : .secondary)
            Text(event.windowLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            if let status = event.status.label {
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.7)).frame(width: 2) }
        .accessibilityElement(children: .combine)
        .help(formatted(event.resetsAt, "yyyy-MM-dd HH:mm zzz"))
    }
}
