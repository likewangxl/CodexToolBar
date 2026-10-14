import AppKit
import MonitorCore

final class ControlSwipeRecognizer: NSGestureRecognizer {
    var onCapture: (() -> Void)?
    var onChange: ((ControlSwipe.Control, Double) -> Void)?
    var onFinish: (() -> Void)?
    private var swipe = ControlSwipe()

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = .direct
        delaysPrimaryMouseButtonEvents = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func process(_ event: NSEvent) {
        guard state == .possible || state == .began || state == .changed else { return }
        let touches = event.touches(matching: .touching, in: view).filter { $0.type == .direct }
        let x = touches.isEmpty ? 0 : touches.reduce(0.0) { $0 + Double($1.location(in: view).x) } / Double(touches.count)
        let delta = swipe.update(count: touches.count, x: x, time: event.timestamp)
        if swipe.captured && state == .possible {
            onCapture?()
            state = .began
        }
        if let delta, let control = swipe.control {
            onChange?(control, delta)
            state = .changed
        }
        if touches.isEmpty { state = swipe.captured ? .ended : .failed }
    }
    override func touchesBegan(with event: NSEvent) { super.touchesBegan(with: event); process(event) }
    override func touchesMoved(with event: NSEvent) { super.touchesMoved(with: event); process(event) }
    override func touchesEnded(with event: NSEvent) { super.touchesEnded(with: event); process(event) }
    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        state = swipe.captured ? .cancelled : .failed
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // A pointer click completes normally; do not reject on mouse-down,
        // which AppKit can synthesize before delivering the direct touches.
        if state == .possible && !swipe.captured { state = .failed }
    }
    override func reset() {
        super.reset()
        if swipe.captured { onFinish?() }
        swipe = ControlSwipe()
    }
}
