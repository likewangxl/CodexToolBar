import Foundation

public enum WorkStatus: String, Codable {
    case working, tool, replying, waiting, completed, interrupted, failed, idle, unknown
    public var label: String {
        switch self {
        case .working: return "工作中"
        case .tool: return "执行工具"
        case .replying: return "正在回复"
        case .waiting: return "等待你操作"
        case .completed: return "已完成"
        case .interrupted: return "已中断"
        case .failed: return "出错了"
        case .idle: return "空闲"
        case .unknown: return "状态待确认"
        }
    }
    public var active: Bool { [.working, .tool, .replying, .waiting].contains(self) }
    public var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .tool: return "hammer.fill"
        case .replying: return "text.bubble.fill"
        case .waiting: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .interrupted: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle, .unknown: return "circle"
        }
    }
}

public struct TaskState: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var rolloutPath: String
    public var updatedAt: TimeInterval
    public var status: WorkStatus = .unknown
    public var reply = ""
    public var activity = ""
    public var isLive = false
    public var connectionIssue: String?
    public var lastEventAt: TimeInterval = 0
    public var activities: [Activity] = []
    public var liveSteps: [ExecutionStep] = []
    public var context: ContextUsage?
    public init(id: String, title: String, rolloutPath: String = "", updatedAt: TimeInterval = 0) {
        self.id = id; self.title = title; self.rolloutPath = rolloutPath; self.updatedAt = updatedAt
    }
    public var summary: String { Self.singleLine(reply.isEmpty ? activity : reply) }
    public static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LiveStateParser {
    public static func turns(_ state: [String: Any]) -> [[String: Any]] {
        if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any],
           let entities = history["entitiesByKey"] as? [String: Any] {
            let islands = history["islands"] as? [[String: Any]] ?? []
            let keys = islands.flatMap { $0["entries"] as? [[String: Any]] ?? [] }.compactMap { $0["key"] as? String }
            let ordered = keys.compactMap { entities[$0] as? [String: Any] }
            if !ordered.isEmpty { return ordered }
            return entities.values.compactMap { $0 as? [String: Any] }.sorted {
                ($0["turnStartedAtMs"] as? Double ?? 0) < ($1["turnStartedAtMs"] as? Double ?? 0)
            }
        }
        return state["turns"] as? [[String: Any]] ?? []
    }

    public static func apply(_ state: [String: Any], to original: TaskState, now: TimeInterval = Date().timeIntervalSince1970) -> TaskState {
        var task = original
        task.isLive = true; task.lastEventAt = now
        if let title = state["title"] as? String, !title.isEmpty { task.title = title }
        if let timestamp = state["recencyAt"] as? Double { task.updatedAt = timestamp / 1000 }
        if let usage = state["latestTokenUsageInfo"] as? [String: Any] { task.context = ContextUsage.live(usage) }
        let allTurns = turns(state)
        let lastTurn = allTurns.last ?? [:]
        let items = lastTurn["items"] as? [[String: Any]] ?? []
        task.activities = ActivityParser.parse(Array(items.suffix(128)))
        task.liveSteps = Array(items.suffix(128)).enumerated().compactMap { ExecutionParser.step($0.element, fallbackID: "live-\($0.offset)") }
        let runtime = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        let flags = runtime["activeFlags"] as? [String] ?? []
        let runtimeType = runtime["type"] as? String
        let turnStatus = lastTurn["status"] as? String
        let requests = state["requests"] as? [Any] ?? []
        if runtimeType == "systemError" || turnStatus == "failed" {
            task.status = .failed
        } else if flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") || !requests.isEmpty {
            task.status = .waiting
        } else if runtimeType == "active" || (runtimeType == nil && turnStatus == "inProgress") {
            task.status = .working
            if let item = items.last {
                let type = item["type"] as? String ?? ""
                if type == "agentMessage" { task.status = .replying }
                else if ["commandExecution", "mcpToolCall", "dynamicToolCall", "webSearch", "fileChange"].contains(type),
                        item["status"] as? String == "inProgress" { task.status = .tool }
            }
        } else if turnStatus == "interrupted" { task.status = .interrupted
        } else if turnStatus == "completed" { task.status = .completed
        } else if runtimeType == "idle" { task.status = .idle
        } else { task.status = .unknown }

        // Only user-visible assistant messages. Never display reasoning or tool output.
        let message = items.reversed().first { $0["type"] as? String == "agentMessage" }
        if let text = message?["text"] as? String, !text.isEmpty { task.reply = text }
        else if task.status.active { task.reply = "" }
        task.activity = task.status == .waiting ? "请在 Codex 中处理确认或问题" : task.status.label
        return task
    }
}

