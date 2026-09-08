import XCTest
@testable import MonitorCore

final class AccountUsageTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-08T03:00:00Z")! }
    func testAccountSummaryPreservesPrecisionWithoutSummingBuckets() throws {
        let data = Data(#"{"summary":{"lifetimeTokens":12500067890,"peakDailyTokens":987654321},"dailyUsageBuckets":[{"startDate":"2026-09-07","tokens":512000123},{"startDate":"2026-09-06","tokens":111}]}"#.utf8)
        let value = try AccountTokenSummary.decode(data, now: now, calendar: calendar)
        XCTAssertEqual(value.total, 12500067890); XCTAssertEqual(value.yesterday, 512000123)
        XCTAssertEqual(value.yesterdayDate, "2026-09-07")
        XCTAssertEqual(TokenSummary.compact(value.total!), "125.00亿")
        XCTAssertEqual(TokenSummary.compact(value.yesterday!), "5.12亿")
    }
    func testUnknownIsNotZeroAndMissingDayIsUnknown() throws {
        for json in [#"{"summary":{"lifetimeTokens":null},"dailyUsageBuckets":null}"#, #"{"summary":{},"dailyUsageBuckets":[]}"#] {
            let value = try AccountTokenSummary.decode(Data(json.utf8), now: now, calendar: calendar)
            XCTAssertNil(value.total); XCTAssertNil(value.yesterday)
        }
        let value = try AccountTokenSummary.decode(Data(#"{"summary":{"lifetimeTokens":0},"dailyUsageBuckets":[{"startDate":"2026-09-07","tokens":0}]}"#.utf8), now: now, calendar: calendar)
        XCTAssertEqual(value.total, 0); XCTAssertEqual(value.yesterday, 0)
    }
    func testInvalidAndDuplicateDataDoNotInventTotals() throws {
        for number in ["-1", "1.5", "9223372036854775808"] {
            XCTAssertThrowsError(try AccountTokenSummary.decode(Data("{\"summary\":{\"lifetimeTokens\":\(number)}}".utf8)))
        }
        let value = try AccountTokenSummary.decode(Data(#"{"summary":{"lifetimeTokens":10},"dailyUsageBuckets":[{"startDate":"2026-09-07","tokens":5},{"startDate":"2026-09-07","tokens":5}]}"#.utf8), now: now, calendar: calendar)
        XCTAssertNil(value.yesterday)
    }
    func testLocalCalendarDayAndRollover() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-09-07T16:01:00Z")!
        let value = AccountTokenSummary(yesterday: 12, total: 100, observedAt: midnight, calendar: calendar)
        XCTAssertEqual(value.yesterdayDate, "2026-09-07")
        XCTAssertEqual(value.yesterdayValue(now: midnight, calendar: calendar), 12)
        XCTAssertNil(value.yesterdayValue(now: midnight.addingTimeInterval(86400), calendar: calendar))
    }
    func testCombinedReadKeepsQuotaWhenTokensUnsupported() throws {
        try fakeCLI("""
        IFS= read -r line
        echo '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r quota
        case "$quota" in *'"method":"account/rateLimits/read"'*) ;; *) exit 3;; esac
        IFS= read -r tokens
        case "$tokens" in *'"method":"account/usage/read"'*) ;; *) exit 4;; esac
        echo '{"id":3,"error":{"code":-32601}}'
        echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1999999999},"secondary":null}}}'
        IFS= read -r unexpected
        """) { home, script in
            let result = try AccountUsageReader().readAccount(home: home, executable: script, timeout: 2)
            XCTAssertEqual(result.quota?.primary?.usedPercent, 25)
            XCTAssertNil(result.quotaError); XCTAssertNil(result.tokens); XCTAssertEqual(result.tokenError, .unsupported)
        }
    }
    func testPartialResponseTimeoutPreservesAvailableEndpoint() throws {
        try fakeCLI("""
        IFS= read -r line
        echo '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        IFS= read -r line
        echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}}'
        IFS= read -r unexpected
        """) { home, script in
            let value = try AccountUsageReader().readAccount(home: home, executable: script, timeout: 0.3)
            XCTAssertNotNil(value.quota); XCTAssertEqual(value.tokenError, .timeout)
        }
    }
    private func fakeCLI(_ body: String, action: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try action(directory, script)
    }
    func testOnlyInitializationAndAccountReadSent() throws {
        try fakeCLI("""
        IFS= read -r first
        case "$first" in *'"method":"initialize"'*) ;; *) exit 3;; esac
        echo '{"id":1,"result":{}}'
        IFS= read -r second
        case "$second" in *'"method":"initialized"'*) ;; *) exit 4;; esac
        IFS= read -r third
        case "$third" in *'"method":"account/usage/read"'*) ;; *) exit 5;; esac
        echo '{"id":2,"result":{"summary":{"lifetimeTokens":12500067890},"dailyUsageBuckets":null}}'
        IFS= read -r unexpected
        """) { home, script in
            let result = try AccountUsageReader().read(home: home, executable: script, timeout: 2)
            XCTAssertEqual(result.total, 12500067890); XCTAssertNil(result.yesterday)
        }
    }
    func testTimeoutAndCancellationAreBounded() throws {
        try fakeCLI("IFS= read -r line\nIFS= read -r line\n") { home, script in
            let start = Date()
            XCTAssertThrowsError(try AccountUsageReader().read(home: home, executable: script, timeout: 0.2)) {
                XCTAssertEqual($0 as? AccountUsageError, .timeout)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            let reader = AccountUsageReader(); reader.cancel()
            XCTAssertThrowsError(try reader.read(home: home, executable: script)) { XCTAssertEqual($0 as? AccountUsageError, .cancelled) }
        }
    }
    func testServerErrorAndOversizedResponseFailClosed() throws {
        try fakeCLI("IFS= read -r line\necho '{\"id\":1,\"error\":{\"code\":-1}}'\n") { home, script in
            XCTAssertThrowsError(try AccountUsageReader().read(home: home, executable: script)) { XCTAssertEqual($0 as? AccountUsageError, .serverError) }
        }
        try fakeCLI("IFS= read -r line\n/usr/bin/head -c 2100000 /dev/zero\n") { home, script in
            XCTAssertThrowsError(try AccountUsageReader().read(home: home, executable: script)) { XCTAssertEqual($0 as? AccountUsageError, .invalidResponse) }
        }
    }
}
