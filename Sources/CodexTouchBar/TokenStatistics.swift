import Foundation
import MonitorCore

/// A shared short-lived account connection; no history scanning or persistent helper.
final class TokenStatistics {
    private let home: URL
    private let queue = DispatchQueue(label: "local.codex.account-usage", qos: .utility)
    private var reader: AccountUsageReader?
    private var timer: Timer?
    private var suspended = false
    private var stopped = true
    private var lastAttempt = Date.distantPast
    private var refreshOnResume = false
    private var failures = 0
    private(set) var snapshot = AccountSnapshot()
    private(set) var quotaState: QuotaSyncState = .waiting
    var onUpdate: ((AccountSnapshot, QuotaSyncState) -> Void)?
    init(home: URL) { self.home = home }
    func start() {
        stopped = false; refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
    }
    func refresh(force: Bool = false) {
        guard !stopped, !suspended, reader == nil else { return }
        let elapsed = Date().timeIntervalSince(lastAttempt)
        let resetDue = snapshot.quota?.windows.contains { Date().timeIntervalSince1970 >= $0.resetsAt } ?? false
        let interval = failures > 0 ? min(300, 60 * pow(2, Double(min(failures - 1, 3)))) : resetDue ? 60 : 300
        guard force || elapsed >= interval else { return }
        lastAttempt = Date(); quotaState = .syncing; onUpdate?(snapshot, quotaState)
        let request = AccountUsageReader(); reader = request
        queue.async { [weak self, home] in
            let result = Result { try request.readAccount(home: home) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reader = nil
                guard !self.stopped else { return }
                if self.suspended { self.refreshOnResume = true; return }
                if self.refreshOnResume { self.refreshOnResume = false; self.refresh(force: true); return }
                switch result {
                case .success(var value):
                    self.quotaState = value.quotaError == nil ? .current : .failed
                    if value.quotaError != nil { value.quota = self.snapshot.quota }
                    self.snapshot = value
                    self.failures = value.quotaError == nil && value.tokenError == nil ? 0 : self.failures + 1
                case .failure(let error):
                    self.snapshot.tokens = nil; self.snapshot.tokenError = (error as? AccountUsageError) ?? .unavailable
                    self.snapshot.quotaError = self.snapshot.tokenError; self.quotaState = .failed; self.failures += 1
                }
                self.onUpdate?(self.snapshot, self.quotaState)
            }
        }
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if value { reader?.cancel(); refreshOnResume = true }
        else if reader == nil { refreshOnResume = false; refresh(force: true) }
    }
    func stop() { stopped = true; timer?.invalidate(); timer = nil; reader?.cancel() }
}
