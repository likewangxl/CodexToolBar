import XCTest
import Darwin
@testable import MonitorCore

final class InputAndPersistenceTests: XCTestCase {
    let taskID = "11111111-1111-4111-8111-111111111111"
    func testUserHideAndLockPreventRestore() {
        var policy = PresentationPolicy()
        XCTAssertFalse(policy.shouldRestore(visible: false, now: 0))
        policy.wanted = true
        XCTAssertTrue(policy.shouldRestore(visible: false, now: 0))
        policy.suspended = true
        XCTAssertFalse(policy.shouldRestore(visible: false, activation: true, now: 20))
        policy.suspended = false
        XCTAssertTrue(policy.shouldRestore(visible: false, now: 20))
        policy.wanted = false
        XCTAssertFalse(policy.shouldRestore(visible: false, activation: true, now: 50))
    }
    func testRestoreThrottlesRepeatedInvisibleEventsAndDoesNoVisibleWork() {
        var policy = PresentationPolicy(); policy.wanted = true
        XCTAssertTrue(policy.shouldRestore(visible: false, now: 0))
        XCTAssertFalse(policy.shouldRestore(visible: false, now: 0.5))
        XCTAssertTrue(policy.shouldRestore(visible: false, now: 2))
        XCTAssertFalse(policy.shouldRestore(visible: false, now: 4))
        XCTAssertFalse(policy.shouldRestore(visible: true, now: 10))
        XCTAssertTrue(policy.shouldRestore(visible: true, activation: true, now: 11))
        policy.pinned = false
        XCTAssertFalse(policy.shouldRestore(visible: false, activation: true, now: 100))
    }
    func testStartPreservesSettingsAndRecipient() throws {
        let value = try DesktopInputClient.message(taskID: taskID, text: "  检查代码 👋  ", active: false)
        XCTAssertEqual(value.method, "thread-follower-start-turn"); XCTAssertEqual(value.version, 2)
        XCTAssertEqual(value.params["conversationId"] as? String, taskID)
        let operation = try XCTUnwrap(value.params["turnStart"] as? [String: Any])
        let request = try XCTUnwrap(operation["request"] as? [String: Any])
        XCTAssertEqual(request["threadId"] as? String, taskID)
        XCTAssertEqual((request["input"] as? [[String: Any]])?.first?["text"] as? String, "检查代码 👋")
        XCTAssertNil(request["model"]); XCTAssertNil(request["approvalPolicy"]); XCTAssertNil(request["sandboxPolicy"])
        XCTAssertEqual((operation["context"] as? [String: Any])?["inheritThreadSettings"] as? Bool, true)
    }
    func testActiveTaskGetsSteeringAndEmptyInputRejected() throws {
        let value = try DesktopInputClient.message(taskID: taskID, text: "继续", active: true)
        XCTAssertEqual(value.method, "thread-follower-steer-turn"); XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.params["conversationId"] as? String, taskID)
        XCTAssertNotNil(value.params["restoreMessage"])
        XCTAssertThrowsError(try DesktopInputClient.message(taskID: taskID, text: "\n ", active: false))
        XCTAssertThrowsError(try DesktopInputClient.message(taskID: "demo", text: "继续", active: false))
    }
    func testSocketSendAcknowledgedOnce() throws { try fixture(active: false, loseAck: false, wrongTask: false) }
    func testSocketSteerAcknowledgedOnce() throws { try fixture(active: true, loseAck: false, wrongTask: false) }
    func testLostAcknowledgementDoesNotRetry() throws { try fixture(active: true, loseAck: true, wrongTask: false) }
    func testWrongSnapshotNeverSends() throws { try fixture(active: false, loseAck: false, wrongTask: true) }
    func testUnsupportedProtocolNeverSubmits() throws { try fixture(active: false, loseAck: false, wrongTask: false, streamVersion: 12) }
    private func fixture(active: Bool, loseAck: Bool, wrongTask: Bool, streamVersion: Int = 11) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ctb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { dest in bytes.withUnsafeBytes { dest.copyMemory(from: $0) } }
        let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(rc, 0); chmod(path, 0o600); XCTAssertEqual(listen(server, 1), 0)
        let completed = expectation(description: "socket closed after one submit")
        let id = taskID
        DispatchQueue.global().async {
            let fd = accept(server, nil, nil); defer { close(fd); completed.fulfill() }
            var flag: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
            var mutations = 0
            func readBytes(_ count: Int) -> Data? {
                var data = Data(count: count); var offset = 0
                let ok = data.withUnsafeMutableBytes { raw -> Bool in
                    while offset < count { let n = recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0); if n <= 0 { return false }; offset += n }; return true
                }
                return ok ? data : nil
            }
            func send(_ value: [String: Any]) {
                let payload = try! JSONSerialization.data(withJSONObject: value); var size = UInt32(payload.count).littleEndian
                var data = Data(bytes: &size, count: 4); data.append(payload)
                _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            }
            while let header = readBytes(4) {
                let size = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard let bytes = readBytes(size), let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { break }
                let method = message["method"] as? String ?? ""
                let params = message["params"] as? [String: Any] ?? [:]
                if method == "thread-stream-following-changed" {
                    if params["following"] as? Bool == true {
                        send(["type": "broadcast", "method": "thread-stream-state-changed", "version": streamVersion, "sourceClientId": "owner", "params": ["hostId": "local", "conversationId": id, "change": ["type": "snapshot", "revision": 1, "conversationState": ["id": wrongTask ? "WRONG" : id, "threadRuntimeStatus": ["type": active ? "active" : "idle"]]]]])
                    }
                    continue
                }
                var response: [String: Any] = ["type": "response", "method": method, "requestId": message["requestId"]!, "resultType": "success", "handledByClientId": "owner", "result": [:]]
                if method == "initialize" { response["result"] = ["clientId": "fixture-client"] }
                else if method == "thread-owner-discovery" { XCTAssertEqual(params["conversationId"] as? String, id) }
                else {
                    mutations += 1
                    XCTAssertEqual(method, active ? "thread-follower-steer-turn" : "thread-follower-start-turn")
                    XCTAssertEqual(message["targetClientId"] as? String, "owner")
                    XCTAssertEqual(params["conversationId"] as? String, id)
                    if loseAck { break }
                }
                send(response)
            }
            XCTAssertEqual(mutations, wrongTask || streamVersion != 11 ? 0 : 1)
        }
        do {
            try DesktopInputClient(home: home).send(taskID: taskID, text: "仅发送给指定任务")
            XCTAssertFalse(loseAck || wrongTask || streamVersion != 11)
        } catch {
            XCTAssertTrue(loseAck || wrongTask || streamVersion != 11, error.localizedDescription)
            XCTAssertEqual((error as? DesktopInputError)?.uncertain, loseAck)
        }
        wait(for: [completed], timeout: 3)
    }
}
