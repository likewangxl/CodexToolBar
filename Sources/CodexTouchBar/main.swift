import AppKit
import MonitorCore
import TouchBarBridge

let args = CommandLine.arguments
func value(after key: String) -> String? {
    guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}
let home = value(after: "--codex-home").map { URL(fileURLWithPath: $0) }
if args.contains("--account-probe") {
    do {
        let start = Date()
        let result = try AccountUsageReader().readAccount(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        let data: [String: Any] = ["seconds": Date().timeIntervalSince(start), "quotaWindows": result.quota?.windows.map { ["minutes": $0.minutes, "usedPercent": $0.usedPercent, "reset": QuotaDisplay.resetTime($0.resetsAt)] as [String: Any] } ?? [], "quotaError": result.quotaError.map { String(describing: $0) } ?? "none", "tokenError": result.tokenError.map { String(describing: $0) } ?? "none", "yesterday": result.tokens?.yesterday as Any? ?? NSNull(), "total": result.tokens?.total as Any? ?? NSNull()]
        print(String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)); exit(result.quota == nil ? 1 : 0)
    } catch { fputs("Account read failed: \(error)\n", stderr); exit(1) }
}
if args.contains("--account-usage-probe") {
    do {
        let start = Date()
        let result = try AccountUsageReader().read(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        print("Account tokens: yesterday=\(result.yesterday.map(String.init) ?? "null"), total=\(result.total.map(String.init) ?? "null"), seconds=\(Date().timeIntervalSince(start)); helper exited")
        exit(0)
    } catch { fputs("Account usage unavailable: \(error)\n", stderr); exit(1) }
}
if args.contains("--input-probe"), let id = value(after: "--task-id") {
    do {
        let sender = DesktopInputClient(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        let active = try sender.probe(taskID: id)
        print("Owner discovered; v11 snapshot validated; active=\(active); no message sent"); exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if args.contains("--history-probe") {
    do {
        let folder = home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let tasks = try LocalStore(home: folder).list()
        guard let task = value(after: "--task-id").flatMap({ id in tasks.first { $0.id == id } }) ?? tasks.first else { exit(1) }
        let reader = try ExecutionHistory(url: URL(fileURLWithPath: task.rolloutPath), home: folder)
        let start = Date()
        let rows = try reader.refresh()
        let duration = Date().timeIntervalSince(start)
        let bytes = reader.bytesRead
        _ = try reader.refresh()
        let detail = try rows.last(where: { $0.kind == "commandExecution" }).map { try reader.detail($0) } ?? ""
        let result: [String: Any] = ["steps": rows.count, "kinds": Dictionary(grouping: rows, by: \.kind).mapValues(\.count), "indexSeconds": duration, "bytesRead": bytes, "subsequentReadBytes": reader.bytesRead - bytes, "lastCommandDetailCharacters": detail.count]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self)); exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if args.contains("--probe") {
    let monitor = home.map { Monitor(home: $0) } ?? Monitor()
    var lastTasks: [TaskState] = []
    var connection = "未连接"
    var usage: UsageSnapshot?
    monitor.onUsage = { usage = $0 }
    monitor.onUpdate = { tasks, label in lastTasks = tasks; connection = label }
    monitor.start()
    let seconds = min(30, max(1, Double(value(after: "--seconds") ?? "5") ?? 5))
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    let result: [String: Any] = [
        "connection": connection,
        "uiUpdates": monitor.updateCount,
        "quotaPercent": QuotaDisplay.window(in: usage)?.usedPercent as Any? ?? NSNull(),
        "quotaHeadline": QuotaDisplay(usage: usage).headline,
        "quotaResetLine": QuotaDisplay(usage: usage).resetLine,
        "touchBarWidth": CTBDisplayWidth(),
        "globalTouchBarAPI": CTBGlobalPresentationAvailable(),
        "tasks": lastTasks.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue, "live": $0.isLive, "replyCharacters": $0.reply.count, "ctxPercent": $0.context?.percent as Any? ?? NSNull(), "activityCount": $0.activities.count, "agentBadges": $0.activities.flatMap(\.agents).map(\.name)] as [String: Any] }
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    exit(lastTasks.isEmpty ? 1 : 0)
}
if args.contains("--probe-system-controls") {
    let controls = SystemControls()
    print(controls.adjust(.volume, delta: 0))
    controls.end()
    print(controls.adjust(.brightness, delta: 0))
    exit(0)
}
let app = NSApplication.shared
if args.contains("--verify-control-input") {
    let view = DashboardView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
    let ok = view.verifyControlInput()
    print(ok ? "PASS single tap and multi-touch action suppression" : "FAIL control input")
    exit(ok ? 0 : 1)
}
if let fixture = value(after: "--speech-file-probe") {
    let voice = VoiceInputController(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    var finished = false, recognized = false
    voice.probeFile(URL(fileURLWithPath: fixture)) { text, status in
        print("Fixture result: \(text) | \(status)"); recognized = !text.isEmpty; finished = true
    }
    let deadline = Date().addingTimeInterval(35)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    voice.shutdown(); exit(recognized ? 0 : 1)
}
let delegate = AppDelegate(home: home, demo: args.contains("--demo"))
app.delegate = delegate
if let path = value(after: "--verify-persistence") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { delegate.verifyPersistence(to: path) }
}
if let path = value(after: "--render-preview") ?? value(after: "--render-touchbar") {
    if let directory = value(after: "--verify-bar") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { delegate.verifyBarWhenReady(to: directory) }
    }
    if args.contains("--verify-inspector") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { delegate.verifyInspector() }
    } else if args.contains("--expand-step") || args.contains("--expand-image") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { delegate.expandInspectorPreview(image: args.contains("--expand-image")) }
    }
    let delay: Double = args.contains("--verify-bar") ? 18 : args.contains("--bar-start") ? 9 : args.contains("--verify-inspector") ? 7 : (args.contains("--expand-step") || args.contains("--expand-image")) ? 8 : args.contains("--demo") ? 1 : 6
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if let directory = value(after: "--verify-menu") { delegate.verifyMenu(to: directory) }
        if let directory = value(after: "--verify-overview") { delegate.verifyOverview(to: directory) }
        if let directory = value(after: "--verify-voice") { delegate.verifyVoice(to: directory) }
        if let directory = value(after: "--verify-editor") { delegate.verifyVoiceEditor(to: directory) }
        if args.contains("--voice-preview") { delegate.previewVoice(listening: args.contains("--listening")) }
        let ok = delegate.renderPreview(to: path, bar: args.contains("--render-touchbar"))
        print(ok ? "Preview rendered; quota icon: \(QuotaArtwork.image == nil ? "missing" : "loaded")" : "Preview failed")
        app.terminate(nil)
    }
}
app.run()
