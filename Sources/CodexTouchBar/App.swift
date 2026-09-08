import AppKit
import ServiceManagement
import MonitorCore
import TouchBarBridge


extension WorkStatus {
    var color: NSColor {
        switch self {
        case .working, .tool, .replying: return .systemCyan
        case .waiting: return .systemOrange
        case .completed: return .systemGreen
        case .failed: return .systemRed
        case .interrupted, .idle, .unknown: return .secondaryLabelColor
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSPopoverDelegate {
    private let monitor: Monitor
    private let defaults = UserDefaults.standard
    private var tasks: [TaskState] = []
    private var completions = CompletionNotifications()
    private var lastBadgeCount = -1
    private let menuAppearance: MenuAppearance
    private var menuPalette = MenuPalette(settings: DesktopThemeSettings())
    private let heading = NSTextField(labelWithString: "CODEX  /  TOUCH BAR")
    private let quotaPanel = NSView()
    private let completedButton = NSButton(title: "", target: nil, action: nil)
    private var fixedID: String?
    private var automaticID: String?
    private var connectionLabel = "正在连接 Codex…"
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var previewHost: NSWindow?
    private var touchBar: NSTouchBar!
    private let dashboard = DashboardView()
    private var usage: UsageSnapshot?
    private let diagnostics = RuntimeDiagnostics()
    private var systemSleeping = false
    private var tokenSummary: AccountTokenSummary?
    private var quotaState: QuotaSyncState = .waiting
    private let tokenStatistics: TokenStatistics
    private var touchVisible = false
    private var persistence: BarPersistence?
    private var sleeping = false
    private var sessionInactive = false
    private var locked = false
    private let voice: VoiceInputController
    private var clockTimer: Timer?
    private var terminationSource: DispatchSourceSignal?
    private var rendering: Bool { CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--render-touchbar") }
    private var pickerIDs: [String] = []
    private let picker = NSPopUpButton()
    private let taskTitle = NSTextField(labelWithString: "Codex Touch Bar")
    private let sourceLabel = NSTextField(labelWithString: "正在连接 Codex…")
    private let statusLabel = NSTextField(labelWithString: "等待任务")
    private let previewLabel = NSTextField(labelWithString: "")
    private let inspector: ExecutionInspector
    private let barDetail: TouchBarDetailController
    private var showButton: NSButton!
    private let demo: Bool

    init(home: URL? = nil, demo: Bool = false) {
        self.demo = demo
        menuAppearance = MenuAppearance(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        tokenStatistics = TokenStatistics(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        voice = VoiceInputController(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        barDetail = TouchBarDetailController(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        inspector = ExecutionInspector(home: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        monitor = home.map { Monitor(home: $0) } ?? Monitor()
        super.init()
    }
    private var selected: TaskState? {
        let id = fixedID ?? automaticID
        return tasks.first { $0.id == id } ?? tasks.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["showOnLaunch": true, "pinTouchBar": true])
        if !rendering, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codex.touchbar").first(where: { $0.processIdentifier != getpid() }) {
            existing.activate(options: .activateAllWindows); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--acceptance-log"), CommandLine.arguments.indices.contains(index + 1) {
            diagnostics.start(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        diagnostics.record("launched", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"])
        voice.onDiagnostic = { [weak self] event, fields in self?.diagnostics.record(event, fields) }
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }; terminationSource = termination; termination.resume()
        fixedID = defaults.string(forKey: "fixedTaskID")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshMenuIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buildPopover()
        applyMenuAppearance()
        menuAppearance.onChange = { [weak self] in
            guard let self, self.popover.isShown else { return }; self.applyMenuAppearance()
        }
        if !rendering { menuAppearance.start() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemAppearanceChanged), name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        if CommandLine.arguments.contains("--render-preview"), let root = popover.contentViewController?.view {
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = menuPalette.appearance; window.contentView = root
            root.layoutSubtreeIfNeeded(); previewHost = window
        }
        buildTouchBar()
        if !rendering {
            CTBPrepareTray(self, #selector(showTouchBar))
            persistence = BarPersistence(touchBar)
            persistence?.policy.pinned = defaults.bool(forKey: "pinTouchBar")
            persistence?.onRestore = { [weak self] restored in self?.diagnostics.record("barRestored", ["success": String(restored)]) }
        }
        monitor.onUpdate = { [weak self] tasks, label in self?.receive(tasks, label) }
        monitor.onUsage = { [weak self] usage in
            guard let self else { return }; self.tokenStatistics.refresh()
            if self.popover.isShown { self.updateDetails() }
        }
        tokenStatistics.onUpdate = { [weak self] value, state in
            guard let self else { return }; self.tokenSummary = value.tokens; self.usage = value.quota; self.quotaState = state; self.refreshTouchBar()
            if self.popover.isShown { self.updateDetails() }
        }
        if demo {
            var task = TaskState(id: "demo", title: "开发 Codex Touch Bar 状态工具", updatedAt: Date().timeIntervalSince1970)
            task.status = .working; task.isLive = true; task.reply = "正在把任务状态和最新回复实时显示到 Touch Bar。点击任一会话卡片查看完整回复、活动和精确 ctx。"
            task.activities = [
                Activity(id: "1", label: "已读取文件", symbol: "book"),
                Activity(id: "2", label: "Luna backend 和 Luna reference index 有了更新", symbol: "person.2", agents: [AgentBadge(id: "backend", path: "/root/luna_backend"), AgentBadge(id: "reference", path: "/root/luna_reference_index")]),
                Activity(id: "3", label: "编辑了文件", symbol: "pencil"),
                Activity(id: "4", label: "Luna integration 有了更新", symbol: "person.2", agents: [AgentBadge(id: "integration", path: "/root/luna_integration")]),
                Activity(id: "5", label: "Luna ui 有了更新", symbol: "person.2", agents: [AgentBadge(id: "ui", path: "/root/luna_ui")])
            ]
            task.context = ContextUsage(used: 195727, window: 258400)
            var second = TaskState(id: "demo2", title: "检查构建和测试结果")
            second.status = .completed; second.isLive = true; second.context = ContextUsage(used: 48898, window: 258400)
            second.activities = [Activity(id: "a", label: "Luna backend 有了更新", symbol: "person.2", agents: [AgentBadge(id: "b", path: "/root/luna_backend")])]
            var third = TaskState(id: "demo3", title: "同步远端目录文件")
            third.status = .waiting; third.isLive = true; third.context = ContextUsage(used: 226000, window: 258400)
            third.activities = [Activity(id: "b", label: "等待确认后继续", symbol: "hand.raised")]
            usage = UsageSnapshot(primary: QuotaWindow(usedPercent: 14, minutes: 300, resetsAt: Date().timeIntervalSince1970 + 7200), secondary: QuotaWindow(usedPercent: 18, minutes: 10080, resetsAt: Date().timeIntervalSince1970 + 500000), observedAt: Date().timeIntervalSince1970)
            quotaState = .current
            tokenSummary = AccountTokenSummary(yesterday: 512000123, total: 12500067890)
            receive([task, second, third], "演示数据 · 非实时任务")
        } else { monitor.start(); if !rendering { tokenStatistics.start() } }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.touchBar.isVisible || self.popover.isShown else { return }; self.refreshTouchBar()
        }
        clockTimer?.tolerance = 10
        if defaults.bool(forKey: "showOnLaunch") && !rendering {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showTouchBar() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(timeZoneChanged), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(applicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        if let index = CommandLine.arguments.firstIndex(of: "--bar-start"), CommandLine.arguments.indices.contains(index + 1) {
            let content = CommandLine.arguments[index + 1] == "content"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.enterBarTask() }
            if content { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.openBarStep() } }
        }
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showPopover() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistence?.stop(); voice.shutdown(); tokenStatistics.stop()
        if !rendering {
            if touchBar != nil { CTBDismiss(touchBar) }
            CTBRemoveTray()
        }
        clockTimer?.invalidate(); inspector.close(); barDetail.close()
    }

    private func receive(_ tasks: [TaskState], _ label: String) {
        completions.update(tasks)
        self.tasks = tasks; connectionLabel = label
        voice.connectionChanged()
        if fixedID == nil {
            // Follow the newest user activity, not whichever background tool emitted last.
            let candidates = tasks.filter { $0.isLive && $0.status.active }
            let next = candidates.max { $0.updatedAt < $1.updatedAt } ?? tasks.first
            automaticID = next?.id
        }
        refreshTouchBar()
        refreshMenuIcon()
        if popover.isShown || rendering { updateDetails() }
    }

    private func updateDetails() {
        let label = connectionLabel
        let ids = tasks.map(\.id)
        let labels = ["自动跟随最近活跃任务"] + tasks.map { "\(completions.unread.contains($0.id) ? "● " : "")\($0.status.label) · \(String(TaskState.singleLine($0.title).prefix(38)))" }
        if ids != pickerIDs || picker.itemTitles != labels {
            pickerIDs = ids; picker.removeAllItems(); picker.addItems(withTitles: labels)
        }
        picker.selectItem(at: fixedID.flatMap { pickerIDs.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        let current = selected
        let activeCount = tasks.filter { $0.isLive && $0.status.active }.count
        refreshMenuIcon()
        taskTitle.stringValue = current?.title ?? "还没有可显示的任务"
        statusLabel.stringValue = "\(current?.status.label ?? "等待任务")\(activeCount > 0 ? "   ·   \(activeCount) 个任务进行中" : "")"
        statusLabel.textColor = menuPalette.accent
        completedButton.title = completions.unread.isEmpty ? "暂无未读完成任务" : "\(completions.unread.count) 个任务已完成 · 点击查看"
        completedButton.isEnabled = !completions.unread.isEmpty
        sourceLabel.stringValue = demo ? "演示数据 · 非实时任务" : current?.isLive == true ? "实时连接 · 本机 Codex" : label + " · 状态以 Codex 为准"
        if let current, popover.isShown || CommandLine.arguments.contains("--render-preview") {
            inspector.show(task: current, demo: demo)
        }
        previewLabel.stringValue = usageDescription()
    }

    private func refreshMenuIcon() {
        let count = completions.unread.count
        if count != lastBadgeCount {
            statusItem.button?.image = MenuArtwork.image(unread: count); lastBadgeCount = count
        }
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.contentTintColor = nil
        let summary = count > 0 ? "\(count) 个任务已完成，尚未查看" : "没有未读完成任务"
        statusItem.button?.toolTip = "Codex Touch Bar · " + summary
        statusItem.button?.setAccessibilityLabel("Codex Touch Bar，" + summary)
    }
    private func acknowledgeTask(_ id: String) {
        completions.acknowledge(id); refreshMenuIcon()
    }
    @objc private func openCompletedTask() {
        guard let task = tasks.first(where: { completions.unread.contains($0.id) }) else { return }
        fixedID = task.id; if !rendering { defaults.set(task.id, forKey: "fixedTaskID") }
        acknowledgeTask(task.id); monitor.select(task.id); updateDetails()
    }
    @objc private func systemAppearanceChanged() { if popover.isShown { applyMenuAppearance() } }
    private func applyMenuAppearance() {
        let palette = menuAppearance.read()
        guard palette.settings != menuPalette.settings || popover.appearance == nil else { return }
        menuPalette = palette; popover.appearance = palette.appearance
        guard let root = popover.contentViewController?.view as? PanelBackground else { return }
        root.appearance = palette.appearance; root.fillColor = palette.background
        root.window?.appearance = palette.appearance
        heading.textColor = palette.secondary; heading.font = palette.font(11, weight: .bold)
        taskTitle.textColor = palette.text; taskTitle.font = palette.font(19, weight: .semibold)
        sourceLabel.textColor = palette.secondary; sourceLabel.font = palette.font(10)
        statusLabel.textColor = palette.accent; statusLabel.font = palette.font(13, weight: .medium)
        previewLabel.textColor = palette.text; previewLabel.font = palette.font(12)
        quotaPanel.layer?.backgroundColor = palette.inset.cgColor
        picker.font = palette.font(12); picker.contentTintColor = palette.text
        picker.menu?.appearance = palette.appearance
        completedButton.contentTintColor = palette.accent; completedButton.font = palette.font(12, weight: .medium)
        func styleButtons(_ view: NSView) {
            for child in view.subviews {
                if let button = child as? NSButton { button.font = palette.font(12); button.contentTintColor = palette.text }
                styleButtons(child)
            }
        }
        styleButtons(root); completedButton.contentTintColor = palette.accent
        inspector.applyPalette(palette)
    }

    private func buildPopover() {
        popover = NSPopover(); popover.behavior = .transient; popover.delegate = self
        let controller = NSViewController()
        let root = PanelBackground(frame: NSRect(x: 0, y: 0, width: 660, height: 760))
        controller.view = root; popover.contentViewController = controller
        heading.font = .systemFont(ofSize: 11, weight: .bold); heading.textColor = .secondaryLabelColor
        taskTitle.font = .systemFont(ofSize: 19, weight: .semibold); taskTitle.lineBreakMode = .byTruncatingTail
        taskTitle.maximumNumberOfLines = 1
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sourceLabel.font = .systemFont(ofSize: 10); sourceLabel.textColor = .secondaryLabelColor
        picker.target = self; picker.action = #selector(selectTask); picker.font = .systemFont(ofSize: 12)
        let preview = quotaPanel; preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.black.cgColor; preview.layer?.cornerRadius = 8
        previewLabel.font = .systemFont(ofSize: 12, weight: .medium); previewLabel.textColor = .white
        previewLabel.maximumNumberOfLines = 4; previewLabel.lineBreakMode = .byTruncatingTail
        preview.addSubview(previewLabel); previewLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.heightAnchor.constraint(equalToConstant: 82), previewLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 12), previewLabel.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -12), previewLabel.centerYAnchor.constraint(equalTo: preview.centerYAnchor)])
        let open = NSButton(title: "打开 Codex 任务", target: self, action: #selector(openTask)); open.bezelStyle = .rounded
        showButton = NSButton(title: "显示 Touch Bar", target: self, action: #selector(toggleTouchBar)); showButton.bezelStyle = .rounded
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!, target: self, action: #selector(showSettings)); settings.bezelStyle = .rounded
        completedButton.target = self; completedButton.action = #selector(openCompletedTask); completedButton.bezelStyle = .inline
        let actions = NSStackView(views: [open, showButton, settings]); actions.spacing = 8
        let stack = NSStackView(views: [heading, taskTitle, statusLabel, sourceLabel, completedButton, picker, preview, inspector, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 11
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)])
        for view in [taskTitle, picker, preview, inspector] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        inspector.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    }

    private func buildTouchBar() {
        touchBar = NSTouchBar(); touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [NSTouchBarItem.Identifier("local.codex.touchbar.dashboard")]
        NSApp.touchBar = touchBar
        _ = touchBar.item(forIdentifier: touchBar.defaultItemIdentifiers[0])
        dashboard.onTask = { [weak self] id in
            guard let self, let task = self.tasks.first(where: { $0.id == id }) else { return }
            self.fixedID = id; self.acknowledgeTask(id); self.monitor.select(id)
            self.barDetail.setWidth(self.dashboard.bounds.width > 0 ? self.dashboard.bounds.width : CTBDisplayWidth())
            self.barDetail.enter(task)
        }
        dashboard.onDetailAction = { [weak self] action in
            guard let self else { return }
            if self.voice.active { self.voice.act(action) }
            else if action == .voice, let id = self.barDetail.taskID, let task = self.tasks.first(where: { $0.id == id }) {
                if self.rendering { self.voice.preview(task: task, phase: .listening) } else { self.voice.start(task: task) }
            } else { self.barDetail.act(action) }
        }
        dashboard.onWidth = { [weak self] width in
            self?.barDetail.setWidth(width); self?.voice.setWidth(width)
        }
        barDetail.onUpdate = { [weak self] snapshot in
            guard let self, !self.voice.active else { return }; self.dashboard.detail = snapshot
        }
        voice.canSendToTask = { [weak self] id in self?.tasks.first(where: { $0.id == id })?.connectionIssue == nil }
        voice.onUpdate = { [weak self] snapshot in
            guard let self else { return }; self.dashboard.detail = snapshot ?? self.barDetail.snapshot
        }
        barDetail.onOverview = { [weak self] in
            guard let self else { return }; self.monitor.select(self.popover.isShown ? self.selected?.id : nil)
            self.refreshTouchBar()
        }
        barDetail.onScreen = { [weak self] id in
            guard let self else { return }; self.fixedID = id; self.showPopover()
        }
        dashboard.onVoice = { [weak self] id in
            guard let self, let task = self.tasks.prefix(2).first(where: { $0.id == id }) else { return }
            self.fixedID = id; self.acknowledgeTask(id); self.monitor.select(id)
            self.barDetail.setWidth(self.dashboard.bounds.width)
            self.barDetail.enter(task)
            if self.rendering { self.voice.preview(task: task, phase: .listening) }
            else { self.voice.start(task: task) }
        }
        dashboard.onQuota = { [weak self] in self?.showPopover() }
        dashboard.onClose = { [weak self] in self?.hideTouchBar() }
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        dashboard.isBordered = false
        dashboard.title = ""
        dashboard.wantsLayer = true
        dashboard.layerContentsRedrawPolicy = .onSetNeedsDisplay
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        dashboard.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        dashboard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let width = dashboard.widthAnchor.constraint(equalToConstant: CTBDisplayWidth())
        width.priority = .defaultLow; width.isActive = true
        dashboard.heightAnchor.constraint(equalToConstant: 30).isActive = true
        item.view = dashboard
        return item
    }
    private func refreshTouchBar() { dashboard.update(tasks: tasks, usage: usage, tokens: tokenSummary, selectedID: selected?.id, quotaState: quotaState); barDetail.update(tasks) }
    private func usageDescription() -> String {
        let stats = tokenSummary.map { "账户 token 昨日 \($0.yesterdayValue().map(String.init) ?? "—") · 累积 \($0.total.map(String.init) ?? "—")（\($0.observedAt.formatted(date: .omitted, time: .shortened)) 同步）" } ?? "账户 token 等待同步或暂不可用（不使用本地日志代替）"
        let ctx = selected?.context.map { "ctx \(Int($0.percent.rounded()))% · \($0.used) / \($0.window) tokens" } ?? "ctx 暂无数据"
        guard let usage else { return "用量等待 Codex 更新\n\(stats)\n\(ctx)" }
        let windows = usage.windows.map { window in
            let stale = quotaState != .current || Date().timeIntervalSince1970 - usage.observedAt >= 600 || Date().timeIntervalSince1970 >= window.resetsAt
            let status = stale ? "上次已用" : "已用"
            return "\(window.displayName) \(status) \(Int(window.usedPercent.rounded()))%"
        }.joined(separator: " · ")
        let resets = usage.windows.map { "\($0.displayName) \(QuotaDisplay.resetTime($0.resetsAt)) 重置" }.joined(separator: " · ")
        let date = Date(timeIntervalSince1970: usage.observedAt).formatted(date: .omitted, time: .shortened)
        let state = quotaState == .failed ? "同步失败 · 保留上次数据" : quotaState == .syncing ? "正在同步" : Date().timeIntervalSince1970 - usage.observedAt >= 600 ? "数据过期" : "账户已同步"
        return "\(windows) · \(date) · \(state)\n\(resets)（\(TimeZone.autoupdatingCurrent.identifier)）\n\(stats)\n\(ctx)"
    }

    @objc private func selectTask() {
        fixedID = picker.indexOfSelectedItem > 0 ? pickerIDs[picker.indexOfSelectedItem - 1] : nil
        defaults.set(fixedID, forKey: "fixedTaskID"); monitor.select(fixedID)
        if let id = selected?.id { acknowledgeTask(id) }
        receive(tasks, connectionLabel)
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp { showSettings(); return }
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem.button else { return }
        applyMenuAppearance()
        if let id = selected?.id { acknowledgeTask(id) }
        monitor.select(selected?.id)
        if let selected { inspector.show(task: selected, demo: demo) }
        updateDetails()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ notification: Notification) { monitor.select(barDetail.taskID); inspector.close() }
    @objc private func openTask() {
        guard let id = selected?.id, UUID(uuidString: id) != nil,
              let url = URL(string: "codex://threads/\(id)") else { return }
        NSWorkspace.shared.open(url)
        popover.performClose(nil)
    }
    @objc private func showTouchBar() {
        touchVisible = true; persistence?.policy.wanted = true
        guard !sleeping, !systemSleeping, !locked, !sessionInactive else { return }
        NSLog("CTB presenting %ld items; %ld materialized", touchBar.defaultItemIdentifiers.count, touchBar.defaultItemIdentifiers.compactMap { touchBar.item(forIdentifier: $0) }.count)
        if CTBPresent(touchBar) {
            touchVisible = true; showButton.title = "收起 Touch Bar"; refreshTouchBar(); dashboard.needsDisplay = true
            if let index = CommandLine.arguments.firstIndex(of: "--layout-diagnostics"), CommandLine.arguments.indices.contains(index + 1) {
                let path = CommandLine.arguments[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    let data: [String: Any] = ["visible": self.touchBar.isVisible, "drawCount": self.dashboard.drawCount, "frame": NSStringFromRect(self.dashboard.frame), "bounds": NSStringFromRect(self.dashboard.bounds), "window": self.dashboard.window.map { NSStringFromRect($0.frame) } ?? "nil", "superview": self.dashboard.superview.map { NSStringFromRect($0.frame) } ?? "nil", "hidden": self.dashboard.isHiddenOrHasHiddenAncestor, "hasAmbiguousLayout": self.dashboard.hasAmbiguousLayout, "width": CTBDisplayWidth()]
                    try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
                }
            }
        } else {
            sourceLabel.stringValue = "此 macOS 不支持跨应用显示；可使用菜单栏预览"
            showPopover()
        }
    }
    @objc private func hideTouchBar() { persistence?.policy.wanted = false; voice.suspend(); voice.cancel(); CTBDismiss(touchBar); barDetail.close(); monitor.select(popover.isShown ? selected?.id : nil); touchVisible = false; showButton.title = "显示 Touch Bar" }
    @objc private func toggleTouchBar() { if touchBar.isVisible { hideTouchBar() } else { showTouchBar() } }
    @objc private func applicationChanged() { diagnostics.record("applicationChanged", ["bundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]); persistence?.schedule(activation: true) }
    @objc private func screenDidSleep() { sleeping = true; diagnostics.record("screenSlept"); updateSuspension() }
    @objc private func screenDidWake() { sleeping = false; diagnostics.record("screenWoke"); updateSuspension() }
    @objc private func systemWillSleep() { systemSleeping = true; diagnostics.record("systemWillSleep"); updateSuspension() }
    @objc private func systemDidWake() { systemSleeping = false; diagnostics.record("systemDidWake"); updateSuspension() }
    @objc private func timeZoneChanged() { refreshTouchBar(); if popover.isShown { updateDetails() }; tokenStatistics.refresh(force: true) }
    @objc private func sessionResigned() { sessionInactive = true; diagnostics.record("sessionResigned"); updateSuspension() }
    @objc private func sessionBecameActive() { sessionInactive = false; diagnostics.record("sessionActive"); updateSuspension() }
    @objc private func screenLocked() { locked = true; diagnostics.record("screenLocked"); updateSuspension() }
    @objc private func screenUnlocked() { locked = false; diagnostics.record("screenUnlocked"); updateSuspension() }
    private func updateSuspension() {
        let paused = systemSleeping || sleeping || sessionInactive || locked
        persistence?.policy.suspended = paused
        diagnostics.record("suspensionChanged", ["paused": String(paused), "taskSuffix": String((barDetail.taskID ?? "").suffix(8)), "content": String(dashboard.detail?.content ?? false)])
        tokenStatistics.setSuspended(paused); monitor.setSuspended(paused)
        if paused { voice.suspend(); barDetail.suspend(); CTBDismiss(touchBar) }
        else {
            barDetail.resume()
            if touchVisible {
                if defaults.bool(forKey: "pinTouchBar") { persistence?.schedule(activation: true) }
                else { showTouchBar() }
            }
        }
    }
    @objc private func togglePinned() {
        let enabled = !defaults.bool(forKey: "pinTouchBar")
        defaults.set(enabled, forKey: "pinTouchBar"); persistence?.policy.pinned = enabled
        if enabled { showTouchBar() }
    }
    @objc private func refreshAccountUsage() { if !demo && !rendering { tokenStatistics.refresh(force: true) } }
    @objc private func startAcceptance() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("local.codex.touchbar/acceptance.json")
        diagnostics.start(root); showDiagnostics()
    }
    @objc private func showDiagnostics() {
        let alert = NSAlert(); alert.messageText = "连接与兼容性诊断"
        let codex = ["/Applications/Codex.app", "/Applications/ChatGPT.app"].compactMap { Bundle(path: $0) }.first
        let appVersion = codex?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未发现"
        alert.informativeText = "Codex：\(appVersion)\n\(connectionLabel)\n已适配任务流：v11 · 输入：start v2 / steer v1\n账户额度：\(quotaState.rawValue)\n\(voice.diagnosticSummary)\n跨应用接口：\(CTBGlobalPresentationAvailable() ? "可用" : "不可用，使用菜单栏") · Touch Bar：\(touchBar.isVisible ? "可见" : "未显示")\n暂停：\(systemSleeping || sleeping || locked || sessionInactive) · 恢复次数：\(persistence?.recoveries ?? 0)\n记录：\(diagnostics.output?.path ?? "仅内存，最近 100 条元数据")"
        alert.addButton(withTitle: "关闭"); alert.runModal()
    }
    @objc private func showSettings() {
        applyMenuAppearance()
        let menu = NSMenu(); menu.appearance = menuPalette.appearance
        func add(_ title: String, _ selector: Selector, on: Bool? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
            if let on { item.state = on ? .on : .off }; menu.addItem(item)
        }
        add("连接与兼容性诊断", #selector(showDiagnostics))
        add("开始实机验收记录", #selector(startAcceptance))
        add("刷新额度与 Token 统计", #selector(refreshAccountUsage))
        add("显示 Touch Bar", #selector(showTouchBar))
        add("收起 Touch Bar", #selector(hideTouchBar))
        menu.addItem(.separator())
        add("跨应用常驻 Touch Bar", #selector(togglePinned), on: defaults.bool(forKey: "pinTouchBar"))
        add("启动时显示 Touch Bar", #selector(toggleLaunchDisplay), on: defaults.bool(forKey: "showOnLaunch"))
        add("登录时启动", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("退出 Codex Touch Bar", #selector(quit))
        if let event = NSApp.currentEvent, let view = statusItem.button { NSMenu.popUpContextMenu(menu, with: event, for: view) }
        else { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
    @objc private func toggleLaunchDisplay() { defaults.set(!defaults.bool(forKey: "showOnLaunch"), forKey: "showOnLaunch") }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法更新登录启动设置"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func verifyPersistence(to path: String) {
        let selectedID = barDetail.taskID
        let originalMode = barDetail.navigation.mode
        // Simulates a system dismissal, not the user's explicit Hide control.
        CTBDismiss(touchBar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let checks: [String: Any] = ["visibleAfterDismissal": self.touchBar.isVisible, "sameTask": self.barDetail.taskID == selectedID, "samePageMode": self.barDetail.navigation.mode == originalMode, "recoveries": self.persistence?.recoveries ?? 0, "pinned": self.persistence?.policy.pinned ?? false]
            try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
    func verifyVoice(to directory: String) {
        enterBarTask()
        guard let task = selected else { return }
        let originalID = barDetail.taskID
        voice.preview(task: task, phase: .listening)
        var checks: [String: Bool] = ["recordingUIHasStop": dashboard.detail.map { BarDetailRenderer.regions($0, width: dashboard.bounds.width).contains { $0.action == .voiceStop } } ?? false, "noSendWhileRecording": dashboard.detail?.canSend == false]
        _ = renderPreview(to: directory + "/voice-recording-v6.png", bar: true)
        voice.preview(task: task, phase: .review)
        checks["reviewHasSend"] = dashboard.detail?.canSend == true
        _ = renderPreview(to: directory + "/voice-review-v6.png", bar: true)
        tapBar(.voiceCancel)
        checks["cancelReturnsToSameTask"] = barDetail.taskID == originalID && dashboard.detail?.voice == nil
        checks["noScreenPopup"] = !popover.isShown
        checks["taskPageHasMic"] = dashboard.detail.map { BarDetailRenderer.regions($0, width: dashboard.bounds.width).contains { $0.action == .voice } } ?? false
        try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: directory + "/voice-interaction-v6.json"))
        print(checks)
    }
    func verifyOverview(to directory: String) {
        guard rendering, demo else { return }
        dashboard.frame = NSRect(x: 0, y: 0, width: CTBDisplayWidth(), height: 30)
        var checks: [String: Bool] = [:]
        for index in 0..<2 {
            dashboard.performTap(at: dashboard.taskPoint(index))
            checks["task\(index + 1)OpensSteps"] = barDetail.taskID == tasks[index].id
            tapBar(.back)
            dashboard.performTap(at: dashboard.voicePoint())
            checks["homeMicTargetsTask\(index + 1)"] = voice.targetTaskID == tasks[index].id && dashboard.detail?.voice != nil
            checks["homeMicDoesNotOpenScreen\(index + 1)"] = !popover.isShown
            tapBar(.voiceCancel)
            checks["cancelReturnsToTask\(index + 1)"] = barDetail.taskID == tasks[index].id && dashboard.detail?.voice == nil
            if let snapshot = dashboard.detail, let region = BarDetailRenderer.regions(snapshot, width: dashboard.bounds.width).first(where: { $0.action == .voice }) {
                dashboard.performTap(at: NSPoint(x: region.rect.maxX - 2, y: region.rect.midY))
                checks["detailMicWideEdge\(index + 1)"] = region.rect.width == 68 && voice.targetTaskID == tasks[index].id && dashboard.detail?.voice != nil
                tapBar(.voiceCancel)
            }
            tapBar(.back)
            let mic = dashboard.voicePoint()
            dashboard.performTap(at: NSPoint(x: mic.x + 34, y: mic.y))
            checks["homeMicWideRightEdge\(index + 1)"] = voice.targetTaskID == tasks[index].id && dashboard.detail?.voice != nil
            tapBar(.voiceCancel); tapBar(.back)
            dashboard.performTap(at: NSPoint(x: mic.x - 34, y: mic.y))
            checks["homeMicWideLeftEdge\(index + 1)"] = voice.targetTaskID == tasks[index].id && dashboard.detail?.voice != nil
            tapBar(.voiceCancel); tapBar(.back)
        }
        fixedID = nil; refreshTouchBar()
        let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: directory + "/overview-interaction.json"))
        print(checks)
    }
    func verifyVoiceEditor(to directory: String) {
        previewVoice(listening: false)
        let checks = voice.verifyEditor(to: directory)
        try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: directory + "/voice-editor.json"))
        print(checks)
    }
    func previewVoice(listening: Bool) {
        enterBarTask()
        guard let task = selected else { return }
        voice.preview(task: task, phase: listening ? .listening : .review)
    }
    func enterBarTask() {
        if dashboard.bounds.width < 100 { dashboard.frame = NSRect(x: 0, y: 0, width: CTBDisplayWidth(), height: 30) }
        dashboard.performTap(at: dashboard.taskPoint(0))
    }
    private func tapBar(_ action: BarDetailAction) {
        guard let snapshot = dashboard.detail,
              let region = BarDetailRenderer.regions(snapshot, width: dashboard.bounds.width).first(where: { $0.action == action }) else { return }
        dashboard.performTap(at: NSPoint(x: region.rect.midX, y: region.rect.midY))
    }
    func openBarStep() {
        guard dashboard.detail != nil else { return }
        // Pick a recorded step when verifying content; user taps use the exact card id.
        for _ in 0..<4 {
            if let step = dashboard.detail?.steps.last(where: { $0.offset != nil }) { tapBar(.step(step.id)); return }
            tapBar(.previous)
        }
        if let step = dashboard.detail?.steps.first { tapBar(.step(step.id)) }
    }
    func verifyBarWhenReady(to directory: String, deadline: Date = Date().addingTimeInterval(8)) {
        if tasks.isEmpty && Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.verifyBarWhenReady(to: directory, deadline: deadline) }
            return
        }
        verifyBar(to: directory)
    }
    func verifyBar(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        enterBarTask()
        let unicode = String(repeating: "中文 👨‍👩‍👧‍👦 e\u{301} 状态与命令输出 \n", count: 12)
        let pager = BarTextPager(unicode, width: 110)
        var flattened = ""; var p = 0
        repeat { flattened += pager.lines(p).joined(); p += 1 } while pager.hasNext(p - 1) && p < 1000
        var checks: [String: Bool] = ["unicodePagingLossless": flattened == unicode.replacingOccurrences(of: "\n", with: ""), "taskTapEntersTouchBarSteps": dashboard.detail?.content == false, "noScreenPopupOnTaskTap": !popover.isShown]
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            checks["stepsRendered"] = self.renderPreview(to: directory + "/touchbar-steps-v5.png", bar: true)
            self.openBarStep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                checks["stepTapEntersTouchBarContent"] = self.dashboard.detail?.content == true
                checks["contentLoaded"] = self.dashboard.detail?.lines.first != "正在读取步骤内容…"
                checks["noScreenPopupOnStepTap"] = !self.popover.isShown
                checks["contentRendered"] = self.renderPreview(to: directory + "/touchbar-content-v5.png", bar: true)
                let first = self.dashboard.detail?.lines
                self.tapBar(.next)
                checks["contentNextPage"] = self.dashboard.detail?.page == 1 && self.dashboard.detail?.lines != first
                _ = self.renderPreview(to: directory + "/touchbar-content-page2-v5.png", bar: true)
                self.tapBar(.previous)
                checks["contentPreviousPage"] = self.dashboard.detail?.page == 0
                self.tapBar(.back)
                checks["backToSteps"] = self.dashboard.detail?.content == false
                let start = self.dashboard.detail?.firstIndex ?? 0
                self.tapBar(.previous)
                checks["earlierSteps"] = (self.dashboard.detail?.firstIndex ?? 0) < start
                self.tapBar(.latest)
                checks["latestSteps"] = self.dashboard.detail?.next == false
                self.tapBar(.back)
                checks["backToOverview"] = self.dashboard.detail == nil && self.barDetail.taskID == nil
                checks["noImplicitScreenPopup"] = !self.popover.isShown
                let text = String(decoding: (try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
                try? text.write(toFile: directory + "/touchbar-interaction-v5.json", atomically: true, encoding: .utf8)
                print(text)
            }
        }
    }

    func verifyInspector() {
        inspector.verifyInteractions { result in
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("Inspector verification: " + text) }
        }
    }
    func expandInspectorPreview(image: Bool = false) { inspector.expandForPreview(image: image) }

    func verifyMenu(to directory: String) {
        guard demo, rendering else { return }
        var checks: [String: Any] = [:]
        checks["initialHistoryDoesNotBadge"] = completions.unread.isEmpty
        var live = tasks; live[0].status = .completed
        receive(live, "演示数据")
        checks["completionBadged"] = completions.unread == [live[0].id] && lastBadgeCount == 1
        receive(live, "演示数据")
        checks["duplicateDoesNotIncrement"] = completions.unread.count == 1
        checks["colorArtwork"] = statusItem.button?.image?.isTemplate == false && statusItem.button?.title == ""
        if let image = statusItem.button?.image, let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory + "/menu-icon-badge.png"))
        }
        updateDetails()
        checks["completionEntry"] = completedButton.isEnabled && completedButton.title.contains("1 个任务")
        completedButton.performClick(nil)
        checks["clickOpensAndAcknowledges"] = selected?.id == live[0].id && completions.unread.isEmpty && lastBadgeCount == 0
        checks["themeSurface"] = menuPalette.settings.surface
        checks["themeInk"] = menuPalette.settings.ink
        checks["themeAccent"] = menuPalette.settings.accent
        checks["uiFont"] = taskTitle.font?.fontName ?? "unknown"
        checks["appearance"] = popover.appearance?.name.rawValue ?? "unknown"
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: directory + "/menu-verification.json"))
        }
    }

    // Render only our own view for layout verification; no desktop capture or permissions.
    func renderPreview(to path: String, bar: Bool = false) -> Bool {
        let view: NSView
        if bar {
            let preview = DashboardView(frame: NSRect(x: 0, y: 0, width: CTBDisplayWidth(), height: 30))
            preview.update(tasks: tasks, usage: usage, tokens: tokenSummary, selectedID: selected?.id, quotaState: quotaState); preview.detail = dashboard.detail; view = preview
        } else { updateDetails(); view = popover.contentViewController!.view }
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = bar ? NSAppearance(named: .darkAqua) : menuPalette.appearance
        window.contentView = view
        view.appearance = window.appearance
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }
}

final class PanelBackground: NSView {
    var fillColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill(); dirtyRect.fill()
    }
}
