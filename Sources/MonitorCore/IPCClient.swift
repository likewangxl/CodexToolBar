import Foundation
import Darwin

/// An observer of the existing desktop router. Never starts an app-server, resumes
/// a task, submits input, or answers approval requests. All methods are allowlisted.
final class IPCClient {
    let queue: DispatchQueue
    let socketURL: URL
    var onState: ((String, [String: Any]) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var onInvalidated: ((String) -> Void)?
    var onCompatibility: ((String, Int?) -> Void)?
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private var clientID: String?
    private var wanted = Set<String>()
    private var subscribed = Set<String>()
    private var documents: [String: (Int, [String: Any])] = [:]
    private var owners: [String: String] = [:]
    private var lastResync: [String: Date] = [:]
    private var nextConnect = Date.distantPast
    private(set) var connected = false

    init(home: URL, queue: DispatchQueue) { socketURL = home.appendingPathComponent("ipc/ipc.sock"); self.queue = queue }

    func updateSubscriptions(_ ids: [String]) {
        wanted = Set(ids)
        if !connected { connectIfNeeded(); return }
        reconcile()
    }
    private func reconcile() {
        for id in subscribed.subtracting(wanted) {
            following(id, false); documents.removeValue(forKey: id); owners.removeValue(forKey: id); onInvalidated?(id)
        }
        for id in wanted.subtracting(subscribed) { following(id, true) }
        subscribed = wanted
    }
    func connectIfNeeded() {
        guard fd < 0, Date() >= nextConnect else { return }
        nextConnect = Date().addingTimeInterval(3)
        var info = stat()
        guard lstat(socketURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyMemory(from: source) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(descriptor); return }
        fd = descriptor; buffer.removeAll(); clientID = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(descriptor) }
        reader = source; source.resume()
        send(["type": "request", "requestId": UUID().uuidString, "method": "initialize", "version": 0, "params": ["clientType": "codex-touchbar"]])
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.fd == descriptor, !self.connected else { return }
            self.disconnect()
        }
    }
    func disconnect() {
        connected = false; clientID = nil; fd = -1
        reader?.cancel(); reader = nil
        subscribed.removeAll(); documents.removeAll(); owners.removeAll(); buffer.removeAll()
        onConnection?(false)
    }
    private func send(_ object: [String: Any]) {
        guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var frame = Data(bytes: &length, count: 4); frame.append(data)
        let success = frame.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }; offset += count
            }
            return true
        }
        if !success { disconnect() }
    }
    private func following(_ id: String, _ enabled: Bool) {
        guard let clientID else { return }
        send(["type": "broadcast", "sourceClientId": clientID, "method": "thread-stream-following-changed", "version": 1,
              "params": ["conversationId": id, "hostId": "local", "following": enabled]])
    }
    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
        if count < 0 && [EAGAIN, EINTR].contains(errno) { return }
        guard count > 0 else { disconnect(); return }
        buffer.append(contentsOf: chunk.prefix(count))
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard length > 0, length <= 32 * 1024 * 1024 else { disconnect(); return }
            guard buffer.count >= length + 4 else { return }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(length + 4))
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { disconnect(); return }
            handle(object)
        }
    }
    func handle(_ object: [String: Any]) {
        let type = object["type"] as? String
        if type == "client-discovery-request", let requestID = object["requestId"] as? String {
            send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        let method = object["method"] as? String
        if type == "response", method == "initialize", object["resultType"] as? String == "success",
           let result = object["result"] as? [String: Any], let id = result["clientId"] as? String {
            clientID = id; connected = true; onConnection?(true); reconcile(); return
        }
        guard type == "broadcast", let params = object["params"] as? [String: Any] else { return }
        if method == "client-status-changed", params["status"] as? String == "disconnected", let owner = params["clientId"] as? String {
            for id in owners.filter({ $0.value == owner }).map(\.key) {
                documents.removeValue(forKey: id); owners.removeValue(forKey: id); onInvalidated?(id)
            }
            return
        }
        if method == "thread-stream-following-status-requested" {
            for id in wanted { following(id, true) }; return
        }
        // v11 is the installed desktop stream schema (2026-09-07).
        guard method == "thread-stream-state-changed", params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String, wanted.contains(id) else { return }
        guard object["version"] as? Int == 11 else {
            documents.removeValue(forKey: id); owners.removeValue(forKey: id)
            onInvalidated?(id); onCompatibility?(id, object["version"] as? Int ?? -1); return
        }
        guard let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int else { return }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            onCompatibility?(id, nil)
            owners[id] = object["sourceClientId"] as? String
            let projected = StreamProjection.prune(state, root: true) as! [String: Any]
            documents[id] = (revision, projected); onState?(id, projected)
        } else if change["type"] as? String == "patches" {
            guard let (previousRevision, previous) = documents[id], change["baseRevision"] as? Int == previousRevision,
                  let patches = change["patches"] as? [[String: Any]],
                  let projected = try? StreamProjection.patches(patches),
                  let state = try? JSONPatch.apply(projected, to: previous) as? [String: Any] else { resync(id); return }
            documents[id] = (revision, state)
            if !projected.isEmpty { onState?(id, state) }
        }
    }
    private func resync(_ id: String) {
        if let last = lastResync[id], Date().timeIntervalSince(last) < 3 { return }
        lastResync[id] = Date(); documents.removeValue(forKey: id)
        onInvalidated?(id)
        following(id, false); following(id, true)
    }
}
