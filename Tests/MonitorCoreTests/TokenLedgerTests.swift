import XCTest
@testable import MonitorCore

final class TokenLedgerTests: XCTestCase {
    private func record(_ total: Int, _ last: Int, _ timestamp: String) -> Data {
        Data("{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)},\"last_token_usage\":{\"total_tokens\":\(last)}}}}\n".utf8)
    }
    func testCumulativeDeltasDuplicateHistoryPartialAppendAndCachedRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl"), cache = root.appendingPathComponent("cache.sqlite")
        let a = record(100, 100, "2026-09-07T08:00:00Z")
        let b = record(180, 80, "2026-09-07T09:00:00Z")
        let duplicateSnapshot = record(180, 80, "2026-09-07T09:01:00Z")
        try (a + b + duplicateSnapshot).write(to: file)
        let ledger = try TokenLedger(cache: cache)
        XCTAssertTrue(try ledger.ingest(file))
        let read = ledger.bytesRead
        XCTAssertTrue(try ledger.ingest(file)); XCTAssertEqual(ledger.bytesRead, read)
        let clone = root.appendingPathComponent("fork.jsonl")
        try (a + b + duplicateSnapshot).write(to: clone)
        XCTAssertTrue(try ledger.ingest(clone))
        let c = record(230, 50, "2026-09-08T08:00:00Z")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: c.dropLast(7))
        XCTAssertTrue(try ledger.ingest(file))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z")!
        XCTAssertEqual(try ledger.summary(now: now, calendar: calendar).total, 180)
        try handle.write(contentsOf: c.suffix(7)); try handle.close()
        XCTAssertTrue(try ledger.ingest(file))
        let summary = try ledger.summary(now: now, calendar: calendar)
        XCTAssertEqual(summary.total, 230); XCTAssertEqual(summary.yesterday, 180)
        let reopened = try TokenLedger(cache: cache)
        XCTAssertTrue(try reopened.ingest(file)); XCTAssertEqual(reopened.bytesRead, 0)
        XCTAssertEqual(try reopened.summary(now: now, calendar: calendar), summary)
        // Rebuilding a replaced log must not double count old observations.
        try a.write(to: file); XCTAssertTrue(try ledger.ingest(file))
        XCTAssertEqual(try ledger.summary(now: now, calendar: calendar).total, 230)
    }
    func testLargeNonUsageLinesAreBoundedAndMidnightUsesLocalCalendar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("huge.jsonl")
        try (Data(String(repeating: "x", count: 3_000_000).utf8) + Data([10]) + record(30, 30, "2026-09-07T16:01:00Z")).write(to: file)
        let ledger = try TokenLedger(cache: root.appendingPathComponent("cache.sqlite"))
        var calls = 0
        while !(try ledger.ingest(file)) { calls += 1; XCTAssertLessThan(calls, 10) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-09-08T02:00:00Z")!
        let summary = try ledger.summary(now: now, calendar: calendar)
        XCTAssertEqual(summary.total, 30); XCTAssertEqual(summary.yesterday, 0)
        XCTAssertLessThan(ledger.bytesRead, 3_300_000)
    }
    func testDualQuotaRowsDoNotInventMissingWindowOrResetToZero() {
        let now: Double = 1000
        let weekly = QuotaWindow(usedPercent: 18, minutes: 10080, resetsAt: 900)
        let rows = QuotaRow.rows(UsageSnapshot(primary: weekly, observedAt: 800), now: now)
        XCTAssertFalse(rows[0].available); XCTAssertEqual(rows[0].reset, "账户无此窗口")
        XCTAssertEqual(rows[1].remaining, "上次82%")
        XCTAssertTrue(rows[1].reset.hasSuffix("待同步"))
        let two = QuotaRow.rows(UsageSnapshot(primary: weekly, secondary: QuotaWindow(usedPercent: 14, minutes: 300, resetsAt: 2000), observedAt: now), now: now)
        XCTAssertEqual(two[0].remaining, "剩余86%")
        XCTAssertEqual(two[1].title, "周额度")
    }
}
