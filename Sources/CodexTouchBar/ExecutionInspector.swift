import AppKit
import ImageIO
import MonitorCore

private final class HistorySession {
    let taskID: String
    let url: URL
    let home: URL
    var index: ExecutionHistory?
    init(task: TaskState, home: URL) { taskID = task.id; url = URL(fileURLWithPath: task.rolloutPath); self.home = home }
}
private final class StepNode: NSObject {
    var step: ExecutionStep
    var body = ""
    var limit = 16_000
    var more = false
    var loading = false
    var artwork: NSImage?
    lazy var detail = DetailNode(parent: self)
    init(_ step: ExecutionStep) { self.step = step }
}
private final class DetailNode: NSObject {
    weak var parent: StepNode?
    init(parent: StepNode) { self.parent = parent }
}
private final class ActionButton: NSButton {
    var actionBlock: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        target = self; self.action = #selector(invoke); actionBlock = action; bezelStyle = .rounded
    }
    @objc private func invoke() { actionBlock?() }
}

/// Native virtualized outline: rows expand independently, output is loaded only
/// for expanded rows, and both index and expanded text are released on close.
final class ExecutionInspector: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var palette = MenuPalette(settings: DesktopThemeSettings())
    private let home: URL
    private let queue = DispatchQueue(label: "local.codex.touchbar.history", qos: .utility)
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let caption = NSTextField(labelWithString: "点击步骤展开执行详情")
    private var older: NSButton!
    private var latest: NSButton!
    private var session: HistorySession?
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var inFlight = false
    private var refreshAgain = false
    private var nodes: [StepNode] = []
    private var saved: [ExecutionStep] = []
    private var live: [ExecutionStep] = []
    private var liveTaskID: String?
    private var visibleLimit = 80
    private var selectedTask: TaskState?
    private var demo = false
    private var demoBodies: [String: String] = [:]
    override var isFlipped: Bool { true }

    init(home: URL) {
        self.home = home; super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("execution")); column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.delegate = self; outline.dataSource = self
        outline.indentationPerLevel = 12; outline.rowSizeStyle = .custom; outline.selectionHighlightStyle = .none
        outline.backgroundColor = .clear; outline.intercellSpacing = NSSize(width: 0, height: 4)
        outline.target = self; outline.action = #selector(clicked)
        outline.setAccessibilityLabel("任务完整执行记录，可展开每个步骤")
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        caption.font = .systemFont(ofSize: 11); caption.textColor = .secondaryLabelColor
        older = ActionButton("更早记录") { [weak self] in self?.showOlder() }
        latest = ActionButton("最新步骤") { [weak self] in self?.scrollToLatest() }
        let toolbar = NSStackView(views: [older, caption, latest]); toolbar.spacing = 8
        addSubview(toolbar); addSubview(scroll)
        toolbar.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyPalette(_ value: MenuPalette) {
        palette = value
        caption.textColor = value.secondary; caption.font = value.font(11)
        older.font = value.font(12); latest.font = value.font(12)
        older.contentTintColor = value.text; latest.contentTintColor = value.text
        // Reload visible rows in place; preserve expanded nodes and scroll position.
        if outline.numberOfRows > 0 { outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0)) }
    }
    func show(task: TaskState, demo: Bool = false) {
        if session?.taskID != task.id || self.demo != demo {
            close(); self.demo = demo; selectedTask = task
            session = HistorySession(task: task, home: home)
            visibleLimit = 80; saved = []; nodes = []; outline.reloadData()
            if demo { installDemo(); return }
            watch(session!.url)
            scheduleRefresh(immediate: true)
        }
        selectedTask = task
        if !demo && watcher == nil { scheduleRefresh() }
        if task.id != liveTaskID || live != task.liveSteps {
            liveTaskID = task.id; live = task.liveSteps
            if !demo { mergeRows() }
        }
    }
    func close() {
        pending?.cancel(); pending = nil; watcher?.cancel(); watcher = nil
        session = nil; selectedTask = nil; saved = []; live = []; nodes = []; demoBodies = [:]; liveTaskID = nil
        outline.reloadData(); caption.stringValue = "点击步骤展开执行详情"
        // An in-flight read can finish, but its session guard rejects delivery.
    }
    private func watch(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"), resolved.pathExtension == "jsonl" else { return }
        let fd = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if source?.data.intersection([.delete, .rename]).isEmpty == false {
                self.watcher?.cancel(); self.watcher = nil
            }
            self.scheduleRefresh()
        }
        source.setCancelHandler { Darwin.close(fd) }; watcher = source; source.resume()
    }
    private func scheduleRefresh(immediate: Bool = false) {
        guard session != nil, !demo else { return }
        if inFlight { refreshAgain = true; return }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.readIndex() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.5), execute: work)
    }
    private func readIndex() {
        guard let session else { return }
        inFlight = true
        if saved.isEmpty { caption.stringValue = "正在读取执行记录…" }
        queue.async { [weak self] in
            let result: Result<[ExecutionStep], Error> = Result {
                if session.index == nil { session.index = try ExecutionHistory(url: session.url, home: session.home) }
                return try session.index!.refresh()
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.inFlight = false
                guard self.session === session else {
                    if self.session != nil { self.scheduleRefresh(immediate: true) }; return
                }
                switch result {
                case .success(let steps): self.saved = steps; self.mergeRows()
                case .failure(let error): self.caption.stringValue = error.localizedDescription
                }
                if self.watcher == nil { self.watch(session.url) }
                if self.refreshAgain { self.refreshAgain = false; self.scheduleRefresh() }
            }
        }
    }
    private func mergeRows() {
        var all = saved
        let recorded = Set(saved.map(\.id))
        // Current running items may not have a completed log record yet.
        for step in live where !recorded.contains(step.id) { all.append(step) }
        let reading = nodes.contains { outline.isItemExpanded($0) } || scroll.contentView.bounds.maxY < outline.bounds.maxY - 50
        if reading, let first = nodes.first, let anchor = all.firstIndex(where: { $0.id == first.step.id }) {
            visibleLimit = max(visibleLimit, all.count - anchor)
        }
        let visible = Array(all.suffix(visibleLimit))
        let old = Dictionary(nodes.map { ($0.step.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = nodes.map { $0.step.id }
        let expanded = Set(nodes.filter { outline.isItemExpanded($0) }.map { $0.step.id })
        let origin = scroll.contentView.bounds.origin
        let atEnd = scroll.contentView.bounds.maxY >= outline.bounds.maxY - 50
        var changed: [StepNode] = []
        nodes = visible.map { step in
            if let node = old[step.id] {
                if node.step != step {
                    let newRecord = node.step.offset != step.offset || node.step.length != step.length
                    node.step = step; changed.append(node)
                    if newRecord && expanded.contains(step.id) { node.body = ""; load(node) }
                }
                return node
            }
            return StepNode(step)
        }
        caption.stringValue = "\(visible.count) / \(all.count) 条 · 点击展开"
        older.isEnabled = all.count > visibleLimit
        if ids != nodes.map({ $0.step.id }) {
            outline.reloadData()
            for node in nodes where expanded.contains(node.step.id) { outline.expandItem(node) }
            if atEnd || ids.isEmpty { scrollToLatest() }
            else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        } else {
            for node in changed { outline.reloadItem(node) }
        }
    }
    private func showOlder() {
        guard let first = nodes.first else { return }
        visibleLimit += 80; mergeRows()
        let row = outline.row(forItem: first)
        if row >= 0 { outline.scrollRowToVisible(row) }
    }
    private func scrollToLatest() {
        if outline.numberOfRows > 0 { outline.scrollRowToVisible(outline.numberOfRows - 1) }
    }
    private func load(_ node: StepNode) {
        guard !node.loading, let session else { return }
        node.loading = true
        let step = node.step; let limit = node.limit
        let deliver: (String, CGImage?) -> Void = { [weak self, weak node] text, image in
            guard let self, let node, self.session === session, self.nodes.contains(where: { $0 === node }) else { return }
            node.loading = false
            // A stale completion must not replace a newer log record's detail.
            guard node.step.offset == step.offset, node.step.length == step.length else { self.load(node); return }
            guard self.outline.isItemExpanded(node) else { return }
            node.artwork = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            node.more = text.count > limit
            node.body = String(text.prefix(limit))
            self.outline.reloadItem(node.detail)
            let row = self.outline.row(forItem: node.detail)
            if row >= 0 { self.outline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
        }
        if demo {
            DispatchQueue.main.async { deliver(self.demoBodies[step.id] ?? step.preview, nil) }; return
        }
        queue.async {
            let result: String
            do {
                if let index = session.index { result = try index.detail(step) }
                else { result = "记录正在加载，请稍后收起并重新展开。" }
            } catch { result = error.localizedDescription }
            let image = Self.thumbnail(step.imagePath)
            DispatchQueue.main.async { deliver(result, image) }
        }
    }
    @objc private func clicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? StepNode else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? nodes.count : item is StepNode ? 1 : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let node = item as? StepNode { return node.detail }; return nodes[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is StepNode }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? StepNode { if node.body.isEmpty { load(node) } }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? StepNode { node.body = ""; node.limit = 16_000; node.more = false; node.artwork = nil }
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let detail = item as? DetailNode, let node = detail.parent {
            if node.artwork != nil { return 300 }
            let lineCount = max(3, node.body.components(separatedBy: "\n").count + node.body.count / 90)
            return min(260, CGFloat(lineCount) * 16 + 24) + (node.more ? 30 : 0)
        }
        return 48
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? StepNode {
            let identifier = NSUserInterfaceItemIdentifier("step")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
            let a = Activity(id: node.step.id, label: node.step.title, symbol: node.step.symbol, agents: node.step.agents)
            cell.textField?.attributedStringValue = ActivityIcons.attributed(a, fontSize: 12, color: palette.text, limit: 120, font: palette.font(12))
            let subtitle = cell.viewWithTag(20) as? NSTextField
            subtitle?.textColor = palette.secondary; subtitle?.font = palette.font(10)
            subtitle?.stringValue = node.step.preview.isEmpty ? (demo ? "演示记录 · 点击展开" : node.step.offset == nil ? "实时步骤 · 完整结果待写入" : "点击查看命令、输出与步骤详情") : node.step.preview
            cell.setAccessibilityLabel(node.step.title + "，点击展开")
            return cell
        }
        guard let detail = item as? DetailNode, let node = detail.parent else { return nil }
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = palette.inset.cgColor; root.layer?.cornerRadius = 6
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = palette.font(node.step.isMessage ? 12 : 11, code: !node.step.isMessage)
        text.textColor = palette.text; text.textContainerInset = NSSize(width: 7, height: 7)
        text.string = node.body.isEmpty ? "正在加载…" : node.body
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.frame = NSRect(x: 0, y: 0, width: max(100, outline.bounds.width - 40), height: 80)
        let scroller = NSScrollView(); scroller.hasVerticalScroller = true; scroller.drawsBackground = false; scroller.documentView = text
        root.addSubview(scroller); scroller.translatesAutoresizingMaskIntoConstraints = false
        let hasImage = node.artwork != nil
        NSLayoutConstraint.activate([scroller.topAnchor.constraint(equalTo: root.topAnchor, constant: hasImage ? 190 : 0), scroller.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroller.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: node.more || hasImage ? -30 : 0)])
        if let artwork = node.artwork {
            let imageView = NSImageView(); imageView.image = artwork; imageView.imageScaling = .scaleProportionallyUpOrDown
            root.addSubview(imageView); imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6), imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6), imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6), imageView.heightAnchor.constraint(equalToConstant: 178)])
            let open = ActionButton("打开原图") {
                if let url = Self.localImageURL(node.step.imagePath) { NSWorkspace.shared.open(url) }
            }
            root.addSubview(open); open.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([open.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2)])
        }
        if node.more {
            let button = ActionButton("加载更多内容") { [weak self, weak node] in
                guard let self, let node else { return }; node.limit += 16_000; self.load(node)
            }
            root.addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), button.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2)])
        }
        return root
    }
    private static func localImageURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let url = URL(string: path), url.isFileURL { return url }
        return nil
    }
    private static func thumbnail(_ path: String?) -> CGImage? {
        guard let url = localImageURL(path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = id
        let title = NSTextField(labelWithString: ""); title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: ""); subtitle.tag = 20; subtitle.font = .systemFont(ofSize: 10); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        cell.textField = title
        for view in [title, subtitle] { cell.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5), subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 22), subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)])
        return cell
    }
    private func installDemo() {
        let items: [[String: Any]] = [
            ["type": "AgentMessage", "id": "demo-message", "content": [["type": "text", "text": "新版已编译完成，正在检查完整执行记录与 Touch Bar 布局。"]]],
            ["type": "CommandExecution", "id": "demo-command", "command": ["swift", "test"], "cwd": "/tmp/codex-touchbar-demo", "status": "completed", "exit_code": 0, "aggregated_output": "Test Suite 'All tests' passed.\nExecuted tests with 0 failures."],
            ["type": "ImageView", "id": "demo-image", "path": "docs/hardware-touchbar-v4.png"],
            ["type": "FileChange", "id": "demo-file", "status": "completed", "changes": ["DashboardView.swift": ["unified_diff": "- 状态图标\n+ 执行步骤图标与实时摘要"]]],
            ["type": "ContextCompaction", "id": "demo-ctx"],
            ["type": "subAgentActivity", "id": "demo-agent", "agentPath": "/root/luna_ui", "kind": "completed"]
        ]
        saved = items.compactMap { ExecutionParser.step($0) }
        for item in items { demoBodies[item["id"] as! String] = ExecutionParser.details(item) }
        live = []; mergeRows()
        if let command = nodes.first(where: { $0.step.id == "demo-command" }) { outline.expandItem(command) }
    }
    func verifyInteractions(completion: @escaping ([String: Any]) -> Void) {
        guard let node = nodes.last(where: { $0.step.kind == "commandExecution" && ($0.step.offset != nil || demo) }) else { completion(["error": "no recorded command"]); return }
        outline.collapseItem(node)
        let before = outline.numberOfRows
        outline.expandItem(node)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let expanded = self.outline.numberOfRows == before + 1 && self.outline.isItemExpanded(node)
            let loaded = !node.body.isEmpty && !node.loading
            self.mergeRows()
            let preserved = self.outline.isItemExpanded(node)
            self.outline.collapseItem(node)
            let released = node.body.isEmpty && node.artwork == nil && self.outline.numberOfRows == before
            let count = self.nodes.count
            self.showOlder()
            let paged = self.nodes.count >= count
            self.outline.expandItem(node)
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: self.outline.rect(ofRow: self.outline.row(forItem: node)).minY))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
            completion(["expanded": expanded, "detailLoaded": loaded, "expansionPreserved": preserved, "collapseReleasesOutput": released, "paging": paged, "visibleSteps": self.nodes.count, "indexedSteps": self.saved.count])
        }
    }
    /// Uses the same native expand/collapse actions for a reproducible UI check.
    func expandForPreview(image: Bool = false) {
        let chosen = image ? nodes.last(where: { $0.step.kind == "imageView" && $0.step.imagePath != nil }) : nodes.first(where: { $0.step.kind == "commandExecution" })
        if let node = chosen { outline.expandItem(node); scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: outline.row(forItem: node)).minY)); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}
