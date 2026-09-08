import Foundation
import Darwin

public struct ContextUsage: Codable, Equatable {
    public let used: Int
    public let window: Int
    public var percent: Double { Double(used) / Double(window) * 100 }
    public init?(used: Int?, window: Int?) {
        guard let used, let window, used >= 0, window > 0 else { return nil }
        self.used = min(used, window); self.window = window
    }
    static func live(_ value: [String: Any]) -> ContextUsage? {
        ContextUsage(used: (value["last"] as? [String: Any])?["totalTokens"] as? Int, window: value["modelContextWindow"] as? Int)
    }
}
public struct QuotaWindow: Codable, Equatable {
    public let usedPercent: Double
    public let minutes: Int
    public let resetsAt: TimeInterval
    public init(usedPercent: Double, minutes: Int, resetsAt: TimeInterval) {
        self.usedPercent = min(100, max(0, usedPercent)); self.minutes = minutes; self.resetsAt = resetsAt
    }
    public var label: String { minutes % 1440 == 0 ? "\(minutes / 1440)日" : minutes % 60 == 0 ? "\(minutes / 60)时" : "\(minutes)分" }
    static func parse(_ value: [String: Any]?) -> QuotaWindow? {
        guard let value, let used = value["used_percent"] as? Double, used.isFinite,
              let minutes = value["window_minutes"] as? Int, minutes > 0,
              let reset = value["resets_at"] as? Double else { return nil }
        return QuotaWindow(usedPercent: used, minutes: minutes, resetsAt: reset)
    }
}
public struct UsageSnapshot: Codable, Equatable {
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    public let observedAt: TimeInterval
    public init(primary: QuotaWindow?, secondary: QuotaWindow? = nil, observedAt: TimeInterval) {
        self.primary = primary; self.secondary = secondary; self.observedAt = observedAt
    }
    public func isNewer(than old: UsageSnapshot?) -> Bool { observedAt > (old?.observedAt ?? 0) }
    public var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
}

/// Event-driven, bounded tail reader. Only token_count records are JSON decoded.
/// An incomplete final line is retained until the next append; no whole-file reads.
final class TelemetryTail {
    let url: URL
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var discardLine = false
    private let marker = Data("\"token_count\"".utf8)
    private static let dateParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    var onRecord: ((ContextUsage?, UsageSnapshot?) -> Void)?
    private(set) var bytesRead = 0
    init(url: URL, queue: DispatchQueue) { self.url = url; self.queue = queue }
    deinit { source?.cancel(); pending?.cancel() }
    func start() {
        guard source == nil else { return }
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        s.setEventHandler { [weak self] in
            guard let self, self.pending == nil else { return }
            let replaced = self.source?.data.intersection([.rename, .delete]).isEmpty == false
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }; self.pending = nil
                if replaced {
                    self.source?.cancel(); self.source = nil; self.offset = 0; self.start()
                } else { self.read() }
            }
            self.pending = work; self.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        s.setCancelHandler { close(fd) }; source = s; s.resume(); read()
    }
    func read() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset { offset = 0; remainder.removeAll(); discardLine = false }
        // If events outrun us, skip to a bounded tail, never accumulate unbounded tool output.
        if offset == 0 || size - offset > 524_288 {
            offset = size > 524_288 ? size - 524_288 : 0
            remainder.removeAll(); discardLine = offset > 0
        }
        try? handle.seek(toOffset: offset)
        guard let bytes = try? handle.read(upToCount: 524_288), !bytes.isEmpty else { return }
        offset += UInt64(bytes.count); bytesRead += bytes.count; remainder.append(bytes)
        while let end = remainder.firstIndex(of: 10) {
            let line = Data(remainder[..<end]); remainder.removeSubrange(...end)
            if discardLine { discardLine = false; continue }
            guard line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any], p["type"] as? String == "token_count" else { continue }
            let info = p["info"] as? [String: Any] ?? [:]
            let context = ContextUsage(used: (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
                                       window: info["model_context_window"] as? Int)
            var usage: UsageSnapshot?
            if let limits = p["rate_limits"] as? [String: Any],
               limits["limit_id"] == nil || limits["limit_id"] as? String == "codex",
               let stamp = obj["timestamp"] as? String,
               let date = Self.dateParser.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) {
                let primary = QuotaWindow.parse(limits["primary"] as? [String: Any])
                let secondary = QuotaWindow.parse(limits["secondary"] as? [String: Any])
                if primary != nil || secondary != nil { usage = UsageSnapshot(primary: primary, secondary: secondary, observedAt: date.timeIntervalSince1970) }
            }
            onRecord?(context, usage)
        }
        if remainder.count > 262_144 { remainder.removeAll(); discardLine = true }
    }
}
