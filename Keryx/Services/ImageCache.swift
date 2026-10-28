import AppKit

/// Downloaded images, kept in memory so scrolling doesn't fetch them again.
/// Capped by cost (decoded bytes); NSCache evicts under memory pressure too.
actor ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    /// Images bigger than this aren't downloaded for an inline preview.
    private let maxBytes = 15 * 1024 * 1024

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inFlight[url] { return await task.value }
        let limit = maxBytes
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count <= limit else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let rep = image.representations.first
            let cost = (rep?.pixelsWide ?? 256) * (rep?.pixelsHigh ?? 256) * 4
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }
}
