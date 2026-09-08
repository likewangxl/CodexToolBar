import Foundation

/// Bounded metadata only. Disk recording is enabled explicitly for hardware acceptance.
final class RuntimeDiagnostics {
    private(set) var events: [[String: Any]] = []
    private(set) var output: URL?
    private let queue = DispatchQueue(label: "local.codex.diagnostics", qos: .utility)
    func start(_ url: URL) { output = url; record("acceptanceStarted") }
    func record(_ event: String, _ fields: [String: String] = [:]) {
        events.append(["time": ISO8601DateFormatter().string(from: Date()), "event": event, "fields": fields])
        if events.count > 100 { events.removeFirst(events.count - 100) }
        guard let output, let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: output, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        }
    }
}
