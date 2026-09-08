import AppKit
import CoreText
import MonitorCore

struct BarDetailSnapshot: Equatable {
    var voice: String?
    var canSend = false
    var canEdit = false
    var content = false
    var title = ""
    var subtitle = ""
    var steps: [ExecutionStep] = []
    var firstIndex = 0
    var total = 0
    var message = ""
    var lines: [String] = []
    var page = 0
    var previous = false
    var next = false
}

enum BarDetailAction: Equatable { case back, previous, next, latest, screen, step(String), voice, voiceCancel, voiceStop, voiceRetry, voiceSend, voiceCopy, voiceEdit }

/// Shape only the two lines requested by the reader. No timer, animation, or
/// eager pagination of thousands of output lines. UTF-16 ranges follow CoreText.
final class BarTextPager {
    private let text: NSAttributedString
    private let typesetter: CTTypesetter
    private let width: CGFloat
        private var pages: [[String]] = []
    private var end = 0
    static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    init(_ body: String, width: CGFloat) {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\n", options: .regularExpression)
        text = NSAttributedString(string: normalized.isEmpty ? "该步骤暂无文字内容。" : normalized, attributes: [.font: Self.font])
        typesetter = CTTypesetterCreateWithAttributedString(text)
        self.width = max(30, width)
    }
    func lines(_ page: Int) -> [String] {
        while pages.count <= page && end < text.length {
            var output: [String] = []
            for _ in 0..<2 where end < text.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, end, Double(width))
                let length = count > 0 ? count : (text.string as NSString).rangeOfComposedCharacterSequence(at: end).length
                let part = (text.string as NSString).substring(with: NSRange(location: end, length: min(length, text.length - end)))
                output.append(part.trimmingCharacters(in: .newlines))
                end += length
            }
            pages.append(output)
        }
        return page < pages.count ? pages[page] : []
    }
    func hasNext(_ page: Int) -> Bool { _ = lines(page); return page + 1 < pages.count || end < text.length }
}

