import AppKit
import MonitorCore
import TouchBarBridge

/// One expanding item prevents AppKit's principal-item centering from wasting the
/// right side. Geometry always follows the width actually assigned by Touch Bar.
final class DashboardView: NSButton {
    private(set) var drawCount = 0
    private var tasks: [TaskState] = []
    private var displayedUsage: UsageSnapshot?
    private var signatures: [String] = []
    private var quotaRows = QuotaRow.rows(nil)
    private var quotaSyncState: QuotaSyncState = .waiting
    private var quotaMinute = -1
    private var quotaTimeZone = ""
    private var tokenSummary: AccountTokenSummary?
    private var tokenDisplayDay = Date.distantPast
    private var voiceTaskIndex = 0
    private var imageCache: [String: NSImage] = [:]
    var detail: BarDetailSnapshot? {
        didSet { if oldValue != detail { needsDisplay = true; syncButtons() } }
    }
    var onDetailAction: ((BarDetailAction) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    override func layout() { super.layout(); onWidth?(bounds.width); syncButtons() }
    private var touchButtons: [NSButton] = []
    var onTask: ((String) -> Void)?
    var onQuota: (() -> Void)?
    var onClose: (() -> Void)?
    var onVoice: ((String) -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: CTBDisplayWidth(), height: 30) }
    private var regions: [NSRect] {
        let gap: CGFloat = 4, margin: CGFloat = 2, close: CGFloat = 24, mic: CGFloat = 72
        let quota = min(354, max(344, bounds.width * 0.348))
        let width = max(1, (bounds.width - margin * 2 - gap * 4 - close - mic - quota) / 2)
        return [NSRect(x: margin, y: 1, width: quota, height: 28)] + (0..<2).map {
            NSRect(x: margin + quota + gap + CGFloat($0) * (width + gap), y: 1, width: width, height: 28)
        } + [NSRect(x: bounds.width - margin - close - gap - mic, y: 1, width: mic, height: 28), NSRect(x: bounds.width - margin - close, y: 1, width: close, height: 28)]
    }
    func update(tasks: [TaskState], usage: UsageSnapshot?, tokens: AccountTokenSummary? = nil, selectedID: String? = nil, quotaState: QuotaSyncState = .current) {
        let next = Array(tasks.prefix(2))
        let nextVoice = next.firstIndex(where: { $0.id == selectedID }) ?? 0
        if voiceTaskIndex != nextVoice || self.tasks.first?.id != next.first?.id || self.tasks.isEmpty != next.isEmpty { setNeedsDisplay(regions[3]) }
        voiceTaskIndex = nextVoice
        for i in 0..<2 {
            let task = i < next.count ? next[i] : nil
            let signature = task.map { "\($0.id)|\($0.title)|\($0.status)|\($0.isLive)|\($0.connectionIssue ?? "")|\($0.context?.used ?? -1)|\($0.context?.window ?? -1)|\($0.activities.last?.label ?? "")|\($0.activities.last?.symbol ?? "")|\($0.activities.last?.agents.map(\.style) ?? [])" } ?? "empty"
            if i >= signatures.count { signatures.append(signature); setNeedsDisplay(regions[i + 1]) }
            else if signatures[i] != signature { signatures[i] = signature; setNeedsDisplay(regions[i + 1]) }
        }
        self.tasks = next
        let now = Date().timeIntervalSince1970
        let minute = Int(now / 60), zone = TimeZone.autoupdatingCurrent.identifier
        if usage != displayedUsage || quotaState != quotaSyncState || minute != quotaMinute || zone != quotaTimeZone {
            displayedUsage = usage; quotaSyncState = quotaState; quotaMinute = minute; quotaTimeZone = zone
            let rows = QuotaRow.rows(usage, now: now, state: quotaState)
            if rows != quotaRows { quotaRows = rows; setNeedsDisplay(regions[0]) }
        }
        let day = Calendar.current.startOfDay(for: Date())
        if tokens != tokenSummary || day != tokenDisplayDay { tokenSummary = tokens; tokenDisplayDay = day; setNeedsDisplay(regions[0]) }
        syncButtons()
        setAccessibilityLabel(detail == nil ? "Codex 双窗口额度、昨日累积 token 及最近两个任务" : "Touch Bar 任务步骤与正文，点返回回到总览")
    }
    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        NSColor.black.setFill(); dirtyRect.fill()
        if let detail { BarDetailRenderer.draw(detail, in: bounds); return }
        let rectangles = regions
        let violet = NSColor(srgbRed: 0.72, green: 0.61, blue: 1, alpha: 1)
        if dirtyRect.intersects(rectangles[0]) {
            let r = rectangles[0]; background(r, tint: violet)
            let iconRect = NSRect(x: r.minX + 6, y: 4, width: 22, height: 22)
            if let image = QuotaArtwork.image {
                image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else { symbol("sparkles", in: iconRect, color: violet) }
            for (index, row) in quotaRows.enumerated() {
                let y: CGFloat = index == 0 ? 1 : 15
                let color: NSColor = !row.available || row.expired ? .gray : row.fraction <= 0.2 ? .systemRed : row.fraction <= 0.45 ? .systemOrange : .systemGreen
                let x = r.minX + 32
                text(row.title, rect: NSRect(x: x, y: y, width: 34, height: 13), size: 10, color: .white, weight: .semibold)
                battery(NSRect(x: x + 35, y: y + 4, width: 32, height: 5), fraction: row.fraction, color: color)
                text(row.remaining, rect: NSRect(x: x + 72, y: y, width: 55, height: 13), size: 10, color: row.expired ? .systemOrange : .white, weight: .medium)
                text(row.reset, rect: NSRect(x: x + 126, y: y + 0.5, width: 91, height: 12), size: 9, color: row.expired ? .systemOrange : violet)
                let value = index == 0 ? tokenSummary?.yesterdayValue() : tokenSummary?.total
                let stats = "\(index == 0 ? "昨日" : "累积") \(value.map(TokenSummary.compact) ?? "—")"
                let statsColor = index == 0 ? NSColor(srgbRed: 0.39, green: 0.92, blue: 0.90, alpha: 1) : NSColor(srgbRed: 1, green: 0.82, blue: 0.48, alpha: 1)
                text(stats, rect: NSRect(x: x + 218, y: y, width: r.maxX - x - 221, height: 13), size: 10, color: statsColor, weight: .semibold)
            }
        }
        for i in 0..<2 where dirtyRect.intersects(rectangles[i + 1]) {
            let r = rectangles[i + 1]
            guard i < tasks.count else {
                background(r, tint: .gray)
                text("\(i + 1)  等待最近任务", rect: r.insetBy(dx: 12, dy: 7), size: 11, color: .gray)
                continue
            }
            let task = tasks[i]; let tint = task.status.color
            background(r, tint: tint)
            let badge = task.activities.last?.agents.first
            let iconRect = NSRect(x: r.minX + 7, y: 6, width: 17, height: 17)
            if let badge { ActivityIcons.badge(badge.style).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            else { symbol(task.activities.last?.symbol ?? task.status.symbol, in: iconRect, color: tint) }
            let label = task.connectionIssue ?? (task.isLive ? task.status.label : "本地记录")
            let labelWidth: CGFloat = label.count > 4 ? 61 : 50
            text(task.title, rect: NSRect(x: r.minX + 29, y: 2, width: r.width - 38 - labelWidth, height: 13), size: 10.5, color: .white, weight: .medium)
            text(label, rect: NSRect(x: r.maxX - labelWidth - 7, y: 3, width: labelWidth, height: 12), size: 9, color: tint, alignment: .right)
            let ctx = task.context.map { "ctx \(Int($0.percent.rounded()))% · \(tokens($0.used))/\(tokens($0.window))" } ?? "ctx —"
            let ctxWidth: CGFloat = task.context == nil ? 42 : 113
            let activity = task.activities.last?.label ?? (task.status.active ? "正在处理任务" : task.status.label)
            text(activity, rect: NSRect(x: r.minX + 29, y: 15, width: max(1, r.width - 41 - ctxWidth), height: 11), size: 9, color: NSColor(white: 0.67, alpha: 1))
            let ctxColor: NSColor = (task.context?.percent ?? 0) >= 85 ? .systemOrange : NSColor(white: 0.84, alpha: 1)
            text(ctx, rect: NSRect(x: r.maxX - ctxWidth - 7, y: 15, width: ctxWidth, height: 11), size: 9, color: ctxColor, alignment: .right)
            progress(in: r, fraction: (task.context?.percent ?? 0) / 100, color: (task.context?.percent ?? 0) >= 85 ? .systemOrange : tint)
        }
        if dirtyRect.intersects(rectangles[3]) {
            let r = rectangles[3]; background(r, tint: .systemPink)
            symbol("mic.fill", in: NSRect(x: r.minX + 9, y: 4, width: 18, height: 22), color: tasks.isEmpty ? .gray : .systemPink)
            text("语音", rect: NSRect(x: r.minX + 32, y: 2, width: 36, height: 13), size: 10, color: .systemPink, weight: .semibold)
            text(tasks.isEmpty ? "无任务" : "任务\(voiceTaskIndex + 1)", rect: NSRect(x: r.minX + 32, y: 16, width: 36, height: 11), size: 9, color: .white)
        }
        if dirtyRect.intersects(rectangles[4]) {
            background(rectangles[4], tint: NSColor(white: 0.25, alpha: 1))
            symbol("xmark", in: NSRect(x: rectangles[4].midX - 5, y: 10, width: 10, height: 10), color: .lightGray)
        }
    }
    private func battery(_ r: NSRect, fraction: Double, color: NSColor) {
        for i in 0..<10 {
            (Double(i) < ceil(fraction * 10) ? color : NSColor(white: 0.24, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + CGFloat(i) * 3.2, y: r.minY, width: 2.2, height: r.height), xRadius: 1, yRadius: 1).fill()
        }
    }
    private func tokens(_ value: Int) -> String { String(format: "%.0fk", Double(value) / 1000) }
    private func background(_ r: NSRect, tint: NSColor) {
        NSColor(white: 0.075, alpha: 1).setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        tint.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    }
    private func progress(in r: NSRect, fraction: Double, color: NSColor) {
        let track = NSRect(x: r.minX + 7, y: 27, width: r.width - 14, height: 1)
        color.withAlphaComponent(0.18).setFill(); track.fill()
        color.withAlphaComponent(0.8).setFill(); NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: 1).fill()
    }
    private func text(_ string: String, rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]).draw(in: rect)
    }
    private func symbol(_ name: String, in r: NSRect, color: NSColor) {
        let key = name + color.description
        let image: NSImage
        if let cached = imageCache[key] { image = cached }
        else {
            let config = NSImage.SymbolConfiguration(paletteColors: [color])
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
            imageCache[key] = image
        }
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private func syncButtons() {
        guard bounds.width > 0 else { return }
        let hitRegions: [(NSRect, String, Bool)]
        if let detail {
            hitRegions = BarDetailRenderer.regions(detail, width: bounds.width).map { region in
                let label: String
                switch region.action {
                case .back: label = detail.content ? "返回步骤" : "返回总览"
                case .previous: label = "上一页"
                case .next: label = "下一页"
                case .latest: label = "最新步骤"
                case .screen: label = "在电脑屏幕查看详情"
                case .step(let id): label = detail.steps.first(where: { $0.id == id })?.title ?? "展开步骤"
                case .voice: label = "语音输入给当前任务"
                case .voiceCancel: label = "关闭语音输入返回任务"
                case .voiceStop: label = "结束录音并检查文字"
                case .voiceRetry: label = "重新录音"
                case .voiceSend: label = "发送文字给当前任务"
                case .voiceEdit: label = "编辑语音文字，保存后复核"
                case .voiceCopy: label = "复制文字并检查发送结果"
                case nil: label = ""
                }
                return (region.rect, label, region.action != nil)
            }
        } else {
            hitRegions = regions.enumerated().map { i, r in
                (r, i == 0 ? "账户额度与昨日、累积 Token 统计" : i == 4 ? "收起 Touch Bar" : i == 3 ? (tasks.isEmpty ? "等待任务后使用语音" : "语音输入给任务\(voiceTaskIndex + 1)：" + tasks[voiceTaskIndex].title) : i - 1 < tasks.count ? "查看 " + tasks[i - 1].title : "等待任务", i == 0 || i == 4 || (i == 3 ? !tasks.isEmpty : i - 1 < tasks.count))
            }
        }
        if touchButtons.count != hitRegions.count {
            touchButtons.forEach { $0.removeFromSuperview() }; touchButtons = []
            for _ in hitRegions {
                let button = NSButton(title: "", target: self, action: #selector(nativeTap(_:)))
                button.isBordered = false; button.isTransparent = true
                button.setButtonType(.momentaryPushIn)
                addSubview(button); touchButtons.append(button)
            }
        }
        for (button, region) in zip(touchButtons, hitRegions) {
            button.frame = region.0; button.isEnabled = region.2
            button.setAccessibilityLabel(region.1)
        }
    }
    @objc private func nativeTap(_ sender: NSButton) { activate(at: NSPoint(x: sender.frame.midX, y: sender.frame.midY)) }
    /// Exercises the same native NSButton action as a physical Touch Bar tap.
    func performTap(at point: NSPoint) {
        syncButtons()
        touchButtons.first(where: { $0.frame.contains(point) && $0.isEnabled })?.performClick(nil)
    }
    override func mouseDown(with event: NSEvent) {
        activate(at: convert(event.locationInWindow, from: nil))
    }
    func taskPoint(_ index: Int) -> NSPoint {
        let rect = regions[min(2, max(1, index + 1))]
        return NSPoint(x: rect.midX, y: rect.midY)
    }
    func voicePoint() -> NSPoint { NSPoint(x: regions[3].midX, y: regions[3].midY) }
    func activate(at point: NSPoint) {
        if let detail {
            if let action = BarDetailRenderer.regions(detail, width: bounds.width).first(where: { $0.rect.contains(point) })?.action { onDetailAction?(action) }
            return
        }
        guard let index = regions.firstIndex(where: { $0.contains(point) }) else { return }
        if index == 0 { onQuota?() }
        else if index == 4 { onClose?() }
        else if index == 3, !tasks.isEmpty { onVoice?(tasks[voiceTaskIndex].id) }
        else if index - 1 < tasks.count { onTask?(tasks[index - 1].id) }
    }
}
