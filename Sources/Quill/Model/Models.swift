import Foundation

// MARK: - Feed

struct Feed: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var feedURL: URL
    var siteURL: URL?
    var folder: String
    var iconName: String?
    var lastFetched: Date?
    var lastError: String?

    init(id: UUID = UUID(),
         title: String,
         feedURL: URL,
         siteURL: URL? = nil,
         folder: String = "Feeds",
         iconName: String? = nil) {
        self.id = id
        self.title = title
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.folder = folder
        self.iconName = iconName
    }

    // Every field beyond the identity is optional on the way in, so a library written by an
    // older (or newer) build still loads instead of silently resetting the app.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled feed"
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        siteURL = try c.decodeIfPresent(URL.self, forKey: .siteURL)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? "Feeds"
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
        lastFetched = try c.decodeIfPresent(Date.self, forKey: .lastFetched)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}


// MARK: - Article

struct Article: Identifiable, Codable, Hashable {
    var id: String              // stable key: guid, else link, else hash(title+date)
    var feedID: UUID
    var title: String
    var link: URL?
    var author: String?
    var published: Date?
    var summary: String         // plain-text snippet for the list
    var contentHTML: String     // best available body HTML
    var imageURL: URL?
    var isRead: Bool = false
    var isStarred: Bool = false
    var notionPageURL: String?
    var firstSeen: Date = Date()

    /// Article body pulled from the publisher's own page, when the feed carries only a stub.
    var fullContentHTML: String?
    var fullTextError: String?

    /// Raw category strings as the publisher supplied them.
    var categories: [String] = []
    /// Tags applied by hand; these always show in the sidebar, unmapped.
    var tags: [String] = []
    /// Canonical topics, cached so the sidebar isn't reclassifying on every redraw.
    var derivedTopics: [String] = []
    /// Classifier version these topics came from, so rule changes can force a recompute.
    var topicsVersion: Int = 0

    var savedToNotion: Bool { notionPageURL != nil }
    var hasFullText: Bool { !(fullContentHTML ?? "").isEmpty }

    /// Readable characters the feed itself supplied.
    var feedTextLength: Int { HTMLText.plain(contentHTML, limit: Int.max).count }

    /// Feeds that publish only a teaser are the ones worth fetching in full.
    var feedIsThin: Bool { feedTextLength < 1500 }

    /// What the sidebar groups by: hand-applied tags first, then derived topics.
    var topics: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags + derivedTopics {
            let key = tag.lowercased()
            if !seen.contains(key), !tag.isEmpty { seen.insert(key); out.append(tag) }
        }
        return out
    }

    func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        feedID = try c.decode(UUID.self, forKey: .feedID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(untitled)"
        link = try c.decodeIfPresent(URL.self, forKey: .link)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        published = try c.decodeIfPresent(Date.self, forKey: .published)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        contentHTML = try c.decodeIfPresent(String.self, forKey: .contentHTML) ?? ""
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isStarred = try c.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        notionPageURL = try c.decodeIfPresent(String.self, forKey: .notionPageURL)
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? Date()
        fullContentHTML = try c.decodeIfPresent(String.self, forKey: .fullContentHTML)
        fullTextError = try c.decodeIfPresent(String.self, forKey: .fullTextError)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        derivedTopics = try c.decodeIfPresent([String].self, forKey: .derivedTopics) ?? []
        topicsVersion = try c.decodeIfPresent(Int.self, forKey: .topicsVersion) ?? 0
    }

    init(id: String, feedID: UUID, title: String, link: URL?, author: String?,
         published: Date?, summary: String, contentHTML: String, imageURL: URL?) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.link = link
        self.author = author
        self.published = published
        self.summary = summary
        self.contentHTML = contentHTML
        self.imageURL = imageURL
    }


    var displayDate: Date { published ?? firstSeen }
}

// MARK: - Sidebar selection

enum SidebarSelection: Hashable {
    case all
    case unread
    case starred
    case savedToNotion
    case feed(UUID)
    case folder(String)
    case topic(String)
}

// MARK: - Sort / filter

enum ArticleSort: String, CaseIterable, Codable {
    case newestFirst = "Newest first"
    case oldestFirst = "Oldest first"
}