public struct AgentBadge: Codable, Equatable {
    public var id: String
    public var name: String
    public var style: Int
    public init(id: String, path: String) {
        self.id = id
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        let words = leaf.replacingOccurrences(of: "_", with: " ")
        name = words.isEmpty ? "子代理" : words.prefix(1).uppercased() + words.dropFirst()
        // Recognizable colors for the supplied reference; stable palette for all others.
        let references = ["luna_binding": 0, "luna_backend": 1, "luna_ui": 2, "luna_map": 3, "luna_reference_index": 4, "luna_integration": 5]
        let hash = leaf.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        style = references[leaf] ?? Int(hash % 6)
    }
}

public struct Activity: Codable, Equatable {
    public var id: String
    public var label: String
    public var symbol: String
    public var agents: [AgentBadge]
    public init(id: String, label: String, symbol: String, agents: [AgentBadge] = []) {
        self.id = id; self.label = label; self.symbol = symbol; self.agents = agents
    }
}

public enum ActivityParser {
    public static func single(_ item: [String: Any]) -> Activity? {
        let type = ExecutionParser.kind(item)
        let id = item["id"] as? String ?? "activity"
        let running = item["status"] as? String == "inProgress" || item["status"] as? String == "in_progress"
        switch type {
        case "subAgentActivity":
            let path = item["agentPath"] as? String ?? item["agent_path"] as? String ?? "子代理"
            let threadID = item["agentThreadId"] as? String ?? item["agent_thread_id"] as? String ?? path
            let badge = AgentBadge(id: threadID, path: path)
            let kind = item["kind"] as? String ?? ""
            let verb = kind == "started" ? "已启动" : kind == "completed" ? "已完成" : "有了更新"
            return Activity(id: id, label: badge.name + verb, symbol: "person.2", agents: [badge])
        case "collabAgentToolCall":
            let badges = (item["receiverThreads"] as? [[String: Any]] ?? []).map { receiver -> AgentBadge in
                let thread = receiver["thread"] as? [String: Any] ?? [:]
                return AgentBadge(id: receiver["threadId"] as? String ?? "agent", path: thread["agentPath"] as? String ?? thread["agentNickname"] as? String ?? "子代理")
            }
            return Activity(id: id, label: badges.isEmpty ? "子代理协作更新" : badges.map(\.name).joined(separator: "、") + "有了更新", symbol: "person.2", agents: badges)
        case "commandExecution":
            let actions = item["commandActions"] as? [[String: Any]] ?? item["command_actions"] as? [[String: Any]] ?? item["parsed_cmd"] as? [[String: Any]] ?? []
            let kinds = actions.compactMap { $0["type"] as? String }
            var labels: [String] = []
            if kinds.contains("read") { labels.append(running ? "正在读取文件" : "已读取文件") }
            if kinds.contains("search") { labels.append(running ? "正在搜索文件" : "已搜索文件") }
            if kinds.contains("listFiles") || kinds.contains("list_files") { labels.append(running ? "正在列出文件" : "已列出文件") }
            if labels.isEmpty || kinds.contains("unknown") { labels.append(running ? "正在运行命令" : "运行了命令") }
            let symbol = kinds.contains("read") ? "book" : kinds.contains("search") ? "magnifyingglass" : kinds.contains("listFiles") || kinds.contains("list_files") ? "folder" : "terminal"
            let failed = item["status"] as? String == "failed" || (item["exitCode"] as? Int ?? item["exit_code"] as? Int ?? 0) != 0
            return Activity(id: id, label: labels.joined(separator: " · ") + (failed ? " · 未成功" : ""), symbol: symbol)
        case "fileChange": return Activity(id: id, label: running ? "正在编辑文件" : "编辑了文件", symbol: "pencil")
        case "webSearch": return Activity(id: id, label: running ? "正在搜索网页" : "搜索了网页", symbol: "globe")
        case "imageView": return Activity(id: id, label: "已查看 1 张图像", symbol: "photo.on.rectangle")
        case "contextCompaction": return Activity(id: id, label: "上下文已自动压缩", symbol: "text.badge.minus")
        case "mcpToolCall", "dynamicToolCall":
            let tool = item["tool"] as? String ?? item["name"] as? String ?? "工具"
            return Activity(id: id, label: (running ? "正在调用 " : "已调用 ") + tool, symbol: "wrench.and.screwdriver")
        case "imageGeneration": return Activity(id: id, label: running ? "正在生成图像" : "已生成图像", symbol: "photo.badge.plus")
        case "extension":
            let image = (item["kind"] as? String ?? "").contains("image")
            return Activity(id: id, label: image ? (running ? "正在生成图像" : "已生成图像") : "扩展工具更新", symbol: image ? "photo.badge.plus" : "puzzlepiece.extension")
        default: return nil
        }
    }
    public static func parse(_ items: [[String: Any]]) -> [Activity] {
        var result: [Activity] = []
        var previousKind = ""
        var imageCount = 0
        for item in items {
            let kind = ExecutionParser.kind(item)
            guard var activity = single(item) else { previousKind = kind; imageCount = 0; continue }
            if kind == "imageView" {
                imageCount = previousKind == kind ? imageCount + 1 : 1
                activity.label = "已查看 \(imageCount) 张图像"
                if previousKind == kind && !result.isEmpty { result.removeLast() }
            } else { imageCount = 0 }
            if let last = result.last, previousKind == kind, last.label == activity.label && last.agents == activity.agents {
                result[result.count - 1] = activity
            } else if let last = result.last, !last.agents.isEmpty, !activity.agents.isEmpty,
                      last.label.hasSuffix("有了更新"), activity.label.hasSuffix("有了更新") {
                var agents = last.agents
                for agent in activity.agents where !agents.contains(where: { $0.id == agent.id }) { agents.append(agent) }
                result[result.count - 1] = Activity(id: activity.id, label: agents.map(\.name).joined(separator: "、") + "有了更新", symbol: "person.2", agents: agents)
            } else { result.append(activity) }
            previousKind = kind
        }
        return Array(result.suffix(8))
    }
}

