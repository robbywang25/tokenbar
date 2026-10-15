import Foundation

struct ResetCalendarEvent: Identifiable, Equatable {
    enum Status: Equatable {
        case scheduled, stale, expired

        var label: String? {
            switch self {
            case .scheduled: return nil
            case .stale: return "待核实"
            case .expired: return "已过期"
            }
        }
    }

    struct ID: Hashable {
        let accountID: UUID
        let windowID: String
        let group: String
        let model: String?
        let resetsAt: Date
    }

    let id: ID
    let accountName: String
    let service: String
    let windowLabel: String
    let resetsAt: Date
    let status: Status
}

/// A projection of the current readings, never a prediction or a reset action.
/// Dates remain absolute instants; the selected calendar controls civil-day grouping.
struct ResetCalendarModel {
    let events: [ResetCalendarEvent]
    let missingAccounts: Int
    let missingWindows: Int

    init(accounts: [AccountConfig], readings: [UUID: AccountReading], history: ResetCalendarHistory = ResetCalendarHistory(), now: Date,
         identity: (AccountConfig) -> String) {
        var events: [ResetCalendarEvent] = []
        var missingAccounts = 0, missingWindows = 0
        var seenAccounts = Set<UUID>()
        for account in accounts where account.enabled && seenAccounts.insert(account.id).inserted {
            let reading = readings[account.id]
            if reading?.visibleWindows.isEmpty ?? true { missingAccounts += 1 }
            var seen = Set<ResetCalendarEvent.ID>()
            func append(_ id: ResetCalendarEvent.ID, label: String, reset: Date, status: ResetCalendarEvent.Status) {
                guard seen.insert(id).inserted else { return }
                events.append(ResetCalendarEvent(id: id, accountName: identity(account), service: account.menuAgentPrefix,
                    windowLabel: label, resetsAt: reset, status: status))
            }
            if let reading {
                for window in reading.visibleWindows {
                    guard let reset = window.resetsAt, ResetCalendarInstant.isValid(reset) else {
                        missingWindows += 1
                        continue
                    }
                    append(ResetCalendarEvent.ID(accountID: account.id, windowID: window.id, group: window.group, model: window.model, resetsAt: reset),
                           label: window.title + (window.model.map { " · " + $0 } ?? ""), reset: reset,
                           status: reset <= now ? .expired : reading.isFresh(at: now) ? .scheduled : .stale)
                }
            }
            let remembered = history.records(for: account, reading: reading) + (reading?.resetHistory ?? []).filter { $0.resetsAt <= now }
            for record in remembered where record.group != "reserve" && ResetCalendarInstant.isValid(record.resetsAt) {
                append(ResetCalendarEvent.ID(accountID: account.id, windowID: record.id, group: record.group, model: record.model, resetsAt: record.resetsAt),
                       label: Self.displayLabel(group: record.group, label: record.label, model: record.model), reset: record.resetsAt,
                       status: record.resetsAt <= now ? .expired : .stale)
            }
        }
        self.events = events.sorted {
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            if $0.accountName != $1.accountName { return $0.accountName < $1.accountName }
            if $0.windowLabel != $1.windowLabel { return $0.windowLabel < $1.windowLabel }
            return $0.id.accountID.uuidString < $1.id.accountID.uuidString
        }
        self.missingAccounts = missingAccounts
        self.missingWindows = missingWindows
    }

    /// Past events stay in the month count. Only a future date that is no longer fresh is unverified.
    func summary(in events: [ResetCalendarEvent]) -> String {
        guard !events.isEmpty else { return "本月暂无已知重置" }
        let unverified = events.filter { $0.status == .stale }.count
        return "本月 \(events.count) 项重置" + (unverified > 0 ? "，\(unverified) 项待核实" : "")
    }

    private static func displayLabel(group: String, label: String, model: String?) -> String {
        let prefix = group == "reserve" ? "Reserve" : group == "code-review" ? "代码审查" : group == "additional" ? "附加" : ""
        let title = prefix.isEmpty ? label : "\(prefix) · \(label)"
        return title + (model.map { " · " + $0 } ?? "")
    }

    func events(on day: Date, calendar: Calendar) -> [ResetCalendarEvent] {
        events.filter { calendar.isDate($0.resetsAt, inSameDayAs: day) }
    }

    func events(inMonth month: Date, calendar: Calendar) -> [ResetCalendarEvent] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        return events.filter { $0.resetsAt >= interval.start && $0.resetsAt < interval.end }
    }

    var missingLabel: String? {
        let parts = [missingAccounts > 0 ? "\(missingAccounts) 个账号" : nil,
                     missingWindows > 0 ? "\(missingWindows) 项额度" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "、") + "未提供日期"
    }
}

enum ResetCalendarDates {
    static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    static func monthDays(containing date: Date, calendar: Calendar) -> [Date] {
        guard let first = calendar.dateInterval(of: .month, for: date)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: first) else { return [] }
        // Calendar arithmetic preserves local dates across 23/25-hour DST days.
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func movingMonth(_ date: Date, by amount: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: amount, to: date) ?? date
    }
}
