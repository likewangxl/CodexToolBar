import Foundation

/// User intent is independent of whether AppKit is currently showing the bar.
public struct PresentationPolicy {
    public var wanted = false
    public var pinned = true
    public var suspended = false
    private var lastAttempt: TimeInterval = -.infinity
    private var failures = 0
    public init() {}
    public mutating func shouldRestore(visible: Bool, activation: Bool = false, now: TimeInterval) -> Bool {
        guard wanted, pinned, !suspended else { return false }
        if visible && !activation { failures = 0; return false }
        let delay = min(15, pow(2, Double(min(failures, 4))))
        guard now - lastAttempt >= delay else { return false }
        lastAttempt = now
        if !visible { failures += 1 } else { failures = 0 }
        return true
    }
    public mutating func shown() { failures = 0 }
}