/// Owns only the task explicitly entered on Touch Bar. Reads a history index on
/// a utility queue; releasing this session cancels its watcher and cached output.
final class TouchBarDetailController {
    private final class Session {
        let taskID: String, url: URL
        let history: ExecutionHistory
        init(task: TaskState, home: URL) throws {
            taskID = task.id; url = URL(fileURLWithPath: task.rolloutPath)
            history = try ExecutionHistory(url: url, home: home)
        }
    }
    private let home: URL
    private let queue = DispatchQueue(label: "local.codex.touchbar.detail", qos: .utility)
    private var session: Session?
    private var watcher: DispatchSourceFileSystemObject?
    private var scheduled: DispatchWorkItem?
    private var suspended = false
    private var busy = false
    private var again = false
    private var task: TaskState?
    private var saved: [ExecutionStep] = []
    private var live: [ExecutionStep] = []
    private var message = ""
    private var body = ""
    private var pager: BarTextPager?
    private var page = 0
    private var bodyRequest = 0
    private var width: CGFloat = 1004
    private(set) var navigation = TouchBarNavigation()
    var onUpdate: ((BarDetailSnapshot?) -> Void)?
    var onOverview: (() -> Void)?
    var onScreen: ((String) -> Void)?
    var taskID: String? { navigation.taskID }
    var snapshot: BarDetailSnapshot? {
        guard let task, navigation.mode != .overview else { return nil }
        var value = BarDetailSnapshot()
        value.content = navigation.mode == .content
        value.title = value.content ? (navigation.selected?.title ?? task.title) : task.title
        let status = task.connectionIssue ?? (task.isLive ? task.status.label : "本地记录")
        let ctx = task.context.map { "ctx \(Int($0.percent.rounded()))%" } ?? "ctx —"
        value.subtitle = value.content ? "\(task.title) · \(status)" : "\(status) · \(ctx)"
        value.total = navigation.steps.count; value.firstIndex = navigation.start
        value.steps = navigation.visible; value.message = message
        value.page = page
        if value.content {
            value.lines = pager?.lines(page) ?? ["正在读取步骤内容…", ""]
            value.previous = page > 0; value.next = pager?.hasNext(page) ?? false
        } else { value.previous = navigation.canPrevious; value.next = navigation.canNext }
        return value
    }
    init(home: URL) { self.home = home }
    func enter(_ task: TaskState) {
        close(notify: false)
        self.task = task; live = task.liveSteps; navigation.enter(taskID: task.id)
        message = "正在载入历史步骤…"; navigation.update(live); publish()
        do {
            let session = try Session(task: task, home: home); self.session = session
            watch(session); refresh()
        } catch { message = error.localizedDescription; publish() }
    }
    func update(_ tasks: [TaskState]) {
        guard let id = taskID, let next = tasks.first(where: { $0.id == id }) else { return }
        let liveChanged = live != next.liveSteps
        task = next
        if liveChanged { live = next.liveSteps; merge() } else { publish() }
        if watcher == nil, session != nil { schedule() }
    }
    func setWidth(_ width: CGFloat) {
        guard abs(self.width - width) > 1 else { return }; self.width = width
        if navigation.mode == .content { setBody(body, preservePage: false) }
    }
    func act(_ action: BarDetailAction) {
        switch action {
        case .back:
            if navigation.mode == .content {
                navigation.back(); clearBody(); publish()
            } else { close(); onOverview?() }
        case .previous:
            if navigation.mode == .content { page = max(0, page - 1) }
            else { navigation.previous() }; publish()
        case .next:
            if navigation.mode == .content { if pager?.hasNext(page) == true { page += 1 } }
            else { navigation.next() }; publish()
        case .latest: navigation.latest(); clearBody(); publish()
        case .screen: if let id = taskID { onScreen?(id) }
        case .step(let id): navigation.open(id); clearBody(); publish(); load()
        case .voice, .voiceCancel, .voiceStop, .voiceRetry, .voiceSend, .voiceCopy, .voiceEdit: break
        }
    }
    func close(notify: Bool = true) {
        scheduled?.cancel(); scheduled = nil; watcher?.cancel(); watcher = nil
        session = nil; saved = []; live = []; task = nil; navigation = TouchBarNavigation(); clearBody()
        if notify { onUpdate?(nil) }
    }
    func suspend() { suspended = true; scheduled?.cancel(); scheduled = nil; watcher?.cancel(); watcher = nil }
    func resume() { suspended = false; if let session { watch(session); schedule() } }
    private func clearBody() { bodyRequest += 1; body = ""; pager = nil; page = 0 }
    private func publish() { onUpdate?(snapshot) }
    private func watch(_ session: Session) {
        guard !suspended, watcher == nil else { return }
        let fd = Darwin.open(session.url.path, O_EVTONLY | O_CLOEXEC); guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if source?.data.intersection([.rename, .delete]).isEmpty == false { self.watcher?.cancel(); self.watcher = nil }
            self.schedule()
        }
        source.setCancelHandler { Darwin.close(fd) }; watcher = source; source.resume()
    }
    private func schedule() {
        guard !suspended, session != nil else { return }
        if busy { again = true; return }
        guard scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.scheduled = nil; self?.refresh() }
        scheduled = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    private func refresh() {
        guard let session else { return }
        busy = true
        queue.async { [weak self] in
            let result = Result { try session.history.refresh() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                guard self.session === session else { if self.session != nil { self.schedule() }; return }
                switch result {
                case .success(let rows): self.saved = rows; self.message = rows.isEmpty ? "尚无已写入的步骤" : "点步骤展开"; self.merge()
                case .failure(let error): self.message = error.localizedDescription; self.publish()
                }
                if self.watcher == nil { self.watch(session) }
                if self.again { self.again = false; self.schedule() }
            }
        }
    }
    private func merge() {
        let old = navigation.selected
        let ids = Set(saved.map(\.id))
        navigation.update(saved + live.filter { !ids.contains($0.id) })
        if navigation.mode == .content && navigation.selected != old { load(preservePage: true) }
        publish()
    }
    private func setBody(_ value: String, preservePage: Bool) {
        body = value; pager = BarTextPager(value, width: BarDetailRenderer.bodyRect(width: width).width - 12)
        if !preservePage { page = 0 }
        // At most the pages the user explicitly visited are shaped on refresh.
        while page > 0 && pager?.lines(page).isEmpty == true { page -= 1 }
    }
    private func load(preservePage: Bool = false) {
        guard let step = navigation.selected else { return }
        bodyRequest += 1; let request = bodyRequest
        guard let session, step.offset != nil else {
            let text = step.preview.isEmpty ? "该步骤正在执行，详细结果尚未写入。" : step.preview + "\n详细结果将在该步骤写入后显示。"
            setBody(text, preservePage: preservePage); publish(); return
        }
        queue.async { [weak self] in
            let result: String
            do { result = try session.history.detail(step) } catch { result = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self, self.session === session, self.bodyRequest == request, self.navigation.selectedID == step.id else { return }
                self.setBody(result, preservePage: preservePage); self.publish()
            }
        }
    }
}

