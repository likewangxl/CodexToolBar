import Foundation
import Darwin

public final class Monitor {
    private let queue = DispatchQueue(label: "local.codex.touchbar.monitor", qos: .utility)
    private let store: LocalStore
    private var ipc: IPCClient!
    private var timer: DispatchSourceTimer?
    private var databaseWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var tails: [String: TelemetryTail] = [:]
    private var contexts: [String: ContextUsage] = [:]
    private var pendingStates: [String: [String: Any]] = [:]
    private var flushWork: DispatchWorkItem?
    private var scanWork: DispatchWorkItem?
    private var tasks: [TaskState] = []
    private var live: [String: TaskState] = [:]
    private var incompatible: [String: Int] = [:]
    private var lastOutput: [TaskState] = []
    private var lastLabel = ""
    private var lastUsage: UsageSnapshot?
    private var usage: UsageSnapshot?
    private var selectedID: String?
    private var lastScan = Date.distantPast
    private var suspended = false
    private var message = "正在连接 Codex…"
    public private(set) var updateCount = 0 // Read on main queue, useful for probe/idle verification.
    public var onUpdate: (([TaskState], String) -> Void)?
    public var onUsage: ((UsageSnapshot?) -> Void)?
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        store = LocalStore(home: home); ipc = IPCClient(home: home, queue: queue)
        ipc.onConnection = { [weak self] connected in
            guard let self else { return }
            if !connected { self.live.removeAll(); self.pendingStates.removeAll(); self.incompatible.removeAll() }
            self.message = connected ? "实时连接 · 本机 Codex" : "连接断开 · 显示本地记录"
            self.scheduleFlush()
        }
        ipc.onCompatibility = { [weak self] id, version in
            guard let self else { return }
            self.incompatible[id] = version; self.scheduleFlush()
        }
        ipc.onState = { [weak self] id, state in
            guard let self else { return }; self.pendingStates[id] = state; self.scheduleFlush()
        }
        ipc.onInvalidated = { [weak self] id in
            self?.live.removeValue(forKey: id); self?.pendingStates.removeValue(forKey: id); self?.scheduleFlush()
        }
    }
    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            self.scan()
            // Only a slow recovery pass. Normal stream and file changes wake us directly.
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 20, repeating: .seconds(20), leeway: .seconds(3))
            timer.setEventHandler { [weak self] in guard let self, !self.suspended else { return }; self.scan() }
            self.timer = timer; timer.resume()
        }
    }
    public func select(_ id: String?) {
        queue.async { guard self.selectedID != id else { return }; self.selectedID = id; self.scheduleScan() }
    }
    public func setSuspended(_ value: Bool) {
        queue.async {
            guard self.suspended != value else { return }; self.suspended = value
            if value {
                self.ipc.updateSubscriptions([]); self.ipc.disconnect(); self.tails.removeAll()
                self.databaseWatchers.values.forEach { $0.cancel() }; self.databaseWatchers.removeAll()
                self.scanWork?.cancel(); self.scanWork = nil
            } else { self.scan() }
        }
    }
    private func scheduleScan() {
        guard !suspended, scanWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.scanWork = nil; self?.scan() }
        scanWork = work
        queue.asyncAfter(deadline: .now() + max(0.1, 5 - Date().timeIntervalSince(lastScan)), execute: work)
    }
    private func scan() {
        guard !suspended else { return }; lastScan = Date()
        do {
            let metadata = try store.list()
            tasks = metadata.enumerated().map { index, task in
                guard index < 2 || task.id == selectedID else { return task }
                return live[task.id] == nil ? store.fallback(task) : task
            }
            var wanted = tasks.prefix(2).map(\.id)
            if let selectedID, tasks.contains(where: { $0.id == selectedID }), !wanted.contains(selectedID) { wanted.append(selectedID) }
            let ids = Set(wanted)
            live = live.filter { ids.contains($0.key) }; contexts = contexts.filter { ids.contains($0.key) }
            tails = tails.filter { ids.contains($0.key) }
            incompatible = incompatible.filter { ids.contains($0.key) }
            ipc.updateSubscriptions(wanted)
            for task in tasks where ids.contains(task.id) && tails[task.id] == nil {
                let url = URL(fileURLWithPath: task.rolloutPath).standardizedFileURL.resolvingSymlinksInPath()
                let sessions = store.home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
                guard url.path.hasPrefix(sessions), url.pathExtension == "jsonl" else { continue }
                let tail = TelemetryTail(url: url, queue: queue)
                tail.onRecord = { [weak self] context, snapshot in
                    guard let self else { return }
                    if let context { self.contexts[task.id] = context }
                    if let snapshot, snapshot.isNewer(than: self.usage) { self.usage = snapshot }
                    self.scheduleFlush()
                }
                tails[task.id] = tail; tail.start()
            }
            for tail in tails.values { tail.start() } // Retry a file recreated after rotation.
            watchDatabase()
        } catch { message = error.localizedDescription }
        scheduleFlush()
    }
    private func watchDatabase() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: store.home, includingPropertiesForKeys: nil)) ?? []
        let paths = Set(urls.filter { $0.lastPathComponent.range(of: #"^state_\d+\.sqlite(-wal)?$"#, options: .regularExpression) != nil }.map(\.path))
        for path in databaseWatchers.keys.filter({ !paths.contains($0) }) { databaseWatchers.removeValue(forKey: path)?.cancel() }
        for path in paths where databaseWatchers[path] == nil {
            let fd = open(path, O_EVTONLY | O_CLOEXEC); guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self else { return }
                if source?.data.intersection([.rename, .delete]).isEmpty == false { self.databaseWatchers.removeValue(forKey: path)?.cancel() }
                self.scheduleScan()
            }
            source.setCancelHandler { close(fd) }; databaseWatchers[path] = source; source.resume()
        }
    }
    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushWork = nil; self?.flush() }
        flushWork = work; queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func flush() {
        for (id, state) in pendingStates {
            guard let base = tasks.first(where: { $0.id == id }) else { continue }
            live[id] = LiveStateParser.apply(state, to: live[id] ?? base)
        }
        pendingStates.removeAll(keepingCapacity: true)
        let output = tasks.map { task -> TaskState in
            var current = live[task.id] ?? task
            // Recency/name come from the index; streaming content does not reorder cards.
            current.title = task.title; current.updatedAt = task.updatedAt
            if current.context == nil { current.context = contexts[task.id] }
            if self.incompatible[task.id] != nil { current.isLive = false; current.status = .unknown; current.connectionIssue = "协议不兼容" }
            current.lastEventAt = 0 // Event timestamps do not change anything visible.
            return current
        }
        let effectiveMessage = incompatible.isEmpty ? message : "Codex 协议不兼容：需要 v11，收到 " + Set(incompatible.values).sorted().map { $0 < 0 ? "未知版本" : "v\($0)" }.joined(separator: "、") + " · 已禁用对应任务发送"
        if output != lastOutput || effectiveMessage != lastLabel {
            lastOutput = output; lastLabel = effectiveMessage; let label = effectiveMessage
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.updateCount += 1; self.onUpdate?(output, label)
            }
        }
        if usage != lastUsage {
            lastUsage = usage; let snapshot = usage
            DispatchQueue.main.async { [weak self] in self?.onUsage?(snapshot) }
        }
    }
}
