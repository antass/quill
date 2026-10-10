import Foundation
import SwiftUI

struct AppSettings: Codable {
    var notionDatabaseID: String = ""
    var notionDatabaseTitle: String = ""
    var notionWorkspace: String = ""
    var refreshMinutes: Int = 30
    var sort: ArticleSort = .newestFirst
    var markReadOnOpen: Bool = true
    var defaultTags: [String] = []
    var defaultStatus: String = ""
    var keepPerFeed: Int = 200
    var autoLoadFullText: Bool = true
    var hasSeeded: Bool = false

    init() {}

    /// Missing keys fall back to defaults — adding a setting must never reset the library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notionDatabaseID = try c.decodeIfPresent(String.self, forKey: .notionDatabaseID) ?? ""
        notionDatabaseTitle = try c.decodeIfPresent(String.self, forKey: .notionDatabaseTitle) ?? ""
        notionWorkspace = try c.decodeIfPresent(String.self, forKey: .notionWorkspace) ?? ""
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 30
        sort = try c.decodeIfPresent(ArticleSort.self, forKey: .sort) ?? .newestFirst
        markReadOnOpen = try c.decodeIfPresent(Bool.self, forKey: .markReadOnOpen) ?? true
        defaultTags = try c.decodeIfPresent([String].self, forKey: .defaultTags) ?? []
        defaultStatus = try c.decodeIfPresent(String.self, forKey: .defaultStatus) ?? ""
        keepPerFeed = try c.decodeIfPresent(Int.self, forKey: .keepPerFeed) ?? 200
        autoLoadFullText = try c.decodeIfPresent(Bool.self, forKey: .autoLoadFullText) ?? true
        hasSeeded = try c.decodeIfPresent(Bool.self, forKey: .hasSeeded) ?? false
    }
}


private struct Library: Codable {
    var feeds: [Feed] = []
    var articles: [Article] = []
    var settings: AppSettings = AppSettings()

    init(feeds: [Feed], articles: [Article], settings: AppSettings) {
        self.feeds = feeds
        self.articles = articles
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try c.decodeIfPresent([Feed].self, forKey: .feeds) ?? []
        articles = try c.decodeIfPresent([Article].self, forKey: .articles) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

@MainActor
final class AppState: ObservableObject {

    @Published var feeds: [Feed] = []
    @Published var articles: [Article] = []
    @Published var settings = AppSettings() { didSet { scheduleSave() } }

    @Published var selection: SidebarSelection = .unread
    @Published var selectedArticleID: Article.ID?
    @Published var searchText = ""

    @Published var isRefreshing = false
    @Published var refreshProgress: String = ""
    @Published var banner: Banner?
    @Published var fullTextLoading: Set<Article.ID> = []
    private var loadFailure: String?

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, success, failure }
        var id = UUID()
        var kind: Kind
        var text: String
    }

