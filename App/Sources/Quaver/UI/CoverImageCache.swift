import AppKit

// MARK: - CoverImageCache
// Shared in-memory cache for cover_data_url base64 → NSImage.
// Used by Library cells, PlayerBar, Lyrics, Queue, NowPlaying.
// Base64 decode + NSImage(data:) is 0.5–2ms per call; for a 483-row
// list scrolling at 60fps that's ~30ms/frame if decoded per reuse.
// Caching makes reuse O(1). NSCache evicts under pressure; countLimit 300 bounds memory.

enum CoverImageCache {

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        c.totalCostLimit = 120 * 1024 * 1024 // ~120MB
        return c
    }()

    static func image(fromDataURL url: String) -> NSImage? {
        if url.isEmpty { return nil }
        if let cached = cache.object(forKey: url as NSString) { return cached }
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let b64 = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSString)
        return img
    }

    static func clear() { cache.removeAllObjects() }
}
