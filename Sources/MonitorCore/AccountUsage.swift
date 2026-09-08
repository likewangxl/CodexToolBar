import Foundation
import Darwin

/// Numeric data from the same account endpoint as Codex's profile, never local log totals.
public struct AccountTokenSummary: Equatable {
    public let yesterday: Int64?
    public let total: Int64?
    public let observedAt: Date
    public let yesterdayDate: String
    public init(yesterday: Int64?, total: Int64?, observedAt: Date = Date(), calendar: Calendar = .current) {
        self.yesterday = yesterday; self.total = total; self.observedAt = observedAt
        yesterdayDate = Self.dayBefore(observedAt, calendar: calendar)
    }
    public static func dayBefore(_ now: Date, calendar: Calendar) -> String {
        let day = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
    public func yesterdayValue(now: Date = Date(), calendar: Calendar = .current) -> Int64? {
        calendar.isDate(observedAt, inSameDayAs: now) ? yesterday : nil
    }
    public static func decode(_ data: Data, now: Date = Date(), calendar: Calendar = .current) throws -> Self {
        struct Payload: Decodable {
            struct Summary: Decodable { let lifetimeTokens: Int64? }
            struct Bucket: Decodable { let startDate: String; let tokens: Int64? }
            let summary: Summary
            let dailyUsageBuckets: [Bucket]?
        }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        let day = dayBefore(now, calendar: calendar)
        let matches = value.dailyUsageBuckets?.filter { $0.startDate == day } ?? []
        let yesterday = matches.count == 1 ? matches[0].tokens : nil
        guard value.summary.lifetimeTokens.map({ $0 >= 0 }) ?? true,
              yesterday.map({ $0 >= 0 }) ?? true else { throw AccountUsageError.invalidResponse }
        return Self(yesterday: yesterday, total: value.summary.lifetimeTokens, observedAt: now, calendar: calendar)
    }
}

public enum AccountUsageError: Error { case unavailable, cancelled, timeout, invalidResponse, serverError, unsupported }

/// A bounded, short-lived read-only app-server. No credential parsing or persistent subprocess.
public final class AccountUsageReader {
    private let lock = NSLock()
    private var cancelled = false
    private var runningProcess: Process?
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true
        if let process = runningProcess, process.isRunning { process.terminate() }
        lock.unlock()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func read(home: URL, executable: URL? = nil, timeout: TimeInterval = 20) throws -> AccountTokenSummary {
        let values = try fetch(home: home, executable: executable, timeout: timeout, methods: ["account/usage/read"])
        guard let value = values["account/usage/read"] else { throw AccountUsageError.invalidResponse }
        return try AccountTokenSummary.decode(value.get())
    }
    public func readAccount(home: URL, executable: URL? = nil, timeout: TimeInterval = 20) throws -> AccountSnapshot {
        let values = try fetch(home: home, executable: executable, timeout: timeout, methods: ["account/rateLimits/read", "account/usage/read"])
        var result = AccountSnapshot()
        do { result.quota = try AccountSnapshot.quota(values["account/rateLimits/read"]!.get()) }
        catch { result.quotaError = (error as? AccountUsageError) ?? .invalidResponse }
        do { result.tokens = try AccountTokenSummary.decode(values["account/usage/read"]!.get()) }
        catch { result.tokenError = (error as? AccountUsageError) ?? .invalidResponse }
        return result
    }
    private func fetch(home: URL, executable: URL?, timeout: TimeInterval, methods: [String]) throws -> [String: Result<Data, AccountUsageError>] {
        let candidates = ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path]
        guard let cli = executable ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else { throw AccountUsageError.unavailable }
        if isCancelled { throw AccountUsageError.cancelled }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = cli; process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw AccountUsageError.cancelled }
        do { try process.run(); runningProcess = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            lock.lock(); runningProcess = nil; lock.unlock()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_touch_bar", "version": "0.8.0"], "capabilities": ["experimentalApi": true]]])
        var buffer = Data(), bytes = 0, requested = false
        var results: [String: Result<Data, AccountUsageError>] = [:]
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if isCancelled { throw AccountUsageError.cancelled }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw AccountUsageError.unavailable }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else {
                if !results.isEmpty {
                    for method in methods where results[method] == nil { results[method] = .failure(.unavailable) }
                    return results
                }
                throw AccountUsageError.unavailable
            }
            bytes += count; guard bytes <= 2 * 1024 * 1024 else { throw AccountUsageError.invalidResponse }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AccountUsageError.invalidResponse }
                guard let id = message["id"] as? Int else { continue }
                if !requested {
                    guard id == 1 else { continue }
                    if message["error"] != nil { throw AccountUsageError.serverError }
                    guard message["result"] is [String: Any] else { throw AccountUsageError.invalidResponse }
                    try send(["method": "initialized", "params": [:]])
                    for (index, method) in methods.enumerated() { try send(["id": index + 2, "method": method]) }
                    requested = true
                } else if id >= 2 && id < methods.count + 2 {
                    let method = methods[id - 2]
                    if let error = message["error"] as? [String: Any] {
                        results[method] = .failure(error["code"] as? Int == -32601 ? .unsupported : .serverError)
                    } else if let result = message["result"] as? [String: Any] {
                        results[method] = .success(try JSONSerialization.data(withJSONObject: result))
                    } else { results[method] = .failure(.invalidResponse) }
                    if results.count == methods.count { return results }
                }
            }
        }
        if !results.isEmpty {
            for method in methods where results[method] == nil { results[method] = .failure(.timeout) }
            return results
        }
        throw AccountUsageError.timeout
    }
}
