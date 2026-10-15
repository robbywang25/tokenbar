import Foundation

struct ClaudeResetDeadline: Identifiable, Equatable {
    let id: String
    let label: String
    let date: Date?

    static func rows(account: AccountConfig, reading: AccountReading) -> [ClaudeResetDeadline] {
        guard ["Claude", "Anthropic"].contains(account.menuAgentPrefix) else { return [] }
        func reset(ids: [String], labels: [String]) -> Date? {
            let window = reading.visibleWindows.first {
                ids.contains($0.id.lowercased()) || labels.contains($0.label.filter { !$0.isWhitespace })
            }
            guard let date = window?.resetsAt, ResetCalendarInstant.isValid(date) else { return nil }
            return date
        }
        return [
            .init(id: "five-hour", label: "5 小时重置", date: reset(ids: ["five_hour", "five-hour", "five", "5h"], labels: ["5小时", "5小时额度"])),
            .init(id: "weekly", label: "每周重置", date: reset(ids: ["seven_day", "seven-day", "weekly", "week", "7d"], labels: ["每周", "每周额度", "7天"]))
        ]
    }
}