/// Drawing and hit regions share one geometry. The physical Touch Bar is the
/// navigation surface; the optional screen button is a separate explicit action.
enum BarDetailRenderer {
    private static var icons: [String: NSImage] = [:]
    struct Region { var rect: NSRect; var action: BarDetailAction? }
    static func regions(_ value: BarDetailSnapshot, width: CGFloat) -> [Region] {
        var result: [Region] = []; var x: CGFloat = 2
        func add(_ size: CGFloat, _ action: BarDetailAction?) { result.append(Region(rect: NSRect(x: x, y: 1, width: size, height: 28), action: action)); x += size + 4 }
        if let phase = value.voice {
            add(48, phase == "sending" ? nil : .voiceCancel); add(182, nil)
            add(30, value.previous ? .previous : nil); add(max(60, width - 508), nil)
            add(30, value.next ? .next : nil)
            add(64, phase == "listening" ? .voiceStop : ["review", "error"].contains(phase) ? .voiceRetry : phase == "uncertain" ? .voiceCopy : nil)
            add(56, value.canEdit ? .voiceEdit : nil)
            add(64, value.canSend ? .voiceSend : nil)
            return result
        }
        add(42, .back); add(160, nil); add(30, value.previous ? .previous : nil)
        if value.content { add(max(60, width - 470), nil) }
        else {
            let card = max(30, (width - 478) / 3)
            for i in 0..<3 { add(card, i < value.steps.count ? .step(value.steps[i].id) : nil) }
        }
        add(30, value.next ? .next : nil); add(54, .latest); add(68, .voice); add(54, .screen)
        return result
    }
    static func bodyRect(width: CGFloat) -> NSRect { NSRect(x: 246, y: 1, width: max(60, width - 470), height: 28) }
    static func draw(_ value: BarDetailSnapshot, in bounds: NSRect) {
        if value.voice != nil { drawVoice(value, in: bounds); return }
        let r = regions(value, width: bounds.width).map(\.rect)
        let cyan = NSColor.systemCyan, gray = NSColor.secondaryLabelColor
        for rect in r { NSColor(white: 0.095, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill() }
        label(value.content ? "‹ 步骤" : "‹ 总览", r[0].insetBy(dx: 2, dy: 7), size: 10, color: .white)
        label(value.title, NSRect(x: r[1].minX + 7, y: 2, width: r[1].width - 14, height: 13), size: 10.5, color: .white)
        label(value.subtitle, NSRect(x: r[1].minX + 7, y: 16, width: r[1].width - 14, height: 11), size: 9, color: cyan)
        icon("chevron.left", rect: r[2], color: value.previous ? cyan : gray)
        if value.content {
            for (i, line) in value.lines.prefix(2).enumerated() {
                label(line, NSRect(x: r[3].minX + 6, y: 2 + CGFloat(i) * 13, width: r[3].width - 12, height: 13), size: 10.5, color: .white, mono: true)
            }
            icon("chevron.right", rect: r[4], color: value.next ? cyan : gray)
            label("第 \(value.page + 1) 页", NSRect(x: r[5].minX + 3, y: 2, width: r[5].width - 6, height: 13), size: 9, color: .white)
            label("回到最新", NSRect(x: r[5].minX + 3, y: 16, width: r[5].width - 6, height: 11), size: 8, color: cyan)
        } else {
            for i in 0..<3 {
                let rect = r[i + 3]
                guard i < value.steps.count else { label(value.message.isEmpty ? "等待步骤" : value.message, rect.insetBy(dx: 8, dy: 7), size: 9, color: gray); continue }
                let step = value.steps[i]
                let imageRect = NSRect(x: rect.minX + 6, y: 7, width: 16, height: 16)
                if let badge = step.agents.first { ActivityIcons.badge(badge.style).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
                else { icon(step.symbol, rect: imageRect, color: cyan, inset: false) }
                label(step.title, NSRect(x: rect.minX + 27, y: 2, width: rect.width - 34, height: 13), size: 10, color: .white)
                let preview = step.preview.isEmpty ? "点击展开详情" : step.preview
                label("\(value.firstIndex + i + 1) · \(preview)", NSRect(x: rect.minX + 27, y: 16, width: rect.width - 34, height: 11), size: 9, color: NSColor(white: 0.7, alpha: 1))
            }
            icon("chevron.right", rect: r[6], color: value.next ? cyan : gray)
            label("最新步骤", NSRect(x: r[7].minX + 3, y: 2, width: r[7].width - 6, height: 13), size: 9, color: cyan)
            label("共 \(value.total) 条", NSRect(x: r[7].minX + 3, y: 16, width: r[7].width - 6, height: 11), size: 8, color: gray)
        }
        let mic = r[r.count - 2]
        icon("mic.fill", rect: NSRect(x: mic.minX + 8, y: 4, width: 18, height: 22), color: .systemPink, inset: false)
        label("语音", NSRect(x: mic.minX + 32, y: 8, width: 30, height: 14), size: 10, color: .systemPink)
        label("屏幕详情", r.last!.insetBy(dx: 3, dy: 7), size: 9, color: gray)
    }
    private static func drawVoice(_ value: BarDetailSnapshot, in bounds: NSRect) {
        let r = regions(value, width: bounds.width).map(\.rect)
        let phase = value.voice ?? "", recording = phase == "listening"
        for rect in r { NSColor(white: 0.095, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill() }
        label(phase == "sent" ? "‹ 返回" : "取消", r[0].insetBy(dx: 7, dy: 7), size: 10, color: phase == "sending" ? .gray : .white)
        icon(recording ? "mic.fill" : "text.bubble.fill", rect: NSRect(x: r[1].minX + 5, y: 7, width: 16, height: 16), color: recording ? .systemPink : .systemCyan, inset: false)
        label(value.title, NSRect(x: r[1].minX + 26, y: 2, width: r[1].width - 32, height: 13), size: 10, color: .white)
        label(value.subtitle, NSRect(x: r[1].minX + 26, y: 16, width: r[1].width - 32, height: 11), size: 8.5, color: recording ? .systemPink : .systemCyan)
        icon("chevron.left", rect: r[2], color: value.previous ? .systemCyan : .gray)
        for (i, line) in value.lines.prefix(2).enumerated() {
            label(line, NSRect(x: r[3].minX + 6, y: 2 + CGFloat(i) * 13, width: r[3].width - 12, height: 13), size: 10.5, color: .white, mono: true)
        }
        icon("chevron.right", rect: r[4], color: value.next ? .systemCyan : .gray)
        let middle = recording ? "结束录音" : phase == "finishing" ? "识别中" : phase == "permission" ? "等待授权" : phase == "uncertain" ? "复制文字" : phase == "sending" ? "发送中" : phase == "sent" ? "已完成" : "重新录音"
        label(middle, r[5].insetBy(dx: 6, dy: 7), size: 10, color: recording ? .systemPink : .systemCyan)
        label("编辑", r[6].insetBy(dx: 12, dy: 7), size: 10, color: value.canEdit ? .systemYellow : .gray)
        if value.canSend { NSColor.systemTeal.withAlphaComponent(0.3).setFill(); NSBezierPath(roundedRect: r[7], xRadius: 5, yRadius: 5).fill() }
        label(phase == "sent" ? "已发送 ✓" : "发送 ↑", r[7].insetBy(dx: 9, dy: 7), size: 10, color: value.canSend || phase == "sent" ? .systemMint : .gray)
    }
    private static func label(_ text: String, _ rect: NSRect, size: CGFloat, color: NSColor, mono: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let font = mono ? BarTextPager.font : NSFont.systemFont(ofSize: size, weight: .medium)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]).draw(in: rect)
    }
    private static func icon(_ name: String, rect: NSRect, color: NSColor, inset: Bool = true) {
        let key = name + color.description
        if icons[key] == nil { icons[key] = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color])) }
        let image = icons[key]
        let target = inset ? NSRect(x: rect.midX - 6, y: rect.midY - 7, width: 12, height: 14) : rect
        image?.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
