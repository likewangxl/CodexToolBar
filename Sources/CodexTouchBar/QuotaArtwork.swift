import AppKit
import ImageIO

/// Decode once at 2x Touch Bar resolution. The full-size artwork is never kept
/// in the display loop, and no animation or extra refresh timer is introduced.
enum QuotaArtwork {
    static let image: NSImage? = {
        let url = Bundle.main.url(forResource: "QuotaIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "QuotaIcon", withExtension: "png")
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 44,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: thumbnail, size: NSSize(width: 22, height: 22))
        result.isTemplate = false
        return result
    }()
}
