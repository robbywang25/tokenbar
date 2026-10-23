import Foundation
import CryptoKit

enum ResetCalendarInstant {
    static let upperBound: TimeInterval = 253_402_300_800

    static func isValid(_ date: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite && value > 0 && value < upperBound
    }
}

/// Calendar-only memory of reset instants that were actually observed.
/// Pending holds a future instant that has not arrived. Archive holds an instant
/// that was reached. A future instant corrected before it arrives is discarded,
/// so it cannot show up later as something that happened.
struct ResetCalendarHistory: Codable, Equatable {
    static let fileName = "reset-calendar-history.json"
    static let maximumStoredBytes = 16 * 1_024 * 1_024
    static let persistenceError = "重置历史未能保存到本机。"

    var accounts: [UUID: AccountHistory] = [:]

    struct AccountHistory: Codable, Equatable {
        var sourceSignature: String
        var identityKey: String? = nil
        var verifiedEmailDigest: String? = nil
        var sourceHistoryIdentity: String? = nil
        var lastObservedAt: Date? = nil
        var pending: [QuotaResetRecord] = []
        var archived: [QuotaResetRecord] = []

        func conflicts(with reading: AccountReading) -> Bool {
            if let identityKey, let current = reading.identityKey, identityKey != current { return true }
            if let verifiedEmailDigest, let current = ResetCalendarHistory.emailDigest(reading.email), verifiedEmailDigest != current { return true }
            if let sourceHistoryIdentity, let current = reading.resetHistoryIdentity, sourceHistoryIdentity != current { return true }
            return false
        }
    }

    func records(for account: AccountConfig, reading: AccountReading?) -> [QuotaResetRecord] {
        guard let state = accounts[account.id], state.sourceSignature == AccountEmail.sourceSignature(account) else { return [] }
        if let reading, state.conflicts(with: reading) { return [] }
        return state.archived + state.pending
    }

    mutating func removeAccount(_ id: UUID) {
        accounts.removeValue(forKey: id)
    }

    mutating func mergeSynced(_ records: [QuotaResetRecord], account: AccountConfig, reading: AccountReading?, at now: Date) {
        let signature = AccountEmail.sourceSignature(account)
        var value = accounts[account.id] ?? AccountHistory(sourceSignature: signature)
        if value.sourceSignature != signature || reading.map(value.conflicts) == true { value = AccountHistory(sourceSignature: signature) }
        if let reading {
            value.identityKey = reading.identityKey
            value.verifiedEmailDigest = Self.emailDigest(reading.email)
            value.sourceHistoryIdentity = reading.resetHistoryIdentity
        }
        value.archived = Self.normalized(value.archived + records.filter { $0.resetsAt <= now })
        accounts[account.id] = value
    }

