import Foundation

public struct ControlSwipe {
    public enum Control: Equatable { case volume, brightness }
    public private(set) var captured = false
    public private(set) var control: Control?
    private var count = 0
    private var since = 0.0
    private var anchor = 0.0
    private var stopped = false

    public init() {}

    // Coordinates are Touch Bar points. Once fingers lift or change after lock,
    // consume the remainder without turning it into a tap or another control.
    public mutating func update(count next: Int, x: Double, time: Double) -> Double? {
        guard !stopped else { return nil }
        if next >= 2 { captured = true }
        if next > 3 || (captured && next < 2) || (control != nil && next != count) {
            stopped = true; return nil
        }
        guard next >= 2 else { return nil }
        if next != count {
            count = next; since = time; anchor = x; return nil
        }
        guard time - since >= 0.15 else { return nil }
        if control == nil {
            guard abs(x - anchor) >= 12 else { return nil }
            control = count == 2 ? .volume : .brightness
            anchor = x
            return 0
        }
        let delta = x - anchor
        guard abs(delta) >= 2 else { return nil }
        anchor = x
        return delta / 400
    }
}
