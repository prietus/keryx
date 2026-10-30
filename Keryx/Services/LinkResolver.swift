import Foundation

/// What a URL in a message turned out to be: an image to show as a
/// thumbnail, or a page to preview as a card.
struct LinkInfo: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case image, page, other }
    var url: URL
    var kind: Kind
    var title: String?
    var site: String?
    /// For a page that is just a wrapper around an image (paste sites).
    var imageURL: URL?
    /// The page's summary (`og:description`, `twitter:description`, `description`).
    var summary: String?
    /// The page's own picture (`og:image`), shown small in its card.
    var thumbnail: URL?
}

enum MessageLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "tiff"]

    /// http(s) URLs in `text`, with their ranges.
    static func detect(in text: String) -> [(url: URL, range: Range<String.Index>)] {
        guard text.contains("."), let detector else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: ns).compactMap { match in
            guard let url = match.url, url.scheme == "http" || url.scheme == "https",
                  let range = Range(match.range, in: text) else { return nil }
            // The detector turns any bare hostname into https://…; on IRC those
            // are server names and hosts, not links. Only what was written as one.
            let written = text[range].lowercased()
            guard written.hasPrefix("http://") || written.hasPrefix("https://") || written.hasPrefix("www.") else { return nil }
            return (url, range)
        }
    }
}

/// Resolves links by content type, not extension (extension-less CDN links
/// work), and reads `<title>` / OpenGraph from the first bytes of a page.
/// Results are cached for the session.
actor LinkResolver {
    static let shared = LinkResolver()

    private var cache: [URL: LinkInfo] = [:]
    private var inFlight: [URL: Task<LinkInfo, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) Keryx/0.1 (link preview)"]
        return URLSession(configuration: config)
    }()

    /// Hosts whose pages are always image wrappers: the user's own uploader
    /// and the networks' file hosts. Kept current by the app model.
    private(set) var wrapperHosts: Set<String> = []

    func setWrapperHosts(_ hosts: Set<String>) { wrapperHosts = Set(hosts.map { $0.lowercased() }) }

    func resolve(_ url: URL) async -> LinkInfo {
        if let cached = cache[url] { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task { await fetch(url) }
        inFlight[url] = task
        let info = await task.value
        cache[url] = info
        inFlight[url] = nil
        return info
    }

    private func fetch(_ url: URL) async -> LinkInfo {
        if MessageLinks.imageExtensions.contains(url.pathExtension.lowercased()) {
            return LinkInfo(url: url, kind: .image)
        }
        guard let (data, http) = await head(url, limit: 65_536) else {
            return LinkInfo(url: url, kind: .other, site: url.host())
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let final = http.url ?? url
        if type.hasPrefix("image/") || (Self.isUntyped(type) && Self.looksLikeImage(data)) {
            return LinkInfo(url: final, kind: .image)
        }
        guard type.contains("html") else { return LinkInfo(url: url, kind: .other, site: url.host()) }

        let html = String(decoding: data, as: UTF8.self)
        let pageTitle = Self.title(in: html)
        let title = Self.meta("og:title", in: html) ?? Self.meta("twitter:title", in: html) ?? pageTitle
        let site = Self.meta("og:site_name", in: html) ?? url.host()
        let ogImage = (Self.meta("og:image", in: html) ?? Self.meta("twitter:image", in: html)
            ?? Self.meta("twitter:image:src", in: html))
            .flatMap { URL(string: $0, relativeTo: final)?.absoluteURL }
        let hasMetadata = html.range(of: #"(property|name)\s*=\s*["'](og|twitter):"#, options: .regularExpression) != nil

        // Image-wrapper pages — paste sites, file viewers, your own uploader —
        // are pages around one picture. Show the picture, not a sparse card.
        let host = final.host()?.lowercased() ?? ""
        let isWrapper = wrapperHosts.contains(host)
            || (!hasMetadata && (pageTitle ?? "").isEmpty)
            || pageTitle.map(Self.titleNamesImage) == true
            || Self.meta("twitter:card", in: html)?.lowercased() == "photo"
            || Self.meta("og:type", in: html)?.lowercased().hasPrefix("image") == true
        if isWrapper {
            for candidate in [ogImage, Self.firstImage(in: html, base: final)].compactMap({ $0 }) {
                if await isImage(candidate) {
                    return LinkInfo(url: candidate, kind: .image, title: title.map(Self.decodeEntities), site: site)
                }
            }
        }
        let summary = (Self.meta("og:description", in: html) ?? Self.meta("twitter:description", in: html)
            ?? Self.meta("description", in: html))
            .map { Self.decodeEntities($0).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .map { $0.count > 220 ? String($0.prefix(217)) + "…" : $0 }
        return LinkInfo(url: url, kind: .page, title: title.map(Self.decodeEntities), site: site,
                        summary: summary, thumbnail: ogImage)
    }

    /// GETs the first `limit` bytes of `url`.
    private func head(_ url: URL, limit: Int) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {}
        return (data, http)
    }

    /// Whether `url` really serves an image (by type, or by its first bytes).
    private func isImage(_ url: URL) async -> Bool {
        if MessageLinks.imageExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let (data, http) = await head(url, limit: 32) else { return false }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return type.hasPrefix("image/") || (Self.isUntyped(type) && Self.looksLikeImage(data))
    }

    private static func isUntyped(_ type: String) -> Bool {
        type.isEmpty || type.hasPrefix("application/octet-stream") || type.hasPrefix("text/plain")
            || type.hasPrefix("binary/")
    }

    /// PNG, JPEG, GIF, WebP, HEIC/AVIF, BMP, TIFF by their magic numbers.
    static func looksLikeImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        func starts(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8))
            || starts(Array("BM".utf8)) || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) {
            return true
        }
        if b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) { return true }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return ["heic", "heix", "mif1", "avif", "avis"].contains(brand)
        }
        return false
    }

    /// "Screenshot 2026-10-29.png — paste" is an image page, not an article.
    static func titleNamesImage(_ title: String) -> Bool {
        title.range(of: #"\.(png|jpe?g|gif|webp|heic|avif|bmp|tiff?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first `<img src>` in the page, resolved against it.
    static func firstImage(in html: String, base: URL) -> URL? {
        firstCapture(#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: html)
            .flatMap { URL(string: decodeEntities($0), relativeTo: base)?.absoluteURL }
    }

    static func meta(_ property: String, in html: String) -> String? {
        let p = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            #"<meta[^>]+(?:property|name)\s*=\s*["']"# + p + #"["'][^>]*content\s*=\s*["']([^"']*)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']"# + p + #"["']"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: html), !value.isEmpty { return value }
        }
        return nil
    }

    static func title(in html: String) -> String? {
        firstCapture(#"<title[^>]*>([^<]*)</title>"#, in: html)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                               "&#x27;": "'", "&apos;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