    func sanitized(accounts configured: [AccountConfig], readings: [UUID: AccountReading]) -> ResetCalendarHistory {
        let byID = Dictionary(configured.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var copy = ResetCalendarHistory()
        for (id, state) in accounts {
            guard let account = byID[id], state.sourceSignature == AccountEmail.sourceSignature(account) else { continue }
            if let reading = readings[id], state.conflicts(with: reading) { continue }
            var cleaned = state
            cleaned.pending = Self.normalized(state.pending)
            cleaned.archived = Self.normalized(state.archived)
            if let observed = cleaned.lastObservedAt, !ResetCalendarInstant.isValid(observed) { cleaned.lastObservedAt = nil }
            guard !cleaned.pending.isEmpty || !cleaned.archived.isEmpty else { continue }
            copy.accounts[id] = cleaned
        }
        return copy
    }

    /// `previous` is the reading about to be overwritten. A failed or window-less
    /// read keeps those observations. A reported schedule may replace a future instant.
    mutating func incorporate(account: AccountConfig, previous: AccountReading?, next: AccountReading, at now: Date) {
        guard ResetCalendarInstant.isValid(now) else { return }
        let signature = AccountEmail.sourceSignature(account)
        let existing = accounts[account.id]
        let previousGuard = previous.map { AccountHistory(sourceSignature: signature, identityKey: $0.identityKey,
                                                          verifiedEmailDigest: Self.emailDigest($0.email), sourceHistoryIdentity: $0.resetHistoryIdentity) }
        let sourceChanged = existing != nil && existing?.sourceSignature != signature
        let replacedIdentity = existing == nil || sourceChanged || existing?.conflicts(with: next) == true || previousGuard?.conflicts(with: next) == true
        var state = replacedIdentity ? AccountHistory(sourceSignature: signature) : existing!
        if !sourceChanged, previousGuard?.conflicts(with: next) != true,
           let previous, let previousAt = Self.observationTime(previous, at: now), previousAt >= (state.lastObservedAt ?? .distantPast) {
            absorb(previous, now: now, into: &state, replaceUnreportedFuture: false)
        }
        for record in next.resetHistory ?? [] where QuotaResetRecord.isStorable(record) && record.resetsAt <= now {
            upsert(&state.archived, record)
        }
        if let observedAt = Self.observationTime(next, at: now), observedAt >= (state.lastObservedAt ?? .distantPast) {
            let schedules = Dictionary(next.visibleWindows.compactMap(QuotaResetRecord.init(window:)).map { ($0.windowKey, $0.resetsAt) }, uniquingKeysWith: { _, last in last })
            let keep: (QuotaResetRecord) -> Bool = { record in
                !(record.resetsAt > observedAt && schedules[record.windowKey] != nil && schedules[record.windowKey] != record.resetsAt)
            }
            state.pending.removeAll { !keep($0) }
            state.archived.removeAll { !keep($0) }
            archiveElapsedPending(at: now, in: &state)
            absorb(next, now: now, into: &state, replaceUnreportedFuture: true)
            state.lastObservedAt = observedAt
        } else {
            archiveElapsedPending(at: now, in: &state)
        }
        if let identity = next.identityKey { state.identityKey = identity }
        if let email = Self.emailDigest(next.email) { state.verifiedEmailDigest = email }
        if let epoch = next.resetHistoryIdentity { state.sourceHistoryIdentity = epoch }
        state.pending = Self.normalized(state.pending)
        state.archived = Self.normalized(state.archived)
        if state.pending.isEmpty && state.archived.isEmpty { accounts.removeValue(forKey: account.id) }
        else { accounts[account.id] = state }
    }

    private static func emailDigest(_ value: String?) -> String? {
        guard let email = AccountEmail.validated(value) else { return nil }
        return SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func observationTime(_ reading: AccountReading, at now: Date) -> Date? {
        guard [.connected, .stale].contains(reading.status),
              let success = reading.lastSuccessAt, ResetCalendarInstant.isValid(success), success <= now,
              reading.visibleWindows.contains(where: { QuotaResetRecord(window: $0) != nil }) else { return nil }
        if reading.sourceCollectedAtPresent == true || reading.sourceCollectedAt != nil {
            guard let source = reading.sourceCollectedAt, ResetCalendarInstant.isValid(source), source <= now else { return nil }
            return min(source, success)
        }
        return success
    }

    private func absorb(_ reading: AccountReading, now: Date, into state: inout AccountHistory, replaceUnreportedFuture: Bool) {
        var seen = Set<QuotaResetRecord.WindowKey>()
        for window in reading.visibleWindows {
            guard let record = QuotaResetRecord(window: window) else { continue }
            seen.insert(record.windowKey)
            if record.resetsAt <= now {
                upsert(&state.archived, record)
                state.pending.removeAll { $0.windowKey == record.windowKey }
            } else {
                // The old future date did not arrive. Do not archive it.
                state.pending.removeAll { $0.windowKey == record.windowKey }
                upsert(&state.pending, record)
            }
        }
        if replaceUnreportedFuture {
            state.pending.removeAll { $0.resetsAt > now && !seen.contains($0.windowKey) }
        }
    }

    private func archiveElapsedPending(at now: Date, in state: inout AccountHistory) {
        for record in state.pending where record.resetsAt <= now { upsert(&state.archived, record) }
        state.pending.removeAll { $0.resetsAt <= now }
    }

    private func upsert(_ records: inout [QuotaResetRecord], _ record: QuotaResetRecord) {
        if let index = records.firstIndex(where: { $0.dedupeKey == record.dedupeKey }) { records[index] = record }
        else { records.append(record) }
    }

    private static func normalized(_ records: [QuotaResetRecord]) -> [QuotaResetRecord] {
        var byKey: [QuotaResetRecord.DedupeKey: QuotaResetRecord] = [:]
        for record in records where QuotaResetRecord.isStorable(record) { byKey[record.dedupeKey] = record }
        return byKey.values.sorted {
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.group != $1.group { return $0.group < $1.group }
            return ($0.model ?? "") < ($1.model ?? "")
        }
    }
}
