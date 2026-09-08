import AppKit

/// An explicit, short-lived correction window. Changes never submit a message.
final class VoiceEditor: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let text = NSTextView()
    private let hint = NSTextField(labelWithString: "")
    private var onSave: ((String) -> Bool)?
    private var onCancel: (() -> Void)?
    func show(title: String, taskID: String, draft: String, save: @escaping (String) -> Bool, cancel: @escaping () -> Void) {
        dismiss()
        onSave = save; onCancel = cancel
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = PanelBackground(frame: NSRect(x: 0, y: 0, width: 600, height: 340))
        window.title = "修改语音文字"; window.minSize = NSSize(width: 480, height: 280); window.isReleasedWhenClosed = false; window.delegate = self
        let target = NSTextField(wrappingLabelWithString: "发送至：\(title)\n任务标识：…\(taskID.suffix(8))")
        target.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.stringValue = "保存后回到 Touch Bar 复核，点击“发送”才提交。"; hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false; text.isContinuousSpellCheckingEnabled = false
        text.font = .systemFont(ofSize: 14); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.minSize = NSSize(width: 0, height: 120); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame = NSRect(x: 0, y: 0, width: 564, height: 160)
        text.textContainer?.containerSize = NSSize(width: 564, height: CGFloat.greatestFiniteMagnitude)
        text.string = draft; scroll.documentView = text
        let cancelButton = NSButton(title: "取消修改", target: self, action: #selector(cancelTapped)); cancelButton.bezelStyle = .rounded; cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "保存并返回复核", target: self, action: #selector(saveTapped)); saveButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancelButton, saveButton]); buttons.spacing = 10
        let stack = NSStackView(views: [target, hint, scroll, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        guard let root = window.contentView else { return }
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120), target.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        self.window = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
    }
    @objc private func saveTapped() {
        guard text.string.utf8.count <= 32768, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hint.stringValue = "请输入非空文字，长度不超过 32 KiB。"; return
        }
        if onSave?(text.string) == true { onCancel = nil; dismiss() }
        else { hint.stringValue = "录音会话已改变，请关闭后重新打开编辑。" }
    }
    @objc private func cancelTapped() { dismiss() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func dismiss() {
        let callback = onCancel; onCancel = nil; onSave = nil
        window?.orderOut(nil); window?.delegate = nil; window?.close(); window = nil; text.string = ""
        callback?()
    }
    func render(to path: String) -> Bool {
        guard let view = window?.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }
    /// Calls the same Save action without any voice or network operation.
    func verifySave(_ value: String) { text.string = value; saveTapped() }
}
