import Foundation
import CSQLite

public final class LocalStore {
    public let home: URL
    private var tails: [String: (Date, UInt64, TaskState)] = [:]
    public init(home: URL) { self.home = home }

    public func list() throws -> [TaskState] {
        let candidates = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^state_\d+\.sqlite$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let url = candidates.first else { throw StoreError.unavailable("未找到 Codex 任务数据库") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw StoreError.unavailable("暂时无法读取 Codex 任务数据库")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        // Schema probing tolerates older installations without name / millisecond columns.
        var columns = Set<String>()
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW { columns.insert(string(statement, 1)) }
        }
        sqlite3_finalize(statement); statement = nil
        guard ["id", "title", "rollout_path", "source", "archived", "updated_at"].allSatisfy(columns.contains) else {
            throw StoreError.unavailable("Codex 数据格式发生变化，需更新工具")
        }
        let title = columns.contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title"
        let time = columns.contains("recency_at_ms") ? "recency_at_ms / 1000.0" : "updated_at"
        let sql = "SELECT id, \(title), rollout_path, \(time) FROM threads WHERE archived=0 AND source NOT LIKE '%subagent%' ORDER BY \(time) DESC LIMIT 12"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.unavailable("任务列表读取失败")
        }
        defer { sqlite3_finalize(statement) }
        var tasks: [TaskState] = []
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW {
            tasks.append(TaskState(id: string(statement, 0), title: string(statement, 1), rolloutPath: string(statement, 2), updatedAt: sqlite3_column_double(statement, 3)))
            rc = sqlite3_step(statement)
        }
        guard rc == SQLITE_DONE else { throw StoreError.unavailable("任务列表读取中断，稍后重试") }
        return tasks
    }

    public func fallback(_ task: TaskState) -> TaskState {
        let url = URL(fileURLWithPath: task.rolloutPath).standardizedFileURL.resolvingSymlinksInPath()
        // The database is untrusted input. Only read the user's Codex session area.
        let sessions = home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(sessions), url.pathExtension == "jsonl",
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date, let size = attrs[.size] as? NSNumber else { return task }
        if let (date, bytes, cached) = tails[task.id], date == modified, bytes == size.uint64Value {
            var result = cached; result.title = task.title; result.updatedAt = task.updatedAt
            return result
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return task }
        defer { try? handle.close() }
        let offset = size.uint64Value > 262_144 ? size.uint64Value - 262_144 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: 262_144) else { return task }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        if data.last != 10 && !lines.isEmpty { lines.removeLast() } // Ignore an incomplete append.
        var result = task
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            TranscriptParser.apply(object, to: &result)
        }
        result.isLive = false
        // A log cannot prove that a process is still running. Never leave a false green status.
        if result.status.active { result.status = .unknown; result.activity = "最近有工作记录；等待实时连接确认" }
        tails[task.id] = (modified, size.uint64Value, result)
        if tails.count > 60 { tails = tails.filter { $0.key == task.id } }
        return result
    }

    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
    public enum StoreError: LocalizedError {
        case unavailable(String)
        public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
    }
}

public enum TranscriptParser {
    public static func apply(_ object: [String: Any], to state: inout TaskState) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        let type = payload["type"] as? String ?? ""
        if object["type"] as? String == "event_msg" {
            switch type {
            case "task_started", "turn_started": state.status = .working; state.reply = ""
            case "task_complete", "task_completed", "turn_complete":
                state.status = .completed
                if let text = payload["last_agent_message"] as? String, !text.isEmpty { state.reply = text }
            case "turn_aborted": state.status = .interrupted
            case "agent_message":
                if let text = payload["message"] as? String { state.reply = text }
            case "item_completed":
                if let item = payload["item"] as? [String: Any] {
                    state.activities = Array((state.activities + ActivityParser.parse([item])).suffix(8))
                }
            default: break
            }
        } else if object["type"] as? String == "response_item", type == "message", payload["role"] as? String == "assistant" {
            let contents = payload["content"] as? [[String: Any]] ?? []
            let text = contents.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { state.reply = text }
            // A final message can precede hooks or an automatic continuation; completion needs its event.
        }
    }
}
