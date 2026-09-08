import XCTest
@testable import MonitorCore

final class MonitorCoreTests: XCTestCase {
    private var base: TaskState { TaskState(id: "task-1", title: "测试任务") }
    private func state(runtime: String = "active", flags: [String] = [], turnStatus: String = "inProgress", items: [[String: Any]] = [], requests: [Any] = []) -> [String: Any] {
        ["threadRuntimeStatus": ["type": runtime, "activeFlags": flags], "requests": requests,
         "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": ["turn-1": ["status": turnStatus, "items": items]], "islands": [["entries": [["key": "turn-1", "value": "turn-1"]]]]]]]
    }
    func testCanonicalHistoryReadsAssistantButNotReasoningOrToolOutput() {
        let input = state(items: [["type": "agentMessage", "text": "正在检查编译结果", "phase": "commentary"], ["type": "reasoning", "text": "private reasoning"], ["type": "commandExecution", "status": "inProgress", "aggregatedOutput": "sensitive output"]])
        let result = LiveStateParser.apply(input, to: base)
        XCTAssertEqual(result.reply, "正在检查编译结果")
        XCTAssertEqual(result.status, .tool)
        XCTAssertTrue(result.isLive)
    }
    func testApprovalAndInputOverrideWorking() {
        for flag in ["waitingOnApproval", "waitingOnUserInput"] {
            XCTAssertEqual(LiveStateParser.apply(state(flags: [flag]), to: base).status, .waiting)
        }
        XCTAssertEqual(LiveStateParser.apply(state(requests: [["id": "request"]]), to: base).status, .waiting)
    }
    func testTerminalStatesAndNewTurnClearOldReply() {
        XCTAssertEqual(LiveStateParser.apply(state(runtime: "idle", turnStatus: "completed"), to: base).status, .completed)
        XCTAssertEqual(LiveStateParser.apply(state(runtime: "idle", turnStatus: "interrupted"), to: base).status, .interrupted)
        XCTAssertEqual(LiveStateParser.apply(state(runtime: "systemError"), to: base).status, .failed)
        var old = base; old.reply = "上一轮已完成"
        XCTAssertEqual(LiveStateParser.apply(state(), to: old).reply, "")
    }
    func testActiveRuntimeOverridesCompletedPriorTurn() {
        XCTAssertEqual(LiveStateParser.apply(state(turnStatus: "completed"), to: base).status, .working)
    }
    func testLegacyTurnsAndUnknownSchema() {
        let input: [String: Any] = ["turns": [["status": "completed", "items": [["type": "agentMessage", "text": "完成"]]]]]
        XCTAssertEqual(LiveStateParser.apply(input, to: base).status, .completed)
        XCTAssertEqual(LiveStateParser.apply([:], to: base).status, .unknown)
    }
    func testImmerPatchesStreamingUnicodeAndListChanges() throws {
        let initial: [String: Any] = ["turns": [["items": [["text": "你"]]]]]
        let patches: [[String: Any]] = [
            ["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "你好 👨‍💻"],
            ["op": "add", "path": ["turns", 0, "items", 1], "value": ["text": "完成"]],
            ["op": "remove", "path": ["turns", 0, "items", 0]]
        ]
        let result = try JSONPatch.apply(patches, to: initial) as! [String: Any]
        let turns = result["turns"] as! [[String: Any]]
        let items = turns[0]["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0]["text"] as? String, "完成")
    }
    func testJSONPointerEscapesNullAndInvalidPatchAtomicity() throws {
        let initial: [String: Any] = ["a/b": ["~": "value"]]
        let result = try JSONPatch.apply([["op": "replace", "path": "/a~1b/~0", "value": NSNull()]], to: initial) as! [String: Any]
        XCTAssertTrue((result["a/b"] as! [String: Any])["~"] is NSNull)
        XCTAssertThrowsError(try JSONPatch.apply([["op": "replace", "path": ["missing", 0], "value": "x"]], to: initial))
        XCTAssertEqual((initial["a/b"] as! [String: Any])["~"] as? String, "value")
    }
    func testTranscriptRequiresCompletionEvent() {
        var task = base
        TranscriptParser.apply(["type": "event_msg", "payload": ["type": "task_started"]], to: &task)
        TranscriptParser.apply(["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "final", "content": [["type": "output_text", "text": "完成说明"]]]], to: &task)
        XCTAssertEqual(task.status, .working)
        TranscriptParser.apply(["type": "event_msg", "payload": ["type": "task_complete"]], to: &task)
        XCTAssertEqual(task.status, .completed); XCTAssertEqual(task.reply, "完成说明")
    }
    func testFallbackNeverClaimsActiveAfterDisconnectAndIgnoresPartialLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = sessions.appendingPathComponent("test.jsonl")
        let text = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}"
        try text.write(to: path, atomically: true, encoding: .utf8)
        let task = TaskState(id: "task", title: "任务", rolloutPath: path.path)
        let result = LocalStore(home: directory).fallback(task)
        XCTAssertEqual(result.status, .unknown); XCTAssertFalse(result.isLive)
    }
    func testFallbackRejectsPathsOutsideCodexSessions() {
        let task = TaskState(id: "x", title: "x", rolloutPath: "/etc/passwd")
        XCTAssertEqual(LocalStore(home: URL(fileURLWithPath: "/tmp")).fallback(task).reply, "")
    }
    func testAgentActivityPreservesNameColorAndCompletionMeaning() {
        let items: [[String: Any]] = [
            ["type": "subAgentActivity", "id": "1", "agentPath": "/root/luna_backend", "agentThreadId": "backend", "kind": "interacted"],
            ["type": "subAgentActivity", "id": "2", "agentPath": "/root/luna_ui", "agentThreadId": "ui", "kind": "completed"]
        ]
        let activities = ActivityParser.parse(items)
        XCTAssertEqual(activities[0].label, "Luna backend有了更新")
        XCTAssertEqual(activities[0].agents[0].style, 1)
        XCTAssertEqual(activities[1].label, "Luna ui已完成")
        XCTAssertEqual(activities[1].agents[0].style, 2)
    }
    func testReadEditCommandIconsAndPrivateItemsOmitted() {
        let activities = ActivityParser.parse([
            ["type": "reasoning", "text": "internal"],
            ["type": "commandExecution", "status": "completed", "commandActions": [["type": "read"]]],
            ["type": "fileChange", "status": "completed"],
            ["type": "commandExecution", "status": "inProgress", "commandActions": [["type": "unknown"]]]
        ])
        XCTAssertEqual(activities.map(\.symbol), ["book", "pencil", "terminal"])
        XCTAssertEqual(activities.map(\.label), ["已读取文件", "编辑了文件", "正在运行命令"])
    }
}
