import Foundation

/// One shared interpretation for the Touch Bar and its detail panel. Account
/// windows can change order; a weekly window must not be confused with a 5h one.
public struct QuotaDisplay: Equatable {
    public let headline: String
    public let resetLine: String
    public let fraction: Double
    public let expired: Bool
    public init(usage: UsageSnapshot?, now: TimeInterval = Date().timeIntervalSince1970, timeZone: TimeZone = .autoupdatingCurrent) {
        guard let window = Self.window(in: usage) else {
            headline = "周额度 · —"; resetLine = "等待用量数据"; fraction = 0; expired = false
            return
        }
        expired = now >= window.resetsAt
        headline = "\(window.displayName) · \(expired ? "上次" : "已用") \(Int(window.usedPercent.rounded()))%"
        resetLine = Self.resetTime(window.resetsAt, timeZone: timeZone) + (expired ? " 待同步" : " 重置")
        fraction = window.usedPercent / 100
    }
    public static func window(in usage: UsageSnapshot?) -> QuotaWindow? {
        guard let usage else { return nil }
        return usage.windows.first(where: { $0.minutes == 10080 }) ?? usage.windows.first
    }
    // Called only for new quota observations or the once-a-minute expiration check.
    public static func resetTime(_ timestamp: TimeInterval, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
public extension QuotaWindow {
    var displayName: String { minutes == 10080 ? "周额度" : label + "额度" }
}

public struct QuotaRow: Equatable {
    public let title: String
    public let remaining: String
    public let reset: String
    public let fraction: Double
    public let expired: Bool
    public let available: Bool
    public static func rows(_ usage: UsageSnapshot?, now: TimeInterval = Date().timeIntervalSince1970, state: QuotaSyncState = .current, timeZone: TimeZone = .autoupdatingCurrent) -> [QuotaRow] {
        let aged = usage.map { now - $0.observedAt >= 600 } ?? false
        return [(300, "5小时"), (10080, "周额度")].map { minutes, title in
            let failure = state == .failed
            let pending = state == .syncing || state == .waiting
            let status = failure ? "同步失败" : pending ? "正在同步" : aged ? "数据过期" : ""
            guard let window = usage?.windows.first(where: { $0.minutes == minutes }) else {
                return QuotaRow(title: title, remaining: "剩余 —", reset: !status.isEmpty ? status : usage == nil ? "等待同步" : "账户无此窗口", fraction: 0, expired: false, available: false)
            }
            let expired = now >= window.resetsAt
            let stale = failure || pending || aged || expired
            let remaining = max(0, 100 - window.usedPercent)
            return QuotaRow(title: title, remaining: "\(stale ? "上次" : "剩余")\(Int(remaining.rounded()))%", reset: !status.isEmpty ? status : QuotaDisplay.resetTime(window.resetsAt, timeZone: timeZone) + (expired ? " 待同步" : " 重置"), fraction: remaining / 100, expired: stale, available: true)
        }
    }
}
