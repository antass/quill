import Foundation

struct NotionDatabaseRef: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var url: String?
}

struct NotionProperty: Hashable {
    var name: String
    var type: String
    var options: [String] = []
}

struct NotionSave {
    var title: String
    var url: String?
    var source: String
    var author: String?
    var published: Date?
    var summary: String
    var notes: String
    var tags: [String]
    var status: String?
}

enum NotionError: LocalizedError {
    case noToken
    case noDatabase
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noToken:    return "Add your Notion integration token in Settings first."
        case .noDatabase: return "Pick a Notion database in Settings first."
        case .api(let m): return m
        case .badResponse: return "Notion sent back something unexpected."
        }
    }
}

actor NotionClient {

    static let shared = NotionClient()
    private let version = "2022-06-28"
    private var schemaCache: [String: [NotionProperty]] = [:]

    private var token: String? {
        let t = Keychain.get("notion-token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    func clearSchemaCache() { schemaCache.removeAll() }

    // MARK: Request plumbing

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token else { throw NotionError.noToken }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionError.badResponse
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (json["message"] as? String) ?? "Notion returned \(http.statusCode)"
            throw NotionError.api(message)
        }
        return json
    }

    // MARK: Public API

    /// Confirms the token works and returns the bot/workspace name.
    func validateToken() async throws -> String {
        let json = try await request("/users/me")
        if let bot = json["bot"] as? [String: Any],
           let workspace = bot["workspace_name"] as? String {
            return workspace
        }
        return (json["name"] as? String) ?? "Notion"
    }

    /// Every database the integration has been shared with.
    func listDatabases() async throws -> [NotionDatabaseRef] {
        let json = try await request("/search", method: "POST", body: [
            "filter": ["value": "database", "property": "object"],
            "page_size": 100
        ])
        let results = json["results"] as? [[String: Any]] ?? []
        return results.compactMap { db in
            guard let id = db["id"] as? String else { return nil }
            let titleParts = db["title"] as? [[String: Any]] ?? []
            let title = titleParts.compactMap { $0["plain_text"] as? String }.joined()
            return NotionDatabaseRef(id: id,
                                     title: title.isEmpty ? "(untitled database)" : title,
                                     url: db["url"] as? String)
        }
    }

    func schema(for databaseID: String) async throws -> [NotionProperty] {
        if let cached = schemaCache[databaseID] { return cached }
        let json = try await request("/databases/\(databaseID)")
        guard let props = json["properties"] as? [String: Any] else { throw NotionError.badResponse }
        var result: [NotionProperty] = []
        for (name, raw) in props {
            guard let dict = raw as? [String: Any], let type = dict["type"] as? String else { continue }
            var options: [String] = []
            if let config = dict[type] as? [String: Any],
               let opts = config["options"] as? [[String: Any]] {
                options = opts.compactMap { $0["name"] as? String }
            }
            result.append(NotionProperty(name: name, type: type, options: options))
        }
        schemaCache[databaseID] = result
        return result
    }

    /// Creates the page. Returns the new page's Notion URL.
    func save(_ item: NotionSave, to databaseID: String) async throws -> String {
        let props = try await schema(for: databaseID)
        let properties = buildProperties(item, schema: props)
        var body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": properties
        ]
        let children = buildChildren(item)
        if !children.isEmpty { body["children"] = children }

        let json = try await request("/pages", method: "POST", body: body)
        return (json["url"] as? String) ?? ""
    }

    // MARK: Property mapping
    //
    // Databases differ, so instead of demanding an exact schema we match each
    // property by name first, then fall back to type.

    private func buildProperties(_ item: NotionSave, schema: [NotionProperty]) -> [String: Any] {
        var out: [String: Any] = [:]
        var usedURL = false, usedDate = false

        func lower(_ s: String) -> String { s.lowercased() }

        // Several properties can contain "summary". Write to exactly one, and never to a
        // field the user keeps for AI-generated text (e.g. "AI summary").
        let summaryKeys = ["summar", "excerpt", "description", "snippet"]
        let summaryCandidates = schema.filter { candidate in
            candidate.type == "rich_text" && summaryKeys.contains { lower(candidate.name).contains($0) }
        }
        let summaryTarget = (summaryCandidates.first { !lower($0.name).contains("ai") }
                             ?? summaryCandidates.first)?.name

        for prop in schema {
            let n = lower(prop.name)

            switch prop.type {
            case "title":
                out[prop.name] = ["title": richText(item.title)]

            case "url":
                if n.contains("url") || n.contains("link") || !usedURL {
                    if let url = item.url { out[prop.name] = ["url": url]; usedURL = true }
                }

            case "date":
                if let published = item.published,
                   n.contains("publish") || n.contains("date") || !usedDate {
                    out[prop.name] = ["date": ["start": iso(published)]]
                    usedDate = true
                } else if n.contains("saved") || n.contains("added") || n.contains("captured") {
                    out[prop.name] = ["date": ["start": iso(Date())]]
                }

            case "rich_text":
                if n.contains("note") || n.contains("comment") || n.contains("thought") {
                    if !item.notes.isEmpty { out[prop.name] = ["rich_text": richText(item.notes)] }
                } else if n.contains("source") || n.contains("feed") || n.contains("publication") || n.contains("site") {
                    out[prop.name] = ["rich_text": richText(item.source)]
                } else if n.contains("author") || n.contains("byline") || n.contains("writer") {
                    if let author = item.author { out[prop.name] = ["rich_text": richText(author)] }
                } else if prop.name == summaryTarget {
                    out[prop.name] = ["rich_text": richText(String(item.summary.prefix(1800)))]
                } else if n.contains("url") || n.contains("link") {
                    if let url = item.url { out[prop.name] = ["rich_text": richText(url)] }
                }

            case "select":
                if n.contains("source") || n.contains("feed") || n.contains("publication") || n.contains("site") {
                    out[prop.name] = ["select": ["name": clean(item.source)]]
                } else if n.contains("status") || n.contains("stage") {
                    if let status = pick(item.status, from: prop.options) {
                        out[prop.name] = ["select": ["name": status]]
                    }
                } else if n.contains("categor") || n.contains("type") || n.contains("kind") {
                    // Match the closest thing the database already offers: many knowledge
                    // bases have "Articles"/"Newsletter" but no literal "Article"/"Link".
                    if let match = pickKind(from: prop.options, item: item) {
                        out[prop.name] = ["select": ["name": match]]
                    }
                }

            case "status":
                // Status options can't be created through the API, so only set a known one.
                if let status = pick(item.status, from: prop.options) {
                    out[prop.name] = ["status": ["name": status]]
                }

            case "multi_select":
                if n.contains("tag") || n.contains("topic") || n.contains("categor") || n.contains("label") {
                    let tags = item.tags.map { clean($0) }.filter { !$0.isEmpty }
                    if !tags.isEmpty { out[prop.name] = ["multi_select": tags.map { ["name": $0] }] }
                }

            case "checkbox":
                if n.contains("read") && !n.contains("unread") {
                    out[prop.name] = ["checkbox": false]
                }

            default:
                break
            }
        }


        return out
    }

    private func buildChildren(_ item: NotionSave) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        if !item.notes.isEmpty {
            blocks.append([
                "object": "block", "type": "callout",
                "callout": [
                    "rich_text": richText(item.notes),
                    "icon": ["type": "emoji", "emoji": "\u{1F4DD}"]
                ]
            ])
        }

        if !item.summary.isEmpty {
            blocks.append([
                "object": "block", "type": "quote",
                "quote": ["rich_text": richText(String(item.summary.prefix(1900)))]
            ])
        }

        if let url = item.url {
            blocks.append([
                "object": "block", "type": "bookmark",
                "bookmark": ["url": url]
            ])
        }

        var meta = item.source
        if let author = item.author, !author.isEmpty { meta += " \u{00B7} " + author }
        if let published = item.published {
            let df = DateFormatter()
            df.dateStyle = .medium
            meta += " \u{00B7} " + df.string(from: published)
        }
        blocks.append([
            "object": "block", "type": "paragraph",
            "paragraph": ["rich_text": richText(meta)]
        ])

        return blocks
    }

    // MARK: Helpers

    private func richText(_ text: String) -> [[String: Any]] {
        guard !text.isEmpty else { return [] }
        // Notion caps a single rich-text object at 2000 characters.
        return stride(from: 0, to: text.count, by: 1900).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: min(1900, text.count - start))
            return ["type": "text", "text": ["content": String(text[from..<to])]]
        }
    }

    private func clean(_ s: String) -> String {
        // Commas are illegal in select option names.
        String(s.replacingOccurrences(of: ",", with: " ").prefix(90))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Chooses the best existing option for "what kind of thing is this".
    private func pickKind(from options: [String], item: NotionSave) -> String? {
        guard !options.isEmpty else { return nil }
        let isNewsletter = item.source.lowercased().contains("newsletter")
            || (item.url?.contains("substack.com") ?? false)
        var wanted = isNewsletter ? ["newsletter", "article"] : ["article", "newsletter"]
        wanted += ["reference", "bookmark", "link", "note"]
        for w in wanted {
            if let match = options.first(where: { $0.lowercased().contains(w) }) { return match }
        }
        return nil
    }

    private func pick(_ wanted: String?, from options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        if let wanted, let exact = options.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return exact
        }
        let preferred = ["to read", "reading list", "inbox", "unread", "not started", "new", "backlog", "reading"]
        for p in preferred {
            if let match = options.first(where: { $0.lowercased().contains(p) }) { return match }
        }
        return options.first
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
