import XCTest
@testable import MonitorCore

final class ExecutionHistoryTests: XCTestCase {
    private func event(_ item: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "item_completed", "item": item]], options: [.sortedKeys])
        data.append(10); return data
    }
    private func fixture() throws -> (URL, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, sessions.appendingPathComponent("test.jsonl"))
    }
    func testIndexesEveryVisibleStepAndLoadsOutputLazily() throws {
        let (home, url) = try fixture()
        var data = try event(["type": "AgentMessage", "id": "message", "content": [["type": "text", "text": "正在验证"]]])
        data.append(try event(["type": "Reasoning", "id": "reasoning", "raw_content": ["never display"]]))
        let output = String(repeating: "large output\n", count: 40_000)
        data.append(try event(["type": "CommandExecution", "id": "cmd", "command": ["swift", "test"], "aggregated_output": output, "exit_code": 0, "status": "completed"]))
        data.append(try event(["type": "ImageView", "id": "image", "path": "file:///tmp/check.png"]))
        try data.write(to: url)
        let reader = try ExecutionHistory(url: url, home: home)
        let rows = try reader.refresh()
        XCTAssertEqual(rows.map(\.id), ["message", "cmd", "image"])
        XCTAssertEqual(rows[0].preview, "正在验证")
        XCTAssertEqual(rows[1].preview, "swift test")
        XCTAssertEqual(rows[2].title, "已查看 1 张图像")
        let detail = try reader.detail(rows[1])
        XCTAssertTrue(detail.contains(output)); XCTAssertTrue(detail.contains("swift test")); XCTAssertTrue(detail.contains("退出码：0"))
        let bytes = reader.bytesRead
        XCTAssertEqual(try reader.refresh(), rows)
        XCTAssertEqual(reader.bytesRead, bytes, "Idle refresh must not reread the log")
    }
    func testPartialAppendUpdateAndTruncation() throws {
        let (home, url) = try fixture()
        let first = try event(["type": "CommandExecution", "id": "cmd", "status": "inProgress"])
        try first.write(to: url)
        let reader = try ExecutionHistory(url: url, home: home)
        XCTAssertEqual(try reader.refresh().count, 1)
        let next = try event(["type": "CommandExecution", "id": "cmd", "status": "completed", "aggregated_output": "done"])
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: next.dropLast(4))
        XCTAssertEqual(try reader.refresh().first?.status, "inProgress")
        try handle.write(contentsOf: next.suffix(4))
        let rows = try reader.refresh()
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].status, "completed")
        XCTAssertTrue(try reader.detail(rows[0]).contains("done"))
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: event(["type": "ImageView", "id": "new", "path": "/tmp/new.png"]))
        XCTAssertEqual(try reader.refresh().map(\.id), ["new"])
    }
    func testActivityIconsImageCountsAndMessageBoundaries() {
        let activities = ActivityParser.parse([
            ["type": "ImageView", "id": "a"], ["type": "imageView", "id": "b"],
            ["type": "AgentMessage", "id": "message"], ["type": "imageView", "id": "c"],
            ["type": "CommandExecution", "id": "cmd", "parsed_cmd": [["type": "read"], ["type": "unknown"]]],
            ["type": "ContextCompaction", "id": "ctx"]
        ])
        XCTAssertEqual(activities.map(\.label), ["已查看 2 张图像", "已查看 1 张图像", "已读取文件 · 运行了命令", "上下文已自动压缩"])
        XCTAssertEqual(activities.map(\.symbol), ["photo.on.rectangle", "photo.on.rectangle", "book", "text.badge.minus"])
    }
    func testExtensionsDiffsAndNoOpaqueImagePayloads() {
        XCTAssertEqual(ExecutionParser.step(["type": "Extension", "id": "web", "kind": "web.search"])?.kind, "webSearch")
        XCTAssertEqual(ExecutionParser.step(["type": "Extension", "id": "image", "kind": "image_gen.generation"])?.title, "已生成图像")
        let diff = ExecutionParser.details(["type": "FileChange", "changes": ["App.swift": ["unified_diff": "- old\n+ new"]]])
        XCTAssertTrue(diff.contains("App.swift")); XCTAssertTrue(diff.contains("- old\n+ new"))
        let result = ExecutionParser.details(["type": "McpToolCall", "result": ["image": "data:image/png;base64,secretblob", "text": "visible"]])
        XCTAssertFalse(result.contains("secretblob")); XCTAssertTrue(result.contains("visible"))
    }
    func testLogPathMustStayInsideSessions() throws {
        let (home, _) = try fixture()
        XCTAssertThrowsError(try ExecutionHistory(url: URL(fileURLWithPath: "/etc/passwd"), home: home))
        let link = home.appendingPathComponent("sessions/outside.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try ExecutionHistory(url: link, home: home))
    }
}
