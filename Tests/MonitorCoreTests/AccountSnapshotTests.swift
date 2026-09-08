import XCTest
@testable import MonitorCore

final class AccountSnapshotTests: XCTestCase {
    func testCodexMapWinsAndWindowOrderDoesNotMatter() throws {
        let json = #"{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1999999999}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1999999999},"secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1999999999}},"other":{"primary":null}}}"#
        let value = try AccountSnapshot.quota(Data(json.utf8), now: Date(timeIntervalSince1970: 1000))
        let rows = QuotaRow.rows(value, now: 1001)
        XCTAssertEqual(rows[0].remaining, "剩余60%"); XCTAssertEqual(rows[1].remaining, "剩余80%")
    }
    func testMissingCodexBucketDoesNotUseAnotherProduct() {
        for json in [#"{"rateLimits":{"limitId":"other","primary":null}}"#, #"{"rateLimits":{"limitId":"codex","primary":null},"rateLimitsByLimitId":{}}"#] {
            XCTAssertThrowsError(try AccountSnapshot.quota(Data(json.utf8)))
        }
    }
    func testInvalidValuesAreNotClampedIntoValidAccountData() {
        for used in ["-1", "101", "1e999"] {
            let json = "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":1999999999}}}"
            XCTAssertThrowsError(try AccountSnapshot.quota(Data(json.utf8)))
        }
    }
    func testFailureAgeAndResetAreVisiblyStale() {
        let value = UsageSnapshot(primary: QuotaWindow(usedPercent: 30, minutes: 300, resetsAt: 2000), observedAt: 1000)
        XCTAssertEqual(QuotaRow.rows(value, now: 1001, state: .current)[0].remaining, "剩余70%")
        XCTAssertEqual(QuotaRow.rows(value, now: 1001, state: .failed)[0].reset, "同步失败")
        XCTAssertEqual(QuotaRow.rows(value, now: 1001, state: .failed)[0].remaining, "上次70%")
        XCTAssertEqual(QuotaRow.rows(value, now: 1001, state: .syncing)[0].reset, "正在同步")
        XCTAssertEqual(QuotaRow.rows(value, now: 1600)[0].reset, "数据过期")
        let refreshed = UsageSnapshot(primary: value.primary, observedAt: 1999)
        XCTAssertTrue(QuotaRow.rows(refreshed, now: 2000)[0].reset.hasSuffix("待同步"))
    }
    func testAbsentWindowAndUnreachableAccountAreDifferent() {
        let known = UsageSnapshot(primary: nil, observedAt: 1000)
        XCTAssertEqual(QuotaRow.rows(known, now: 1001)[0].reset, "账户无此窗口")
        XCTAssertEqual(QuotaRow.rows(nil, now: 1001, state: .failed)[0].reset, "同步失败")
        XCTAssertEqual(QuotaRow.rows(nil, now: 1001, state: .waiting)[0].reset, "正在同步")
    }
    func testResetUsesSelectedTimeZoneIncludingDST() {
        let instant = ISO8601DateFormatter().date(from: "2026-03-08T10:30:00Z")!.timeIntervalSince1970
        XCTAssertEqual(QuotaDisplay.resetTime(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!), "03/08 03:30")
        XCTAssertEqual(QuotaDisplay.resetTime(instant, timeZone: TimeZone(secondsFromGMT: 0)!), "03/08 10:30")
        XCTAssertEqual(QuotaDisplay.resetTime(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!), "03/08 18:30")
    }
    func testUnsupportedStreamInvalidatesThenValidSnapshotRecovers() {
        let client = IPCClient(home: URL(fileURLWithPath: "/nonexistent"), queue: DispatchQueue(label: "test.ipc"))
        client.updateSubscriptions(["task"])
        var invalidated = 0, versions: [Int?] = [], snapshots = 0
        client.onInvalidated = { _ in invalidated += 1 }
        client.onCompatibility = { _, version in versions.append(version) }
        client.onState = { _, _ in snapshots += 1 }
        func state(_ version: Int) -> [String: Any] { ["type": "broadcast", "method": "thread-stream-state-changed", "version": version, "params": ["hostId": "local", "conversationId": "task", "change": ["type": "snapshot", "revision": 1, "conversationState": ["id": "task"]]]] }
        client.handle(state(12)); XCTAssertEqual(invalidated, 1); XCTAssertEqual(snapshots, 0); XCTAssertEqual(versions.first!, 12)
        client.handle(state(11)); XCTAssertEqual(snapshots, 1); XCTAssertNil(versions.last!)
    }
}
