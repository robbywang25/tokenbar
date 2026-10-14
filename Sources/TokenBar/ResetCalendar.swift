import Foundation

struct ResetCalendarEvent: Identifiable, Equatable {
    enum Status: Equatable {
        case scheduled, stale, expired

        var label: String? {
            switch self {
            case .scheduled: return nil
            case .stale: return "待核实"
            case .expired: return "已到期，待核实"
            }
        }
    }

    struct ID: Hashable {
        let accountID: UUID
        let windowID: String
        let group: String
        let model: String?
        let label: String
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

    init(accounts: [AccountConfig], readings: [UUID: AccountReading], now: Date,
         identity: (AccountConfig) -> String) {
        var events: [ResetCalendarEvent] = []
        var missingAccounts = 0, missingWindows = 0
        var seenAccounts = Set<UUID>()
        for account in accounts where account.enabled && seenAccounts.insert(account.id).inserted {
            guard let reading = readings[account.id], !reading.visibleWindows.isEmpty else {
                missingAccounts += 1
                continue
            }
            var seen = Set<ResetCalendarEvent.ID>()
            for window in reading.visibleWindows {
                guard let reset = window.resetsAt,
                      reset.timeIntervalSince1970.isFinite,
                      reset.timeIntervalSince1970 > 0,
                      reset.timeIntervalSince1970 < 253_402_300_800 else {
                    missingWindows += 1
                    continue
                }
                let id = ResetCalendarEvent.ID(accountID: account.id, windowID: window.id,
                    group: window.group, model: window.model, label: window.label, resetsAt: reset)
                guard seen.insert(id).inserted else { continue }
                events.append(ResetCalendarEvent(id: id, accountName: identity(account),
                    service: account.menuAgentPrefix,
                    windowLabel: window.title + (window.model.map { " · " + $0 } ?? ""),
                    resetsAt: reset,
                    status: reset <= now ? .expired : reading.isFresh(at: now) ? .scheduled : .stale))
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
