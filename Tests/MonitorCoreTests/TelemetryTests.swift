import XCTest
@testable import MonitorCore

final class TelemetryTests: XCTestCase {
    func testContextMatchesDesktopLastRequestAndCompaction() {
        let base = TaskState(id: "t", title: "T")
        var usage: [String: Any] = ["total": ["totalTokens": 9207896], "last": ["totalTokens": 195727], "modelContextWindow": 258400]
        let state = LiveStateParser.apply(["latestTokenUsageInfo": usage], to: base)
        XCTAssertEqual(state.context?.percent ?? 0, 75.7457, accuracy: 0.001)
        usage["last"] = ["totalTokens": 48898]
        let compacted = LiveStateParser.apply(["latestTokenUsageInfo": usage], to: state)
        XCTAssertLessThan(compacted.context!.used, state.context!.used)
        XCTAssertNil(ContextUsage(used: nil, window: 100))
        XCTAssertNil(ContextUsage(used: 10, window: 0))
        XCTAssertNil(ContextUsage(used: -1, window: 100))
        XCTAssertEqual(ContextUsage(used: 200, window: 100)?.percent, 100)
    }
    func testQuotaUsesNewestObservationAcrossTasks() {
        let older = UsageSnapshot(primary: QuotaWindow(usedPercent: 94, minutes: 10080, resetsAt: 100), observedAt: 90)
        let newer = UsageSnapshot(primary: QuotaWindow(usedPercent: 7, minutes: 10080, resetsAt: 200), observedAt: 110)
        XCTAssertFalse(older.isNewer(than: newer))
        XCTAssertTrue(newer.isNewer(than: older))
        XCTAssertEqual(newer.primary?.label, "7日")
        XCTAssertEqual(QuotaWindow(usedPercent: 101, minutes: 300, resetsAt: 200).usedPercent, 100)
    }
    func testProjectionSkipsLargeOutputButKeepsRevisionCompatibleIndices() throws {
        let document: [String: Any] = ["turns": [["items": [["type": "commandExecution", "status": "inProgress", "aggregatedOutput": String(repeating: "x", count: 1_000_000)], ["type": "agentMessage", "text": "hi"]]]], "unrelated": "discard"]
        let slim = StreamProjection.prune(document, root: true)
        let ignored = try StreamProjection.patches([["op": "replace", "path": ["turns", 0, "items", 0, "aggregatedOutput"], "value": "new output"]])
        XCTAssertTrue(ignored.isEmpty)
        let patches = try StreamProjection.patches([
            ["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"],
            ["op": "replace", "path": ["turns", 0, "items", 1, "text"], "value": "你好"],
            ["op": "add", "path": ["turns", 0, "items", 2], "value": ["type": "commandExecution", "aggregatedOutput": "private", "status": "inProgress"]]
        ])
        let updated = try JSONPatch.apply(patches, to: slim) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: updated)
        XCTAssertLessThan(data.count, 400)
        let task = LiveStateParser.apply(updated, to: TaskState(id: "t", title: "T"))
        XCTAssertEqual(task.reply, "你好")
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("aggregatedOutput"))
    }
    func testIncrementalTailPartialAppendAndTruncate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.jsonl")
        func record(_ tokens: Int) -> Data {
            Data(("{\"timestamp\":\"2026-09-07T08:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)},\"model_context_window\":1000},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":7,\"window_minutes\":10080,\"resets_at\":1789373763}}}}\n").utf8)
        }
        let bytes = record(100)
        try Data(bytes.dropLast(10)).write(to: url)
        let tail = TelemetryTail(url: url, queue: DispatchQueue(label: "test"))
        var contexts: [Int] = []; var snapshots: [UsageSnapshot] = []
        tail.onRecord = { ctx, usage in if let ctx { contexts.append(ctx.used) }; if let usage { snapshots.append(usage) } }
        tail.read(); XCTAssertTrue(contexts.isEmpty)
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd(); try file.write(contentsOf: bytes.suffix(10)); try file.close()
        tail.read(); XCTAssertEqual(contexts, [100]); XCTAssertEqual(snapshots.first?.primary?.usedPercent, 7)
        let read = tail.bytesRead; tail.read(); XCTAssertEqual(tail.bytesRead, read)
        try record(20).write(to: url); tail.read()
        XCTAssertEqual(contexts, [100, 20])
    }
}
