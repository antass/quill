import Foundation

enum FeedError: LocalizedError {
    case badStatus(Int)
    case notAFeed
    case noFeedFound(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Server returned \(code)"
        case .notAFeed:            return "That URL isn't a readable RSS or Atom feed"
        case .noFeedFound(let host): return "No feed found on \(host)"
        }
    }
}

struct FeedService {

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.timeoutIntervalForRequest = 25
        config.httpAdditionalHeaders = [
            // Some publishers (NYT, a few Substacks) reject the default URLSession agent.
            "User-Agent": "Quill/1.0 (macOS RSS reader)",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, text/html;q=0.8"
        ]
        return URLSession(configuration: config)
    }()

    // MARK: Fetch

    static func fetch(_ feed: Feed) async throws -> (ParsedFeed, [Article]) {
        let (data, response) = try await session.data(from: feed.feedURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.badStatus(http.statusCode)
        }
        guard let parsed = FeedParser.parse(data: data), !parsed.items.isEmpty else {
            throw FeedError.notAFeed
        }
        let articles = parsed.items.compactMap { makeArticle($0, feedID: feed.id, feedURL: feed.feedURL) }
        return (parsed, articles)
    }

    static func makeArticle(_ item: ParsedItem, feedID: UUID, feedURL: URL) -> Article? {
        let title = (item.title.map { HTMLText.plain($0, limit: 300) } ?? "").isEmpty
            ? "(untitled)" : HTMLText.plain(item.title!, limit: 300)

        let link = item.link.flatMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: trimmed), u.scheme != nil { return u }
            return URL(string: trimmed, relativeTo: feedURL)?.absoluteURL
        }

        let body = item.contentHTML ?? item.summaryHTML ?? ""
        // Scope the key to the feed so two publications sharing a guid never collide.
        let raw = item.guid ?? link?.absoluteString ?? "\(title)|\(item.dateString ?? "")"
        guard !raw.isEmpty else { return nil }
        let key = "\(feedID.uuidString)|\(raw)"

        let image = item.imageURL ?? HTMLText.firstImage(in: body)

        let categories = Array(Set(item.categories.map { HTMLText.plain($0, limit: 80) }))
            .filter { !$0.isEmpty }
            .sorted()

        var article = Article(
            id: key,
            feedID: feedID,
            title: title,
            link: link,
            author: item.author.map { HTMLText.plain($0, limit: 120) },
            published: FeedDate.parse(item.dateString),
            summary: HTMLText.plain(item.summaryHTML ?? body, limit: 320),
            contentHTML: body,
            imageURL: image.flatMap { URL(string: $0) }
        )
        article.categories = categories
        return article
    }

    // MARK: Discovery — accept a feed URL *or* a plain site URL

    static func discover(from input: String) async throws -> (feedURL: URL, parsed: ParsedFeed) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("feed://") { text = "https://" + text.dropFirst("feed://".count) }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host else { throw FeedError.notAFeed }

        // 1. Maybe it already is a feed.
        if let parsed = try? await load(url), !parsed.items.isEmpty {
            return (url, parsed)
        }

        // 2. Look for <link rel="alternate"> in the HTML.
        if let html = try? await loadString(url) {
            for candidate in feedLinks(inHTML: html, base: url) {
                if let parsed = try? await load(candidate), !parsed.items.isEmpty {
                    return (candidate, parsed)
                }
            }
        }

        // 3. Fall back to the conventional paths (covers most Substacks and blogs).
        let root = URL(string: "\(url.scheme ?? "https")://\(host)")!
        for path in ["/feed", "/rss", "/feed.xml", "/rss.xml", "/index.xml", "/atom.xml", "/feeds/posts/default"] {
            let candidate = root.appendingPathComponent(path)
            if let parsed = try? await load(candidate), !parsed.items.isEmpty {
                return (candidate, parsed)
            }
        }

        throw FeedError.noFeedFound(host)
    }

    private static func load(_ url: URL) async throws -> ParsedFeed? {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.badStatus(http.statusCode)
        }
        return FeedParser.parse(data: data)
    }

    private static func loadString(_ url: URL) async throws -> String {
        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func feedLinks(inHTML html: String, base: URL) -> [URL] {
        var results: [URL] = []
        let pattern = "<link[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let lower = tag.lowercased()
            guard lower.contains("alternate"),
                  lower.contains("rss+xml") || lower.contains("atom+xml") else { continue }
            guard let hrefRange = tag.range(of: "href=[\"']([^\"']+)[\"']",
                                            options: [.regularExpression, .caseInsensitive]) else { continue }
            let href = String(tag[hrefRange])
                .replacingOccurrences(of: "href=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let u = URL(string: href, relativeTo: base)?.absoluteURL { results.append(u) }
        }
        return results
    }
}
