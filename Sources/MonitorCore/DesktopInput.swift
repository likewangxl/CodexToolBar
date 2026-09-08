import Foundation
import Darwin

public struct DesktopInputError: LocalizedError {
    public let message: String
    public let uncertain: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, uncertain: Bool = false) { self.message = message; self.uncertain = uncertain }
}

/// One short-lived connection per deliberate Send. No background writer and no
/// retry of a mutation, including when an acknowledgement is lost.
public final class DesktopInputClient {
    private let home: URL
    public init(home: URL) { self.home = home }
    public func send(taskID: String, text: String) throws {
        _ = try Self.message(taskID: taskID, text: text, active: false)
        let socket = try DesktopInputSocket(home: home)
        let target = try socket.inspect(taskID: taskID)
        let request = try Self.message(taskID: taskID, text: text, active: target.active)
        do {
            _ = try socket.request(method: request.method, version: request.version, params: request.params, target: target.owner)
        } catch {
            // Even an error returned by the owner may follow an uncertain app-server
            // submission. Do not invite a blind retry or choose another recipient.
            throw DesktopInputError("发送结果未确认，请在 Codex 查看；本工具不会自动重发。", uncertain: true)
        }
    }
    public func probe(taskID: String) throws -> Bool {
        try DesktopInputSocket(home: home).inspect(taskID: taskID).active
    }
    static func message(taskID: String, text: String, active: Bool) throws -> (method: String, version: Int, params: [String: Any]) {
        guard UUID(uuidString: taskID) != nil else { throw DesktopInputError("请选择本机 Codex 任务。") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32_768 else { throw DesktopInputError("语音文字为空或过长，请重新录音。") }
        let messageID = UUID().uuidString
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        let request: [String: Any] = ["threadId": taskID, "input": input, "clientUserMessageId": messageID]
        let context: [String: Any] = ["inheritThreadSettings": true, "attachments": [], "commentAttachments": []]
        if active {
            return ("thread-follower-steer-turn", 1, ["conversationId": taskID, "input": input, "clientUserMessageId": messageID, "attachments": [], "restoreMessage": ["request": request, "context": context]])
        }
        return ("thread-follower-start-turn", 2, ["conversationId": taskID, "turnStart": ["request": request, "context": context]])
    }
}

private final class DesktopInputSocket {
    private var fd: Int32 = -1
    private var clientID = ""
    private var buffer = Data()
    private var state: [String: Any]?
    private var revision = -1
    private var expectedID = "", expectedOwner = ""
    private var following = false
    private let timeout: TimeInterval = 12
    init(home: URL) throws {
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw DesktopInputError("Codex 未连接，请先打开 Codex。")
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw DesktopInputError("Codex 路径过长。") }
        withUnsafeMutableBytes(of: &address.sun_path) { dest in bytes.withUnsafeBytes { dest.copyMemory(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DesktopInputError("无法连接 Codex。") }
        var flag: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { close(fd); fd = -1; throw DesktopInputError("无法连接 Codex，请确认桌面端正在运行。") }
        do {
            let reply = try request(method: "initialize", version: 0, params: ["clientType": "codex-touchbar-input"])
            guard let id = (reply["result"] as? [String: Any])?["clientId"] as? String else { throw DesktopInputError("Codex 接口版本不兼容。") }
            clientID = id
        } catch { close(fd); fd = -1; throw error }
    }
    deinit {
        if fd >= 0 {
            if following { try? follow(false) }
            close(fd)
        }
    }
    func inspect(taskID: String) throws -> (owner: String, active: Bool) {
        guard UUID(uuidString: taskID) != nil else { throw DesktopInputError("请选择本机 Codex 任务。") }
        expectedID = taskID
        let reply = try request(method: "thread-owner-discovery", version: 1, params: ["hostId": "local", "conversationId": taskID])
        guard let owner = reply["handledByClientId"] as? String else { throw DesktopInputError("请先在 Codex 打开这个任务，再发送。") }
        expectedOwner = owner
        try follow(true); following = true
        let deadline = Date().addingTimeInterval(timeout)
        while state == nil { try handle(read(deadline: deadline)) }
        guard let state, state["id"] as? String == taskID else { throw DesktopInputError("任务状态不匹配，未发送。") }
        let runtime = (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String
        let last = LiveStateParser.turns(state).last?["status"] as? String
        guard runtime == "active" || runtime == "idle" || last == "inProgress" || ["completed", "interrupted", "failed"].contains(last ?? "") else {
            throw DesktopInputError("任务状态尚未就绪，请在 Codex 中打开后重试。")
        }
        return (owner, runtime == "active" || (runtime == nil && last == "inProgress"))
    }
    private func follow(_ enabled: Bool) throws {
        try write(["type": "broadcast", "sourceClientId": clientID, "version": 1, "method": "thread-stream-following-changed", "params": ["hostId": "local", "conversationId": expectedID, "following": enabled], "targetClientIds": [expectedOwner]])
    }
    func request(method: String, version: Int, params: [String: Any], target: String? = nil) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID, "method": method, "version": version, "params": params, "timeoutMs": 11000]
        if let target { message["targetClientId"] = target }
        try write(message)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try read(deadline: deadline)
            if reply["type"] as? String == "response", reply["requestId"] as? String == id {
                guard reply["method"] as? String == method, reply["resultType"] as? String == "success",
                      target == nil || reply["handledByClientId"] as? String == target else {
                    throw DesktopInputError("Codex 未接受请求，请打开对应任务检查连接。")
                }
                return reply
            }
            try handle(reply)
        }
    }
    private func handle(_ message: [String: Any]) throws {
        if message["type"] as? String == "client-discovery-request", let id = message["requestId"] as? String {
            try write(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
        }
        guard message["type"] as? String == "broadcast", message["method"] as? String == "thread-stream-state-changed",
              message["sourceClientId"] as? String == expectedOwner,
              let params = message["params"] as? [String: Any], params["hostId"] as? String == "local", params["conversationId"] as? String == expectedID else { return }
        guard message["version"] as? Int == 11 else { throw DesktopInputError("当前 Codex 协议版本不兼容（需要 v11），未发送。请更新本工具。") }
        guard let change = params["change"] as? [String: Any], let next = change["revision"] as? Int else { return }
        if change["type"] as? String == "snapshot", let value = change["conversationState"] as? [String: Any] {
            state = StreamProjection.prune(value, root: true) as? [String: Any]; revision = next
        } else if let previous = state, change["baseRevision"] as? Int == revision, let patches = change["patches"] as? [[String: Any]] {
            state = try JSONPatch.apply(StreamProjection.patches(patches), to: previous) as? [String: Any]; revision = next
        } else { throw DesktopInputError("任务状态已变化，请重试；尚未发送。") }
    }
    private func write(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var size = UInt32(payload.count).littleEndian
        var data = Data(bytes: &size, count: 4); data.append(payload)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DesktopInputError("Codex 连接已中断。") }; offset += count
            }
        }
    }
    private func read(deadline: Date) throws -> [String: Any] {
        while true {
            if buffer.count >= 4 {
                let size = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard size > 0, size <= 32 * 1024 * 1024 else { throw DesktopInputError("Codex 数据格式不兼容。") }
                if buffer.count >= size + 4 {
                    let payload = Data(buffer.dropFirst(4).prefix(size)); buffer = Data(buffer.dropFirst(size + 4))
                    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw DesktopInputError("Codex 数据格式不兼容。") }
                    return object
                }
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw DesktopInputError("Codex 响应超时。") }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&item, 1, Int32(min(remaining * 1000, 12000)))
            if rc < 0 && errno == EINTR { continue }
            guard rc > 0 else { throw DesktopInputError("Codex 响应超时。") }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw DesktopInputError("Codex 连接已中断。") }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}
