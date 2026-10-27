import Foundation
import XCTest
@testable import TokenBar

final class QuotaComparisonTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_155_200)

    func testComparisonRequiresTrustedProductAndExactWindowSemantics() throws {
        let a = try row()
        let b = try row(label: "每 周")
        XCTAssertTrue(a.isComparable(to: b))
        XCTAssertFalse(a.isComparable(to: a))
        XCTAssertFalse(a.isComparable(to: try row(product: nil)))
        XCTAssertFalse(a.isComparable(to: try row(product: "gemini-api")))
        XCTAssertFalse(a.isComparable(to: try row(id: "session")))
        XCTAssertFalse(a.isComparable(to: try row(group: "additional")))
        XCTAssertFalse(a.isComparable(to: try row(model: "another-model")))
        XCTAssertFalse(a.isComparable(to: try row(label: "每月")))
        var duplicate = b.reading; duplicate.identityKey = a.reading.identityKey
        let duplicateRow = try XCTUnwrap(QuotaAnalysisRow(account: b.account, reading: duplicate, window: b.window,
            accountLabel: b.accountLabel, product: b.product))
        XCTAssertFalse(a.isComparable(to: duplicateRow))
    }

    func testAccountNamesAndCurrentCycleDatesNeverDefineCompatibility() throws {
        let a = try row()
        var b = try row(accountLabel: "An unrelated display name")
        var window = b.window; window.resetsAt = now.addingTimeInterval(17_000); window.remainingPercent = 40
        b = try XCTUnwrap(QuotaAnalysisRow(account: b.account, reading: b.reading, window: window,
            accountLabel: b.accountLabel, product: b.product))
        XCTAssertTrue(a.isComparable(to: b), "Each account may have its own reset schedule and balance.")
    }

    func testReserveUnlimitedOtherUnitsAndAmbiguousWindowIDsNeverEnterRecap() throws {
        let base = try row()
        for w in [
            QuotaWindow(id: "reserve-weekly", label: "每周", remainingPercent: 75),
            QuotaWindow(id: "weekly", label: "每周", remainingPercent: 75, group: "reserve"),
            QuotaWindow(id: "weekly", label: "每周", remainingPercent: nil, unlimited: true),
            QuotaWindow(id: "weekly", label: "每周", remainingPercent: 75, unit: "USD")
        ] {
            var reading = base.reading; reading.windows = [w]
            XCTAssertNil(QuotaAnalysisRow(account: base.account, reading: reading, window: w, accountLabel: "fixture", product: "fixture"))
        }
        var ambiguous = base.reading; ambiguous.windows = [base.window, base.window]
        XCTAssertNil(QuotaAnalysisRow(account: base.account, reading: ambiguous, window: base.window, accountLabel: "fixture", product: "fixture"))
    }

    func testRangeSwitchCannotReusePreviousRangeCurveOrStatistics() throws {
        let value = try row()
        XCTAssertNotNil(value.trend(for: .hour))
        XCTAssertNil(value.trend(for: .day))
        XCTAssertEqual(value.summary(for: .day, now: now), .missing)
        XCTAssertEqual(value.summary(for: .hour, now: now).used, 5)
        let csv = QuotaRecapCSV.make(rows: [value], range: .day, now: now)
        let record = csv.components(separatedBy: "\r\n")[1]
        XCTAssertTrue(record.contains("\"\",\"个百分点\",\"\",\"\",\"\",\"未提供\""))
        XCTAssertFalse(record.contains("\"5\""))
    }

    func testCSVPreservesRealZeroAndUnknownAsDifferentValuesWithoutSummingRows() throws {
        let known = try row(used: 0), unknown = try row(withTrend: false)
        let csv = QuotaRecapCSV.make(rows: [known, unknown], range: .hour, now: now)
        let records = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(records[1].contains("\"0\",\"个百分点\",\"600\""))
        XCTAssertTrue(records[2].contains("\"\",\"个百分点\",\"\",\"\",\"\",\"未提供\""))
        XCTAssertFalse(csv.contains("合计"))
    }

    func testCSVQuotesTextAndNeutralizesSpreadsheetFormulas() throws {
        XCTAssertEqual(QuotaRecapCSV.escaped(" =HYPERLINK(\"https://example.test\")"), "\"' =HYPERLINK(\"\"https://example.test\"\")\"")
        XCTAssertEqual(QuotaRecapCSV.escaped("\t+1"), "\"'\t+1\"")
        XCTAssertEqual(QuotaRecapCSV.escaped("\u{FEFF}@SUM(1)"), "\"'\u{FEFF}@SUM(1)\"")
        XCTAssertEqual(QuotaRecapCSV.escaped("name,\"quoted\"\r\nnext"), "\"name,\"\"quoted\"\"\r\nnext\"")
        let csv = QuotaRecapCSV.make(rows: [try row(accountLabel: "=SUM(1)")], range: .hour, now: now)
        XCTAssertTrue(csv.contains("\"'=SUM(1)\""))
    }

    func testStaleHistoryCanBeExportedButAuthFailureCannotExposeItsSamples() throws {
        let value = try row()
        let history = value.summary(for: .hour, now: now.addingTimeInterval(180))
        XCTAssertEqual(history.status, "stale")
        XCTAssertEqual(history.used, 5)
        var revoked = value.reading; revoked.status = .needsAuth
        let revokedRow = try XCTUnwrap(QuotaAnalysisRow(account: value.account, reading: revoked, window: value.window,
            accountLabel: value.accountLabel, product: value.product))
        XCTAssertEqual(revokedRow.summary(for: .hour, now: now), .missing)
        XCTAssertFalse(QuotaRecapCSV.make(rows: [revokedRow], range: .hour, now: now).contains("\"5\""))
    }

    func testSelectionPersistsPerProfileAndMissingWindowDoesNotBorrowAnother() throws {
        let a = try row(), b = try row(id: "session")
        let suite = "TokenBar.QuotaAnalysisTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let choice = QuotaAnalysisSelection(accountID: a.account.id.uuidString, windowKey: a.semantics.selectionKey, comparisonID: b.account.id.uuidString)
        choice.save(to: preferences)
        XCTAssertEqual(QuotaAnalysisSelection.load(from: preferences), choice)
        XCTAssertEqual(choice.selected(in: [a, b])?.id, a.id)
        XCTAssertNil(choice.selected(in: [b]))
        preferences.set(Data("{bad".utf8), forKey: QuotaAnalysisSelection.defaultsKey)
        XCTAssertNil(QuotaAnalysisSelection.load(from: preferences))
    }

    func testDifferentModelsRemainDistinctInPickerTitlesAndCSV() throws {
        let first = try row(model: "model-alpha"), second = try row(model: "model-beta")
        XCTAssertEqual(first.window.title, second.window.title)
        XCTAssertNotEqual(first.displayWindowTitle, second.displayWindowTitle)
        XCTAssertEqual(first.displayWindowTitle, "每周 · model-alpha")
        XCTAssertNotEqual(first.semantics.selectionKey, second.semantics.selectionKey)
        let csv = QuotaRecapCSV.make(rows: [first, second], range: .hour, now: now)
        XCTAssertTrue(csv.contains("每周 · model-alpha"))
        XCTAssertTrue(csv.contains("每周 · model-beta"))
    }

    func testResetMarkersUseIdentityBoundLocalArchiveWithoutInventingFutureResets() throws {
        let value = try row()
        let reset = now.addingTimeInterval(-300)
        let archived = QuotaResetRecord(id: value.window.id, label: value.window.label,
            group: value.window.group, model: value.window.model, resetsAt: reset)
        let differentWindow = QuotaResetRecord(id: "session", label: "5 小时", group: "default", resetsAt: now.addingTimeInterval(-200))
        let differentModel = QuotaResetRecord(id: value.window.id, label: value.window.label,
            group: value.window.group, model: "other-model", resetsAt: now.addingTimeInterval(-100))
        var history = ResetCalendarHistory()
        history.mergeSynced([archived, archived, differentWindow, differentModel], account: value.account, reading: value.reading, at: now)
        XCTAssertNil(value.reading.resetHistory, "This scenario must rely on the durable local archive.")
        let model = ResetCalendarModel(accounts: [value.account], readings: [value.account.id: value.reading],
            history: history, now: now, identity: { _ in "fixture" })
        XCTAssertEqual(value.resetMarkers(in: model.events, from: now.addingTimeInterval(-3_600),
            to: now.addingTimeInterval(7_200), now: now), [reset], "Future schedules and other windows/models are not observed reset markers.")
        let anotherAccount = ResetCalendarEvent(id: .init(accountID: UUID(), windowID: value.window.id,
            group: value.window.group, model: value.window.model, resetsAt: reset), accountName: "other", service: "fixture",
            windowLabel: value.window.label, resetsAt: reset, status: .expired)
        XCTAssertEqual(value.resetMarkers(in: model.events + [anotherAccount] + model.events,
            from: now.addingTimeInterval(-3_600), to: now, now: now), [reset])
        var replaced = value.reading; replaced.identityKey = "another-verified-identity"
        let replacementModel = ResetCalendarModel(accounts: [value.account], readings: [value.account.id: replaced],
            history: history, now: now, identity: { _ in "replacement" })
        XCTAssertTrue(value.resetMarkers(in: replacementModel.events, from: now.addingTimeInterval(-3_600), to: now, now: now).isEmpty)
    }

    private func row(product: String? = "gemini-web", id: String = "weekly", group: String = "default", model: String? = nil,
                     label: String = "每周", accountLabel: String = "fixture@example.test", used: Double = 5,
                     withTrend: Bool = true) throws -> QuotaAnalysisRow {
        let account = AccountConfig(provider: .snapshot, name: "Synthetic", method: .snapshotFile,
            location: "/unused-synthetic.json", sourceAccountID: UUID().uuidString, serviceLabel: "Gemini Web")
        let trend = QuotaUsageTrend(status: "ready", from: now.addingTimeInterval(-3_600), to: now, bucketSeconds: 300,
            balancePoints: [QuotaBalancePoint(at: now.addingTimeInterval(-600), remaining: 80, connect: false),
                            QuotaBalancePoint(at: now, remaining: 75, connect: true)],
            totalUsed: used, coverageSeconds: 600, observedAt: now)
        let window = QuotaWindow(id: id, label: label, remainingPercent: 75, resetsAt: now.addingTimeInterval(3_600),
            startsAt: now.addingTimeInterval(-3_600), group: group, model: model, usageTrend: withTrend ? trend : nil)
        let reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now, windows: [window],
            identityKey: account.id.uuidString)
        return try XCTUnwrap(QuotaAnalysisRow(account: account, reading: reading, window: window, accountLabel: accountLabel, product: product))
    }
}
