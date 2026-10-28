import AppKit
import MonitorCore

/// Passive screen feedback; never takes keyboard focus or intercepts clicks.
final class ControlHUD {
    private var panel: NSPanel?
    private let content = ControlHUDContent(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
    private var dismissal: DispatchWorkItem?
    var isVisible: Bool { panel?.isVisible == true }

    func show(_ feedback: SystemControlFeedback) {
        dismissal?.cancel()
        content.feedback = feedback
        if panel == nil {
            let window = NSPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            let background = NSVisualEffectView(frame: content.bounds)
            background.material = .hudWindow
            background.state = .active
            background.blendingMode = .behindWindow
            background.appearance = NSAppearance(named: .darkAqua)
            background.wantsLayer = true
            background.layer?.cornerRadius = 20
            background.layer?.masksToBounds = true
            background.addSubview(content)
            window.contentView = background
            panel = window
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: area.midX - content.bounds.width / 2, y: area.minY + 80))
        }
        panel?.orderFrontRegardless()
    }

    func finish() {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }

    func renderPreview(to url: URL) -> Bool {
        guard let view = panel?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
}

private final class ControlHUDContent: NSView {
    var feedback: SystemControlFeedback? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let feedback else { return }
        let volume = feedback.control == .volume
        let symbol = volume ? (feedback.fraction == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") : "sun.max.fill"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: volume ? "音量" : "亮度")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])
                .applying(NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)))
        icon?.draw(in: NSRect(x: 24, y: 48, width: 28, height: 28))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let title = feedback.fraction == nil ? feedback.message : (volume ? "音量" : "亮度")
        (title as NSString).draw(in: NSRect(x: 66, y: feedback.fraction == nil ? 35 : 48,
                                               width: feedback.fraction == nil ? 230 : 160,
                                               height: feedback.fraction == nil ? 46 : 26), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        if let fraction = feedback.fraction {
            let number = "\(Int((fraction * 100).rounded()))%"
            let right = NSMutableParagraphStyle(); right.alignment = .right
            (number as NSString).draw(in: NSRect(x: 222, y: 48, width: 74, height: 26), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: right])
            let track = NSRect(x: 24, y: 24, width: 272, height: 7)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
            if fraction > 0 {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: track.height), xRadius: 3.5, yRadius: 3.5).fill()
            }
        }
    }
}
