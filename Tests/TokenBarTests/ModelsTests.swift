import XCTest
@testable import TokenBar

final class ModelsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testFreshnessNeverPromotesExpiredOrFutureReadings() {
        var reading = AccountReading(status: .connected, checkedAt: now, lastSuccessAt: now)
        XCTAssertTrue(reading.isFresh(at: now))
        reading.lastSuccessAt = now.addingTimeInterval(-121)
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .stale)
        reading.lastSuccessAt = now.addingTimeInterval(61)
        XCTAssertFalse(reading.isFresh(at: now))
        reading.lastSuccessAt = now
        reading.windows = [QuotaWindow(id: "w", label: "每周", remainingPercent: 50, resetsAt: now)]
        XCTAssertFalse(reading.isFresh(at: now))
        reading.windows = []; reading.status = .needsAuth
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(reading.displayStatus(at: now), .needsAuth)
    }

    func testUnknownAndZeroAreDistinct() {
        let unknown = QuotaWindow(id: "a", label: "额度", remainingPercent: nil)
        let zero = QuotaWindow(id: "b", label: "额度", remainingPercent: 0)
        XCTAssertEqual(unknown.displayValue, "未提供")
        XCTAssertEqual(zero.displayValue, "0%")
    }

    func testPacingOnlyAppliesToDefinedLongWindows() {
        var window = QuotaWindow(id: "w", label: "每周", remainingPercent: 94,
            resetsAt: now.addingTimeInterval(3600), startsAt: now.addingTimeInterval(-601200))
        XCTAssertEqual(window.alert(at: now), "即将重置")
        window.resetsAt = now.addingTimeInterval(172800)
        XCTAssertEqual(window.alert(at: now), "使用偏慢")
        window.startsAt = nil
        XCTAssertNil(window.alert(at: now))
        window.startsAt = now.addingTimeInterval(-14400); window.resetsAt = now.addingTimeInterval(3600)
        XCTAssertNil(window.alert(at: now))
    }

    @MainActor func testDemoDoesNotWriteAccountsOrCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, startTimers: false)
        store.loadDemo()
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.accounts.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        store.exitDemo()
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.readings.isEmpty)
    }
}