    private var saveTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    // MARK: - Storage

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quill", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    init() {
        Diag.log("app.launch")
        TokenImport.importIfPresent()
        load()
        if !settings.hasSeeded && feeds.isEmpty {
            feeds = AppState.starterFeeds
            settings.hasSeeded = true
        }
        classifyMissingTopics()
        startTimer()
        if let loadFailure {
            banner = Banner(kind: .failure, text: loadFailure)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppState.storeURL), !data.isEmpty else { return }
        do {
            let lib = try JSONDecoder().decode(Library.self, from: data)
            feeds = lib.feeds
            articles = lib.articles
            settings = lib.settings
        } catch {
            // Preserve the unreadable file rather than overwriting it with a fresh seed.
            let backup = AppState.storeURL
                .deletingLastPathComponent()
                .appendingPathComponent("library.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: AppState.storeURL, to: backup)
            loadFailure = "Your library couldn't be read and was set aside at \(backup.lastPathComponent). Starting fresh."
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let lib = Library(feeds: feeds, articles: articles, settings: settings)
        guard let data = try? JSONEncoder().encode(lib) else { return }
        try? data.write(to: AppState.storeURL, options: .atomic)
    }

    // MARK: - Derived collections

    var folders: [String] {
        Array(Set(feeds.map(\.folder))).sorted()
    }

    func feed(_ id: UUID) -> Feed? { feeds.first { $0.id == id } }

    func unreadCount(for selection: SidebarSelection) -> Int {
        switch selection {
        case .all, .unread:   return articles.filter { !$0.isRead }.count
        case .starred:        return articles.filter { $0.isStarred && !$0.isRead }.count
        case .savedToNotion:  return 0
        case .feed(let id):   return articles.filter { $0.feedID == id && !$0.isRead }.count
        case .folder(let f):
            let ids = Set(feeds.filter { $0.folder == f }.map(\.id))
            return articles.filter { ids.contains($0.feedID) && !$0.isRead }.count
        case .topic(let t):
            if t == Self.untaggedTopic { return articles.filter { !$0.isRead && $0.topics.isEmpty }.count }
            return articles.filter { !$0.isRead && $0.topics.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }.count
        }
    }

    var visibleArticles: [Article] {
        var list: [Article]
        switch selection {
        case .all:            list = articles
        case .unread:         list = articles.filter { !$0.isRead }
        case .starred:        list = articles.filter { $0.isStarred }
        case .savedToNotion:  list = articles.filter { $0.savedToNotion }
        case .feed(let id):   list = articles.filter { $0.feedID == id }
        case .folder(let f):
            let ids = Set(feeds.filter { $0.folder == f }.map(\.id))
            list = articles.filter { ids.contains($0.feedID) }
        case .topic(let t):
            list = t == Self.untaggedTopic
                ? articles.filter { $0.topics.isEmpty }
                : articles.filter { $0.topics.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || (feed($0.feedID)?.title.lowercased().contains(query) ?? false)
            }
        }

        return list.sorted {
            settings.sort == .newestFirst
                ? $0.displayDate > $1.displayDate
                : $0.displayDate < $1.displayDate
        }
    }

    var selectedArticle: Article? {
        guard let id = selectedArticleID else { return nil }
        return articles.first { $0.id == id }
    }

    // MARK: - Mutations

    func update(_ article: Article, _ change: (inout Article) -> Void) {
        guard let idx = articles.firstIndex(where: { $0.id == article.id }) else { return }
        change(&articles[idx])
        scheduleSave()
    }

    func toggleRead(_ article: Article) {
        update(article) { $0.isRead.toggle() }
    }

    func markRead(_ article: Article, _ read: Bool = true) {
        guard article.isRead != read else { return }
        update(article) { $0.isRead = read }
    }

    func toggleStar(_ article: Article) {
        update(article) { $0.isStarred.toggle() }
    }

    func markAllRead() {
        let ids = Set(visibleArticles.map(\.id))
        guard !ids.isEmpty else { return }
        for i in articles.indices where ids.contains(articles[i].id) {
            articles[i].isRead = true
        }
        scheduleSave()
        banner = Banner(kind: .info, text: "Marked \(ids.count) as read")
    }

    // MARK: - Feeds

    func addFeed(from input: String, folder: String = "Feeds") async {
        do {
            let (url, parsed) = try await FeedService.discover(from: input)
            if feeds.contains(where: { $0.feedURL == url }) {
                banner = Banner(kind: .info, text: "You already subscribe to that feed")
                return
            }
            let feed = Feed(title: parsed.title ?? url.host ?? "New feed",
                            feedURL: url,
                            siteURL: parsed.siteURL,
                            folder: folder.isEmpty ? "Feeds" : folder)
            feeds.append(feed)
            scheduleSave()
            await refresh(feed)
            banner = Banner(kind: .success, text: "Added \(feed.title)")
        } catch {
            banner = Banner(kind: .failure, text: error.localizedDescription)
        }
    }

    func remove(_ feed: Feed) {
        feeds.removeAll { $0.id == feed.id }
        articles.removeAll { $0.feedID == feed.id && !$0.isStarred && !$0.savedToNotion }
        if case .feed(let id) = selection, id == feed.id { selection = .unread }
        scheduleSave()
    }

    func rename(_ feed: Feed, to title: String, folder: String) {
        guard let idx = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[idx].title = title.isEmpty ? feeds[idx].title : title
        feeds[idx].folder = folder.isEmpty ? "Feeds" : folder
        scheduleSave()
    }

    // MARK: - Refresh

    func refreshAll() async {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        refreshProgress = "Refreshing \(feeds.count) feeds\u{2026}"
        let snapshot = feeds

        await withTaskGroup(of: (UUID, Result<(ParsedFeed, [Article]), Error>).self) { group in
            for feed in snapshot {
                group.addTask {
                    do { return (feed.id, .success(try await FeedService.fetch(feed))) }
                    catch { return (feed.id, .failure(error)) }
                }
            }
            var done = 0
            for await (feedID, result) in group {
                done += 1
                refreshProgress = "Refreshing\u{2026} \(done)/\(snapshot.count)"
                apply(result, for: feedID)
            }
        }

        prune()
        classifyMissingTopics()
        isRefreshing = false
        refreshProgress = ""
        saveNow()

        let failed = feeds.filter { $0.lastError != nil }
        if !failed.isEmpty {
            banner = Banner(kind: .failure,
                            text: failed.count == 1
                                ? "\(failed[0].title): \(failed[0].lastError!)"
                                : "\(failed.count) feeds couldn't be reached")
        }
    }

    func refresh(_ feed: Feed) async {
        do {
            let result = try await FeedService.fetch(feed)
            apply(.success(result), for: feed.id)
        } catch {
            apply(.failure(error), for: feed.id)
        }
        prune()
        scheduleSave()
    }

    private func apply(_ result: Result<(ParsedFeed, [Article]), Error>, for feedID: UUID) {
        guard let idx = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        switch result {
        case .failure(let error):
            feeds[idx].lastError = error.localizedDescription
            feeds[idx].lastFetched = Date()

        case .success(let (parsed, incoming)):
            feeds[idx].lastError = nil
            feeds[idx].lastFetched = Date()
            if feeds[idx].siteURL == nil { feeds[idx].siteURL = parsed.siteURL }

            var existing = Dictionary(articles.enumerated().map { ($1.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            for var item in incoming {
                if let at = existing[item.id] {
                    // Keep local state; refresh the content in case the post was edited.
                    articles[at].title = item.title
                    articles[at].summary = item.summary
                    articles[at].contentHTML = item.contentHTML
                    if articles[at].published == nil { articles[at].published = item.published }
                    // Backfill categories for articles stored before Quill read them, and
                    // reclassify so an existing library gains topics without being re-fetched.
                    if !item.categories.isEmpty && articles[at].categories != item.categories {
                        articles[at].categories = item.categories
                        articles[at].derivedTopics = []
                        articles[at].topicsVersion = 0   // force a recompute with real categories
                    }
                } else {
                    item.firstSeen = Date()
                    articles.append(item)
                    existing[item.id] = articles.count - 1
                }
            }
        }
    }

    /// Keep the library small: newest N per feed, but never drop starred or saved items.
    private func prune() {
        let limit = max(50, settings.keepPerFeed)
        var keep = Set<Article.ID>()
        for feed in feeds {
            let ofFeed = articles.filter { $0.feedID == feed.id }
                .sorted { $0.displayDate > $1.displayDate }
            keep.formUnion(ofFeed.prefix(limit).map(\.id))
        }
        articles.removeAll { article in
            !keep.contains(article.id) && !article.isStarred && !article.savedToNotion
        }
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        let minutes = max(5, settings.refreshMinutes)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    func restartTimer() { startTimer() }


    // MARK: - Topics & tags

    /// Sentinel used by the sidebar's "Untagged" row.
    static let untaggedTopic = "\u{0000}untagged"

    struct TopicEntry: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var total: Int
        var unread: Int
        var isManual: Bool
    }

    /// Everything the sidebar groups by, manual tags first, then derived topics.
    var topicIndex: [TopicEntry] {
        var totals: [String: (total: Int, unread: Int, manual: Bool)] = [:]
        var display: [String: String] = [:]

        for article in articles {
            let manual = Set(article.tags.map { $0.lowercased() })
            for topic in article.topics {
                let key = topic.lowercased()
                display[key] = display[key] ?? topic
                var entry = totals[key] ?? (0, 0, false)
                entry.total += 1
                if !article.isRead { entry.unread += 1 }
                if manual.contains(key) { entry.manual = true }
                totals[key] = entry
            }
        }

        return totals.map { key, value in
            TopicEntry(name: display[key] ?? key,
                       total: value.total,
                       unread: value.unread,
                       isManual: value.manual)
        }
        .sorted {
            if $0.isManual != $1.isManual { return $0.isManual }      // hand-made tags on top
            if $0.unread != $1.unread { return $0.unread > $1.unread }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Untagged articles still need somewhere to live.
    var untaggedCount: Int {
        articles.filter { $0.topics.isEmpty && !$0.isRead }.count
    }

    var allTagNames: [String] {
        Array(Set(articles.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func addTag(_ tag: String, to article: Article) {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !article.hasTag(clean) else { return }
        update(article) { $0.tags.append(clean) }
    }

    func removeTag(_ tag: String, from article: Article) {
        update(article) { $0.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    func toggleTag(_ tag: String, on article: Article) {
        article.hasTag(tag) ? removeTag(tag, from: article) : addTag(tag, to: article)
    }

    func renameTag(_ old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        for i in articles.indices {
            if let idx = articles[i].tags.firstIndex(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) {
                articles[i].tags[idx] = clean
            }
        }
        if case .topic(let current) = selection, current.caseInsensitiveCompare(old) == .orderedSame {
            selection = .topic(clean)
        }
        scheduleSave()
    }

    func deleteTag(_ tag: String) {
        for i in articles.indices {
            articles[i].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        if case .topic(let current) = selection, current.caseInsensitiveCompare(tag) == .orderedSame {
            selection = .unread
        }
        scheduleSave()
    }

    /// Classifies anything that has no topics yet — new articles, and the whole library the
    /// first time this build runs.
    func classifyMissingTopics() {
        var changed = false
        for i in articles.indices where articles[i].topicsVersion < Topics.version {
            let feedTitle = feed(articles[i].feedID)?.title ?? ""
            let topics = Topics.derive(categories: articles[i].categories,
                                       title: articles[i].title,
                                       summary: articles[i].summary,
                                       feedTitle: feedTitle)
            articles[i].derivedTopics = topics
            articles[i].topicsVersion = Topics.version
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: - Full text

    func isLoadingFullText(_ article: Article) -> Bool {
        fullTextLoading.contains(article.id)
    }

    /// Fetches the publisher's page, keeping the result only if it genuinely beats what the
    /// feed already gave us — a bad extraction must never replace good content.
    func loadFullText(for article: Article, force: Bool = false) async {
        guard let url = article.link else { return }
        if !force && article.hasFullText { return }
        if fullTextLoading.contains(article.id) { return }

        fullTextLoading.insert(article.id)
        defer { fullTextLoading.remove(article.id) }

        do {
            let result = try await FullTextExtractor.extract(from: url)
            let feedLength = article.feedTextLength
            if result.textLength > max(600, Int(Double(feedLength) * 1.2)) {
                update(article) {
                    $0.fullContentHTML = result.html
                    $0.fullTextError = nil
                }
            } else {
                update(article) {
                    $0.fullTextError = "The page didn't offer more than the feed already includes."
                }
            }
        } catch {
            update(article) { $0.fullTextError = Self.friendlyExtractError(error, host: url.host) }
        }
    }

    private static func friendlyExtractError(_ error: Error, host: String?) -> String {
        let site = host?.replacingOccurrences(of: "www.", with: "") ?? "This site"
        if let extractError = error as? ExtractError {
            switch extractError {
            case .noContent, .timedOut:
                return "\(site) blocks automated readers, so the full text can't be loaded here. Open it in your browser to read it with your subscription."
            case .load(let message):
                return "Couldn't load the page: \(message)"
            }
        }
        return error.localizedDescription
    }

    // MARK: - Notion

    func saveToNotion(_ article: Article, notes: String, tags: [String], status: String?) async throws {
        guard !settings.notionDatabaseID.isEmpty else { throw NotionError.noDatabase }
        let source = feed(article.feedID)?.title ?? "RSS"
        let payload = NotionSave(
            title: article.title,
            url: article.link?.absoluteString,
            source: source,
            author: article.author,
            published: article.published,
            summary: article.summary,
            notes: notes,
            tags: tags,
            status: status?.isEmpty == false ? status : (settings.defaultStatus.isEmpty ? nil : settings.defaultStatus)
        )
        let pageURL = try await NotionClient.shared.save(payload, to: settings.notionDatabaseID)
        update(article) { $0.notionPageURL = pageURL }
        banner = Banner(kind: .success, text: "Saved to \(settings.notionDatabaseTitle.isEmpty ? "Notion" : settings.notionDatabaseTitle)")
    }

    // MARK: - Seed

    static let starterFeeds: [Feed] = [
        Feed(title: "NYT \u{2014} Home Page",
             feedURL: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")!,
             siteURL: URL(string: "https://www.nytimes.com"), folder: "News"),
        Feed(title: "NYT \u{2014} Technology",
             feedURL: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml")!,
             siteURL: URL(string: "https://www.nytimes.com/section/technology"), folder: "News"),
        Feed(title: "NYT \u{2014} Well",
             feedURL: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Well.xml")!,
             siteURL: URL(string: "https://www.nytimes.com/section/well"), folder: "News"),
        Feed(title: "NYT \u{2014} Books",
             feedURL: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Books.xml")!,
             siteURL: URL(string: "https://www.nytimes.com/section/books"), folder: "News"),
        Feed(title: "Platformer",
             feedURL: URL(string: "https://www.platformer.news/rss/")!,
             siteURL: URL(string: "https://www.platformer.news"), folder: "Substack"),
        Feed(title: "kottke.org",
             feedURL: URL(string: "https://feeds.kottke.org/main")!,
             siteURL: URL(string: "https://kottke.org"), folder: "Blogs")
    ]
}
