import AppKit
import MonitorCore
import TouchBarBridge

/// Workspace events do the fast recovery; the watchdog only reads isVisible.
/// Neither path activates the app, reloads a task, or resets detail navigation.
final class BarPersistence {
    var policy = PresentationPolicy()
    var onRestore: ((Bool) -> Void)?
    private let bar: NSTouchBar
    private var observation: NSKeyValueObservation?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var forcePending = false
    private(set) var recoveries = 0
    init(_ bar: NSTouchBar) {
        self.bar = bar
        observation = bar.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.schedule() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.restore() }
        timer?.tolerance = 1
    }
    func schedule(activation: Bool = false) {
        guard policy.wanted, policy.pinned, !policy.suspended else { return }
        forcePending = forcePending || activation
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil; let force = self.forcePending; self.forcePending = false
            self.restore(activation: force)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func restore(activation: Bool = false) {
        guard policy.shouldRestore(visible: bar.isVisible, activation: activation, now: ProcessInfo.processInfo.systemUptime) else { return }
        // Re-present the SAME bar when another application changes its Touch Bar.
        // isVisible can stay true during a system-modal replacement on macOS.
        CTBDismiss(bar)
        let restored = CTBPresent(bar)
        if restored { recoveries += 1 }
        onRestore?(restored)
    }
    func stop() { pending?.cancel(); pending = nil; timer?.invalidate(); timer = nil; observation = nil }
    deinit { stop() }
}