public enum JSONPatch {
    public enum Failure: Error { case invalidPath, invalidOperation, missingValue }
    public static func apply(_ patches: [[String: Any]], to document: Any) throws -> Any {
        var result = document
        for patch in patches {
            let path: [String]
            if let parts = patch["path"] as? [Any] { path = parts.map { String(describing: $0) } }
            else if let pointer = patch["path"] as? String {
                if pointer.isEmpty { path = [] }
                else {
                    guard pointer.hasPrefix("/") else { throw Failure.invalidPath }
                    path = pointer.dropFirst().components(separatedBy: "/").map {
                        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                    }
                }
            } else { throw Failure.invalidPath }
            guard let op = patch["op"] as? String, ["add", "remove", "replace"].contains(op) else { throw Failure.invalidOperation }
            if op != "remove" && patch["value"] == nil { throw Failure.missingValue }
            result = try mutate(result, path: path[...], op: op, value: patch["value"])
        }
        return result
    }
    private static func mutate(_ node: Any, path: ArraySlice<String>, op: String, value: Any?) throws -> Any {
        guard let key = path.first else {
            guard op != "remove", let value else { throw Failure.invalidOperation }
            return value
        }
        let rest = path.dropFirst()
        if var dictionary = node as? [String: Any] {
            if rest.isEmpty {
                if op != "add" && dictionary[key] == nil { throw Failure.invalidPath }
                if op == "remove" { dictionary.removeValue(forKey: key) } else { dictionary[key] = value }
            } else {
                guard let child = dictionary[key] else { throw Failure.invalidPath }
                dictionary[key] = try mutate(child, path: rest, op: op, value: value)
            }
            return dictionary
        }
        if var array = node as? [Any] {
            let index = key == "-" ? array.count : Int(key) ?? -1
            guard index >= 0 else { throw Failure.invalidPath }
            if rest.isEmpty && op == "add" {
                guard index <= array.count else { throw Failure.invalidPath }
                array.insert(value!, at: index)
            } else {
                guard index < array.count else { throw Failure.invalidPath }
                if !rest.isEmpty { array[index] = try mutate(array[index], path: rest, op: op, value: value) }
                else if op == "remove" { array.remove(at: index) }
                else { array[index] = value! }
            }
            return array
        }
        throw Failure.invalidPath
    }
}
