import Foundation

/// Result of parsing a feed document.
struct ParsedFeed {
    var title: String?
    var siteURL: URL?
    var items: [ParsedItem] = []
}

struct ParsedItem {
    var guid: String?
    var title: String?
    var link: String?
    var author: String?
    var dateString: String?
    var summaryHTML: String?
    var contentHTML: String?
    var imageURL: String?
    var categories: [String] = []
}

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom with a single XMLParser pass.
final class FeedParser: NSObject, XMLParserDelegate {

    private var feed = ParsedFeed()
    private var current: ParsedItem?
    private var path: [String] = []
    private var buffer = ""
    private var inItem = false
    /// Atom feeds carry both a site link and per-entry links; track which we captured.
    private var feedLinkCaptured = false

    static func parse(data: Data) -> ParsedFeed? {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse() else {
            // Some publishers emit a stray byte before the prolog; retry from the first '<'.
            if let idx = data.firstIndex(of: UInt8(ascii: "<")), idx > 0 {
                let retry = FeedParser()
                let xml2 = XMLParser(data: data.subdata(in: idx..<data.endIndex))
                xml2.delegate = retry
                xml2.shouldProcessNamespaces = false
                if xml2.parse() { return retry.feed }
            }
            return parser.feed.items.isEmpty ? nil : parser.feed
        }
        return parser.feed
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {

        let name = elementName.lowercased()
        path.append(name)
        buffer = ""

        switch name {
        case "item", "entry":
            inItem = true
            current = ParsedItem()

        case "link":
            // Atom uses <link href="..." rel="..."/>; RSS puts the URL in the text node.
            if let href = attributeDict["href"] {
                let rel = attributeDict["rel"] ?? "alternate"
                let type = attributeDict["type"] ?? "text/html"
                guard rel == "alternate", type.contains("html") || type == "text/html" else { break }
                if inItem {
                    if current?.link == nil { current?.link = href }
                } else if !feedLinkCaptured {
                    feed.siteURL = URL(string: href)
                    feedLinkCaptured = true
                }
            }

        case "category":
            // Atom puts the label in an attribute; RSS puts it in the text node.
            if inItem, let term = attributeDict["term"] ?? attributeDict["label"] {
                let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { current?.categories.append(clean) }
            }

        case "enclosure":
            if inItem, current?.imageURL == nil,
               let url = attributeDict["url"],
               (attributeDict["type"] ?? "").hasPrefix("image") {
                current?.imageURL = url
            }

        case "media:content", "media:thumbnail":
            if inItem, let url = attributeDict["url"] {
                let type = attributeDict["type"] ?? attributeDict["medium"] ?? "image"
                if type.contains("image"), current?.imageURL == nil { current?.imageURL = url }
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        let name = elementName.lowercased()
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !path.isEmpty { path.removeLast() }
            buffer = ""
        }

        // Ignore anything nested inside <image> or <author> wrappers we don't want.
        let insideChannelImage = path.dropLast().contains("image")

        if inItem {
            switch name {
            case "item", "entry":
                if var item = current {
                    if item.guid == nil { item.guid = item.link }
                    feed.items.append(item)
                }
                current = nil
                inItem = false
            case "title":
                if current?.title == nil || current?.title?.isEmpty == true { current?.title = text }
            case "link":
                if current?.link == nil, !text.isEmpty { current?.link = text }
            case "guid", "id":
                if current?.guid == nil, !text.isEmpty { current?.guid = text }
            case "pubdate", "published", "updated", "dc:date", "date":
                if current?.dateString == nil, !text.isEmpty { current?.dateString = text }
            case "author", "dc:creator", "creator":
                if current?.author == nil, !text.isEmpty { current?.author = text }
            case "name":
                // Atom: <author><name>…</name></author>
                if path.dropLast().contains("author"), current?.author == nil, !text.isEmpty {
                    current?.author = text
                }
            case "category":
                if !text.isEmpty, !(current?.categories.contains(text) ?? false) {
                    current?.categories.append(text)
                }
            case "description", "summary", "subtitle":
                if current?.summaryHTML == nil, !text.isEmpty { current?.summaryHTML = text }
            case "content", "content:encoded", "encoded":
                if !text.isEmpty { current?.contentHTML = text }
            default:
                break
            }
        } else {
            switch name {
            case "title":
                if feed.title == nil, !text.isEmpty, !insideChannelImage { feed.title = text }
            case "link":
                if feed.siteURL == nil, !text.isEmpty, !insideChannelImage {
                    feed.siteURL = URL(string: text)
                }
            default:
                break
            }
        }
    }
}

// MARK: - Date parsing

enum FeedDate {
    private static let formatters: [DateFormatter] = {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = pattern
            return f
        }
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let d = iso.date(from: raw) { return d }
        if let d = isoPlain.date(from: raw) { return d }
        for f in formatters {
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }
}

// MARK: - HTML helpers

enum HTMLText {
    /// Strip tags and decode the entities that actually show up in feeds.
    static func plain(_ html: String, limit: Int = 400) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br[^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: " ", options: [.caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&mdash;": "\u{2014}",
            "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&#8217;": "\u{2019}"
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        return s
    }

    /// First <img src> in a body, used when the feed has no media element.
    static func firstImage(in html: String) -> String? {
        guard let match = html.range(of: "<img[^>]+src=[\"']([^\"']+)[\"']",
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(html[match])
        guard let srcRange = tag.range(of: "src=[\"']([^\"']+)[\"']",
                                       options: [.regularExpression, .caseInsensitive]) else { return nil }
        let src = String(tag[srcRange])
            .replacingOccurrences(of: "src=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return src.hasPrefix("http") ? src : nil
    }
}
