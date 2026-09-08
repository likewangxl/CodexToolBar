import XCTest
@testable import MonitorCore

final class QuotaDisplayTests: XCTestCase {
    func testWeeklyWindowUsesItsOwnQuotaAndExplicitTimeZoneAcrossWindowOrdering() {
        let fiveHour = QuotaWindow(usedPercent: 40, minutes: 300, resetsAt: 1789440000)
        let week = QuotaWindow(usedPercent: 1, minutes: 10080, resetsAt: 1789436123)
        let usage = UsageSnapshot(primary: fiveHour, secondary: week, observedAt: 1788833600)
        let display = QuotaDisplay(usage: usage, now: 1788833700, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(display.headline, "周额度 · 已用 1%")
        XCTAssertEqual(display.resetLine, "09/15 09:35 重置")
        XCTAssertEqual(display.fraction, 0.01)
        XCTAssertFalse(display.expired)
    }
    func testExpirationKeepsLastKnownUsageInsteadOfInventingAReset() {
        let week = QuotaWindow(usedPercent: 94, minutes: 10080, resetsAt: 1789436123)
        let display = QuotaDisplay(usage: UsageSnapshot(primary: week, observedAt: 1788833600), now: week.resetsAt, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertTrue(display.expired)
        XCTAssertEqual(display.headline, "周额度 · 上次 94%")
        XCTAssertEqual(display.resetLine, "09/15 09:35 待同步")
        XCTAssertEqual(display.fraction, 0.94)
    }
    func testMissingAndNonWeeklyWindowsAreNotMisrepresented() {
        let missing = QuotaDisplay(usage: nil)
        XCTAssertEqual(missing.headline, "周额度 · —")
        XCTAssertEqual(missing.resetLine, "等待用量数据")
        let short = QuotaWindow(usedPercent: 20, minutes: 300, resetsAt: 1789436123)
        let display = QuotaDisplay(usage: UsageSnapshot(primary: short, observedAt: 1788833600), now: 1788833700, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(display.headline, "5时额度 · 已用 20%")
    }
}
