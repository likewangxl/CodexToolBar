import Foundation
import CSQLite
import CryptoKit
import Darwin

public struct TokenSummary: Equatable {
    public let yesterday: Int64
    public let total: Int64
    public let indexing: Bool
    public init(yesterday: Int64, total: Int64, indexing: Bool = false) {
        self.yesterday = yesterday; self.total = total; self.indexing = indexing
    }
    public static func compact(_ value: Int64) -> String {
        if value >= 10_000_000 { return String(format: "%.2f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return String(value)
    }
}

/// Private, rebuildable numeric index. Never writes Codex files or stores message text.
/// A shared event hash prevents copied/forked history from counting twice.
public final class TokenLedger {
    private var db: OpaquePointer?
    private let marker = Data("\"token_count\"".utf8)
    private let dates = ISO8601DateFormatter()
    private let plainDates = ISO8601DateFormatter()
    public private(set) var bytesRead: Int64 = 0
    private struct Cursor {
        var identity: String = ""
        var offset: Int64 = 0
        var total: Int64 = 0
        var discard = false
        var size: Int64 = -1
        var modified: Double = 0
    }
    public init(cache: URL) throws {
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(cache.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 1500)
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA cache_size=-1024")
        try execute("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, identity TEXT, offset INTEGER, total INTEGER, discard INTEGER, size INTEGER, modified REAL)")
        try execute("CREATE TABLE IF NOT EXISTS events(hash TEXT PRIMARY KEY, stamp REAL, tokens INTEGER)")
        try execute("CREATE INDEX IF NOT EXISTS event_dates ON events(stamp)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
    }
    deinit { sqlite3_close(db) }
    private func failure() -> Error { NSError(domain: "TokenLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地 token 索引暂不可用"]) }
    private func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (index, value) in values.enumerated() {
            let column = Int32(index + 1)
            if let string = value as? String { sqlite3_bind_text(result, column, string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            else if let number = value as? Int64 { sqlite3_bind_int64(result, column, number) }
            else if let number = value as? Double { sqlite3_bind_double(result, column, number) }
        }
        return result
    }
    private func execute(_ sql: String, _ values: [Any] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        let result = sqlite3_step(s)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func cursor(_ path: String) throws -> Cursor {
        let s = try statement("SELECT identity,offset,total,discard,size,modified FROM files WHERE path=?", [path])
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return Cursor() }
        return Cursor(identity: String(cString: sqlite3_column_text(s, 0)), offset: sqlite3_column_int64(s, 1), total: sqlite3_column_int64(s, 2), discard: sqlite3_column_int64(s, 3) != 0, size: sqlite3_column_int64(s, 4), modified: sqlite3_column_double(s, 5))
    }
    /// Returns true when caught up. Work per call is bounded, including very large output lines.
    @discardableResult public func ingest(_ url: URL, budget: Int = 1_048_576) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        var c = try cursor(url.path)
        if c.identity != identity || size < c.offset || (c.size == size && c.modified != modified) { c = Cursor(identity: identity) }
        if c.size == size && c.modified == modified { return true }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(c.offset))
        let bytes = try handle.read(upToCount: max(1024, budget)) ?? Data()
        bytesRead += Int64(bytes.count)
        try execute("BEGIN IMMEDIATE")
        do {
            var start = bytes.startIndex
            // SIMD libc search avoids walking every byte through Data's collection iterator.
            let newlines: [Int] = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return [] }
                var result: [Int] = [], position = 0
                while position < raw.count, let match = memchr(base.advanced(by: position), 10, raw.count - position) {
                    let index = base.distance(to: UnsafeRawPointer(match))
                    result.append(index); position = index + 1
                }
                return result
            }
            for newline in newlines {
                if c.discard { c.discard = false }
                else {
                    let line = bytes[start..<newline]
                    if line.count <= 262_144, line.range(of: marker) != nil {
                        try accept(Data(line), previous: &c.total)
                    }
                }
                start = bytes.index(after: newline)
            }
            let remainder = bytes.count - start
            c.offset += Int64(start)
            // Do not retain huge tool/image output between slices. Retry small partial JSON on append.
            if remainder > 262_144 || c.discard { c.offset += Int64(remainder); c.discard = true }
            let atEnd = Int64(bytes.count) < Int64(max(1024, budget)) || c.offset >= size
            c.size = atEnd ? size : -1; c.modified = modified
            try execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?,?)", [url.path, identity, c.offset, c.total, Int64(c.discard ? 1 : 0), c.size, c.modified])
            try execute("COMMIT")
            return atEnd
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func accept(_ line: Data, previous: inout Int64) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let cumulative = info["total_token_usage"] as? [String: Any],
              let total = integer(cumulative["total_tokens"]),
              let stamp = object["timestamp"] as? String,
              let date = dates.date(from: stamp) ?? plainDates.date(from: stamp) else { return }
        let last = integer((info["last_token_usage"] as? [String: Any])?["total_tokens"]) ?? 0
        let delta = total >= previous ? total - previous : last
        previous = total
        guard delta > 0 else { return }
        // Ignore quota-only changes when identifying an inherited usage event.
        let identity = Data("\(stamp)|\(total)|\(last)".utf8)
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        try execute("INSERT OR IGNORE INTO events VALUES(?,?,?)", [hash, date.timeIntervalSince1970, delta])
    }
    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0, d < Double(Int64.max), d.rounded(.towardZero) == d else { return nil }
        return number.int64Value
    }
    public func summary(now: Date = Date(), calendar: Calendar = .current, indexing: Bool = false) throws -> TokenSummary {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let s = try statement("SELECT COALESCE(SUM(tokens),0), COALESCE(SUM(CASE WHEN stamp>=? AND stamp<? THEN tokens ELSE 0 END),0) FROM events", [yesterday.timeIntervalSince1970, today.timeIntervalSince1970])
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }
        return TokenSummary(yesterday: sqlite3_column_int64(s, 1), total: sqlite3_column_int64(s, 0), indexing: indexing)
    }
}
