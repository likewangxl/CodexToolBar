import AppKit
import MonitorCore

/// Small native vector badges inspired by the user's Codex reference. These are
/// drawn locally, with stable identity colors, and are not bundled Codex artwork.
enum ActivityIcons {
    private static var cache: [Int: NSImage] = [:]
    static func badge(_ style: Int) -> NSImage {
        if let image = cache[style] { return image }
        let colors: [NSColor] = [.init(srgbRed: 0.73, green: 0.62, blue: 0.91, alpha: 1), .init(srgbRed: 0.55, green: 0.87, blue: 0.44, alpha: 1), .init(srgbRed: 1, green: 0.80, blue: 0.24, alpha: 1), .init(srgbRed: 0.35, green: 0.65, blue: 1, alpha: 1), .init(srgbRed: 1, green: 0.45, blue: 0.49, alpha: 1), .init(srgbRed: 0.36, green: 0.84, blue: 0.69, alpha: 1)]
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let color = colors[style % colors.count]
            if style == 0 {
                for x in [5.0, 11.0] { color.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 2.3, height: 14), xRadius: 1, yRadius: 1).fill() }
                for y in [5.0, 11.0] { color.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: NSRect(x: 2, y: y, width: 14, height: 2.3), xRadius: 1, yRadius: 1).fill() }
            } else if style == 1 || style == 2 {
                for i in 0..<8 {
                    NSGraphicsContext.saveGraphicsState()
                    let transform = NSAffineTransform(); transform.translateX(by: 9, yBy: 9)
                    transform.rotate(byDegrees: CGFloat(i) * 45); transform.concat()
                    color.withAlphaComponent(i % 2 == 0 ? 1 : 0.68).setFill()
                    let path = NSBezierPath()
                    if style == 1 { path.move(to: NSPoint(x: 0.7, y: 0.7)); path.line(to: NSPoint(x: 7.5, y: 0.7)); path.line(to: NSPoint(x: 4.6, y: 4.1)); path.close() }
                    else { path.appendRoundedRect(NSRect(x: 2.6, y: -1, width: 5.6, height: 2), xRadius: 0.8, yRadius: 0.8) }
                    path.fill(); NSGraphicsContext.restoreGraphicsState()
                }
            } else if style == 5 {
                for i in 0..<3 {
                    let radius = CGFloat(15 - i * 4)
                    color.withAlphaComponent(0.55 + Double(i) * 0.15).setFill()
                    let oval = NSBezierPath(ovalIn: NSRect(x: (18 - radius) / 2, y: CGFloat(1 + i), width: radius, height: radius))
                    oval.fill(); NSColor.white.withAlphaComponent(0.35).setStroke(); oval.lineWidth = 0.5; oval.stroke()
                }
            } else {
                let petals = style == 3 ? 4 : 6
                for i in 0..<petals {
                    let angle = Double(i) * 2 * .pi / Double(petals)
                    let x = 9 + cos(angle) * 4.2, y = 9 + sin(angle) * 4.2
                    color.withAlphaComponent(i % 2 == 0 ? 0.95 : 0.67).setFill()
                    let radius = style == 3 ? 3.7 : 2.8
                    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
                }
            }
            return true
        }
        image.isTemplate = false; cache[style] = image
        return image
    }
    static func attributed(_ activity: Activity, fontSize: CGFloat = 12, color: NSColor = .labelColor, limit: Int = 48, font: NSFont? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let icons: [NSImage] = activity.agents.isEmpty ? [NSImage(systemSymbolName: activity.symbol, accessibilityDescription: activity.label) ?? NSImage()] : activity.agents.prefix(3).map { badge($0.style) }
        for image in icons {
            let attachment = NSTextAttachment(); attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            result.append(NSAttributedString(attachment: attachment)); result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: String(activity.label.prefix(limit)), attributes: [.font: font ?? NSFont.systemFont(ofSize: fontSize), .foregroundColor: color]))
        return result
    }
}
