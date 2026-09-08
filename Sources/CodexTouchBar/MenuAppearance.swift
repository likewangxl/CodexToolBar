import AppKit
import MonitorCore

struct MenuPalette {
    let settings: DesktopThemeSettings
    var appearance: NSAppearance? { NSAppearance(named: settings.dark ? .darkAqua : .aqua) }
    var background: NSColor { color(settings.surface) }
    var text: NSColor { color(settings.ink) }
    var accent: NSColor { color(settings.accent) }
    var secondary: NSColor { background.blended(withFraction: 0.65, of: text) ?? text }
    var inset: NSColor { background.blended(withFraction: settings.dark ? 0.08 : 0.035, of: text) ?? background }
    func font(_ size: CGFloat, weight: NSFont.Weight = .regular, code: Bool = false) -> NSFont {
        let name = code ? settings.codeFont : settings.uiFont
        let fallback = code ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard let name, let base = NSFont(name: name, size: size) ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) else { return fallback }
        return weight == .bold || weight == .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }
    private func color(_ hex: String) -> NSColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// Watch the parent directory so atomic config replacement keeps working. Reads
/// only while the panel is visible, or when explicitly opened; no polling timer.
final class MenuAppearance {
    var onChange: (() -> Void)?
    private let config: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stamp: Date?
    private var cachedText = ""
    init(home: URL) { config = home.appendingPathComponent("config.toml") }
    func read() -> MenuPalette {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let values = try? config.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if stamp != values?.contentModificationDate || stamp == nil {
            stamp = values?.contentModificationDate
            cachedText = (values?.fileSize ?? 0) <= 1_048_576 ? (try? String(contentsOf: config, encoding: .utf8)) ?? "" : ""
        }
        return MenuPalette(settings: DesktopThemeSettings(config: cachedText, systemDark: dark))
    }
    func start() {
        let fd = open(config.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }; self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange?() }
            self.pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }; watcher = source; source.resume()
    }
    deinit { pending?.cancel(); watcher?.cancel() }
}

/// Rasterized by AppKit only when the unread count changes, not per task event.
enum MenuArtwork {
    static func image(unread: Int) -> NSImage {
        let count = min(10, max(0, unread))
        let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { _ in
            let rect = NSRect(x: 0, y: 1, width: 20, height: 20)
            if let icon = QuotaArtwork.image { icon.draw(in: rect) }
            else { NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.draw(in: rect) }
            if count > 0 {
                let badge = NSRect(x: 15, y: 10, width: 13, height: 12)
                NSColor(srgbRed: 0.88, green: 0.15, blue: 0.28, alpha: 1).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
                let text = count > 9 ? "9+" : String(count)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: count > 9 ? 7 : 9, weight: .bold), .foregroundColor: NSColor.white]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = QuotaArtwork.image == nil && count == 0
        return image
    }
}
