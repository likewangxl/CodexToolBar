import Foundation

/// A small, user-visible row. Large output stays in the source log until expanded.
public struct ExecutionStep: Identifiable, Codable, Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var symbol: String
    public var preview: String
    public var status: String
    public var agents: [AgentBadge]
    public var offset: UInt64?
    public var length: Int
    public var timestamp: String
    public var imagePath: String?
    public var isMessage: Bool { kind == "agentMessage" || kind == "userMessage" }
    public init(id: String, kind: String, title: String, symbol: String, preview: String = "", status: String = "", agents: [AgentBadge] = [], offset: UInt64? = nil, length: Int = 0, timestamp: String = "", imagePath: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.symbol = symbol; self.preview = preview
        self.status = status; self.agents = agents; self.offset = offset; self.length = length; self.timestamp = timestamp; self.imagePath = imagePath
    }
}

public enum ExecutionParser {
    public static func kind(_ item: [String: Any]) -> String {
        let raw = item["type"] as? String ?? "unknown"
        let name = raw.prefix(1).lowercased() + raw.dropFirst()
        if name == "extension" {
            let kind = item["kind"] as? String ?? ""
            if kind.hasPrefix("web.") { return "webSearch" }
            if kind.hasPrefix("image_gen.") { return "imageGeneration" }
        }
        if name == "steeringUserMessage" { return "userMessage" }
        return name
    }
    public static func text(_ item: [String: Any]) -> String {
        if let text = item["text"] as? String { return text }
        return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    public static func step(_ item: [String: Any], fallbackID: String = "step") -> ExecutionStep? {
        let type = kind(item)
        // Only visible execution items. Raw/encrypted reasoning is not an execution step.
        guard !["reasoning", "turnContext", "tokenCount"].contains(type) else { return nil }
        let id = item["id"] as? String ?? fallbackID
        let status = item["status"] as? String ?? ""
        if type == "agentMessage" || type == "userMessage" {
            let body = text(item)
            let title = type == "userMessage" ? "你的消息" : (item["phase"] as? String == "final" ? "最终回复" : "进展说明")
            return ExecutionStep(id: id, kind: type, title: title, symbol: type == "userMessage" ? "person.crop.circle" : "text.bubble", preview: String(TaskState.singleLine(body).prefix(180)), status: status)
        }
        if let activity = ActivityParser.single(item) {
            var preview = ""
            if type == "commandExecution" { preview = commandText(item) }
            else if type == "fileChange" {
                preview = (item["changes"] as? [String: Any])?.keys.sorted().joined(separator: "、") ?? ""
            } else if type == "imageView" { preview = readablePath(item["path"] as? String ?? "") }
            else if type == "webSearch" { preview = item["query"] as? String ?? "" }
            return ExecutionStep(id: id, kind: type, title: activity.label, symbol: activity.symbol, preview: String(TaskState.singleLine(preview).prefix(180)), status: status, agents: activity.agents, imagePath: type == "imageView" ? item["path"] as? String : type == "imageGeneration" ? item["savedPath"] as? String : nil)
        }
        return ExecutionStep(id: id, kind: type, title: "执行步骤 · " + type, symbol: "wrench.and.screwdriver", status: status)
    }
    public static func details(_ item: [String: Any]) -> String {
        let type = kind(item)
        if type == "agentMessage" || type == "userMessage" {
            let body = text(item)
            let images = (item["content"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String ?? "").lowercased().contains("image") }.count
            return body + (images > 0 ? "\n\n附带 \(images) 张图像；原附件可在 Codex 中查看。" : "")
        }
        var parts: [String] = []
        if let status = item["status"] as? String { parts.append("状态：\(status)") }
        if let cwd = item["cwd"] as? String { parts.append("工作目录：\(readablePath(cwd))") }
        let command = commandText(item)
        if !command.isEmpty { parts.append("命令\n\(command)") }
        if let code = item["exitCode"] as? Int ?? item["exit_code"] as? Int { parts.append("退出码：\(code)") }
        if let path = item["path"] as? String { parts.append("图像路径\n\(readablePath(path))") }
        if type == "contextCompaction" { parts.append("上下文已自动压缩。压缩后的 ctx 以最新一次请求为准。") }
        if let changes = item["changes"] as? [String: Any] {
            for path in changes.keys.sorted() {
                let change = changes[path] as? [String: Any] ?? [:]
                parts.append("文件：\(path)\n" + (change["unified_diff"] as? String ?? change["diff"] as? String ?? pretty(change)))
            }
        } else if let changes = item["changes"] as? [[String: Any]] {
            for change in changes { parts.append("文件：\(change["path"] as? String ?? "")\n" + (change["diff"] as? String ?? pretty(change))) }
        }
        let output = item["aggregatedOutput"] as? String ?? item["aggregated_output"] as? String ?? item["formatted_output"] as? String
        if let output, !output.isEmpty { parts.append("输出\n\(output)") }
        else {
            for key in ["stdout", "stderr"] { if let value = item[key] as? String, !value.isEmpty { parts.append("\(key)\n\(value)") } }
        }
        for key in ["tool", "server", "kind", "arguments", "result", "results", "error", "failure", "savedPath", "query", "action", "agentPath", "receiverThreads"] {
            if let value = item[key], !(value is NSNull) { parts.append("\(key)\n\(pretty(value))") }
        }
        if parts.isEmpty { return pretty(item) }
        return parts.joined(separator: "\n\n")
    }
    private static func readablePath(_ value: String) -> String {
        if let url = URL(string: value), url.isFileURL { return url.path }
        return value
    }
    private static func commandText(_ item: [String: Any]) -> String {
        if let value = item["command"] as? String { return value }
        if let parts = item["command"] as? [String] {
            if parts.count == 3, ["-c", "-lc", "-lic"].contains(parts[1]) { return parts[2] }
            return parts.map { $0.contains(" ") ? "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" : $0 }.joined(separator: " ")
        }
        let actions = item["commandActions"] as? [[String: Any]] ?? item["parsed_cmd"] as? [[String: Any]] ?? []
        return actions.compactMap { $0["cmd"] as? String }.joined(separator: " · ")
    }
    private static func pretty(_ value: Any) -> String {
        // Never expand base64 images or opaque reasoning into a text view.
        func visible(_ value: Any) -> Any {
            if let string = value as? String { return string.hasPrefix("data:image/") ? "[图像附件：请在 Codex 中查看]" : string }
            if let list = value as? [Any] { return list.map(visible) }
            if let dict = value as? [String: Any] {
                return dict.reduce(into: [String: Any]()) { result, pair in
                    if !["encrypted_content", "encryptedContent", "raw_content", "rawContent"].contains(pair.key) { result[pair.key] = visible(pair.value) }
                }
            }
            return value
        }
        let clean = visible(value)
        if let string = clean as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// Queue-confined incremental JSONL index. Row metadata only; each output is read
/// by byte range on expansion. Closing the inspector releases the whole index.
public final class ExecutionHistory {
    private let url: URL
    private static let envelope = try! NSRegularExpression(pattern: #"^\{\s*(?:"timestamp"\s*:\s*"[^"]*"\s*,\s*)?"type"\s*:\s*"([^"]+)""#)
    private var inode: UInt64 = 0
    private var position: UInt64 = 0
    private var lineStart: UInt64 = 0
    private var pending = Data()
    private var skipping = false
    private var rows: [ExecutionStep] = []
    private var positions: [String: Int] = [:]
    public private(set) var bytesRead: UInt64 = 0
    public init(url: URL, home: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let sessions = home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
        guard resolved.path.hasPrefix(sessions), resolved.pathExtension == "jsonl" else { throw HistoryError.invalidPath }
        self.url = resolved
    }
    public func refresh() throws -> [ExecutionStep] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let nextInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if nextInode != inode || size < position {
            inode = nextInode; position = 0; lineStart = 0; pending.removeAll(); skipping = false; rows.removeAll(); positions.removeAll()
        }
        guard size > position else { return rows }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: position)
        // A finite snapshot per pass; continuously appended work cannot block the queue.
        while position < size {
            guard let chunk = try file.read(upToCount: Int(min(262_144, size - position))), !chunk.isEmpty else { break }
            bytesRead += UInt64(chunk.count)
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
                if !skipping {
                    pending.append(contentsOf: chunk[start..<end])
                    if pending.count >= 1024 || end < chunk.endIndex {
                        let header = String(decoding: pending.prefix(1024), as: UTF8.self)
                        // Fast skip only when the leading envelope proves the type.
                        // Unusual key ordering falls back to normal JSON parsing.
                        if let match = Self.envelope.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
                           let range = Range(match.range(at: 1), in: header), header[range] != "event_msg" {
                            skipping = true; pending.removeAll(keepingCapacity: false)
                        }
                    }
                }
                let consumed = end - start + (end < chunk.endIndex ? 1 : 0)
                position += UInt64(consumed)
                if end < chunk.endIndex {
                    if !skipping { autoreleasepool { index(pending, offset: lineStart) } }
                    pending.removeAll(keepingCapacity: pending.count < 262_144); skipping = false; lineStart = position
                }
                start = end < chunk.endIndex ? end + 1 : end
            }
        }
        return rows
    }
    private func index(_ data: Data, offset: UInt64) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
              var step = ExecutionParser.step(item, fallbackID: "log-\(offset)") else { return }
        step.offset = offset; step.length = data.count; step.timestamp = object["timestamp"] as? String ?? ""
        if let i = positions[step.id] { rows[i] = step }
        else { positions[step.id] = rows.count; rows.append(step) }
    }
    public func detail(_ step: ExecutionStep) throws -> String {
        guard let offset = step.offset else { return "执行中，完整输出将在 Codex 写入步骤记录后显示。" }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode else { throw HistoryError.changed }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: step.length), data.count == step.length,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = (object["payload"] as? [String: Any])?["item"] as? [String: Any],
              (item["id"] as? String ?? "log-\(offset)") == step.id else { throw HistoryError.changed }
        return ExecutionParser.details(item)
    }
    public enum HistoryError: LocalizedError {
        case invalidPath, changed
        public var errorDescription: String? {
            switch self { case .invalidPath: return "该任务没有可读取的本机执行记录，请在 Codex 中查看。"
            case .changed: return "记录已变化，请收起后重新展开。" }
        }
    }
}
