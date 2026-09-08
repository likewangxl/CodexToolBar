import Foundation

public struct AccountSnapshot {
    public var tokens: AccountTokenSummary?
    public var quota: UsageSnapshot?
    public var tokenError: AccountUsageError?
    public var quotaError: AccountUsageError?
    public init() {}
    public static func quota(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int; let resetsAt: Double }
        struct Limit: Decodable { let limitId: String?; let primary: Window?; let secondary: Window? }
        struct Payload: Decodable { let rateLimits: Limit?; let rateLimitsByLimitId: [String: Limit]? }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        // A present map is authoritative. Never use another product's bucket.
        let limit = value.rateLimitsByLimitId != nil ? value.rateLimitsByLimitId?["codex"] : value.rateLimits
        guard let limit, limit.limitId == nil || limit.limitId == "codex" else { throw AccountUsageError.unavailable }
        func window(_ input: Window?) throws -> QuotaWindow? {
            guard let input else { return nil }
            guard input.usedPercent.isFinite, (0...100).contains(input.usedPercent), input.windowDurationMins > 0,
                  input.resetsAt.isFinite, input.resetsAt > 0 else { throw AccountUsageError.invalidResponse }
            return QuotaWindow(usedPercent: input.usedPercent, minutes: input.windowDurationMins, resetsAt: input.resetsAt)
        }
        return try UsageSnapshot(primary: window(limit.primary), secondary: window(limit.secondary), observedAt: now.timeIntervalSince1970)
    }
}
public enum QuotaSyncState: String { case waiting, syncing, current, failed }
