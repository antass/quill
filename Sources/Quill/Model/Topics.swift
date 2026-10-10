import Foundation

/// Publishers tag articles with wildly different vocabularies — one NYT feed alone carries
/// 150+ distinct category strings ("Trump, Donald J", "Death Row Records"). Grouping the
/// sidebar by those directly would be unusable, so raw categories are folded into a small
/// canonical set. Manual tags always sit alongside these and take priority.
enum Topics {

    /// Raise this whenever the rules change; stored topics below it are recomputed.
    static let version = 5

    struct Rule {
        let topic: String
        let icon: String
        let patterns: [String]
    }

    /// Every pattern is matched with word boundaries. Bare fragments like "art", "eat",
    /// "home" or "book" would otherwise match inside Administration, threat, homicide and
    /// Facebook — which is exactly what happened before this was tested against real data.
    static let rules: [Rule] = [
        Rule(topic: "AI", icon: "cpu", patterns: [
            "artificial intelligence", "machine learning", "chatgpt", "openai", "anthropic",
            "large language model", "llm", "chatbot", "generative ai", "deepmind", "ai"]),
        Rule(topic: "Technology", icon: "desktopcomputer", patterns: [
            "technology", "computers and the internet", "software", "internet", "social media",
            "smartphone", "semiconductors", "startup", "silicon valley", "cybersecurity",
            "privacy", "apps", "google", "apple inc", "meta platforms", "microsoft",
            "instagram", "tiktok", "data centers"]),
        Rule(topic: "Politics", icon: "building.columns", patterns: [
            "politics and government", "elections", "election", "congress", "senate",
            "house of representatives", "president", "trump, donald", "biden",
            "supreme court", "campaign finance", "legislature", "primaries", "voting",
            "democratic party", "republican party", "federal government", "white house",
            "justice department", "subpoena", "impeachment"]),
        Rule(topic: "World", icon: "globe", patterns: [
            "international relations", "foreign policy", "united nations",
            "war and armed conflict", "defense and military forces", "immigration",
            "europe", "asia", "africa", "middle east", "ukraine", "israel", "russia",
            "china", "gaza", "iran", "diplomacy"]),
        Rule(topic: "Business", icon: "chart.line.uptrend.xyaxis", patterns: [
            "business", "economy", "economics", "finance", "stocks", "stock market",
            "labor", "banking", "inflation", "trade", "layoffs", "wages", "corporations",
            "antitrust", "mergers", "advertising and marketing", "taxes", "irs"]),
        Rule(topic: "Health", icon: "heart.text.square", patterns: [
            "health", "medicine", "disease", "diseases", "vaccination", "vaccines",
            "clinical trials", "covid", "virus", "bacteria", "cancer", "mental health",
            "therapy", "psychology", "doctors", "hospitals", "nutrition", "diet",
            "sleep", "exercise", "fitness", "aging", "food and drug administration"]),
        Rule(topic: "Science", icon: "atom", patterns: [
            "science", "research", "space", "nasa", "astronomy", "physics", "biology",
            "genetics", "evolution", "archaeology", "mathematics", "animals", "wildlife"]),
        Rule(topic: "Climate", icon: "leaf", patterns: [
            "climate change", "climate", "global warming", "environment", "greenhouse gases",
            "renewable energy", "emissions", "hurricanes", "wildfires", "floods"]),
        Rule(topic: "Parenting", icon: "figure.2.and.child.holdinghands", patterns: [
            "parenting", "children and childhood", "families and family life", "babies",
            "teenagers", "motherhood", "fatherhood", "child care", "pregnancy", "mothers"]),
        Rule(topic: "Education", icon: "graduationcap", patterns: [
            "education", "schools", "school", "colleges", "college", "universities",
            "university", "teachers", "students", "classroom"]),
        Rule(topic: "Food", icon: "fork.knife", patterns: [
            "food", "cooking", "recipes", "recipe", "restaurants", "restaurant", "chefs",
            "baking", "wine", "coffee", "kitchen", "dining", "eating"]),
        Rule(topic: "Books", icon: "books.vertical", patterns: [
            "book", "books", "book review", "writing and writers", "authors", "literature",
            "poetry", "novel", "novels", "fiction", "nonfiction"]),
        Rule(topic: "Culture", icon: "theatermasks", patterns: [
            "art", "arts", "artist", "artists", "movies", "movie", "film", "films",
            "television", "music", "theater", "museums", "museum", "culture",
            "celebrities", "pop culture", "photography", "games", "video games",
            "rap and hip-hop", "dance", "comedy", "opera"]),
        Rule(topic: "Media", icon: "newspaper", patterns: [
            "news and news media", "journalism", "newspapers", "broadcasting",
            "publishing industry", "podcast", "podcasts", "substack", "newsletter"]),
        Rule(topic: "Sports", icon: "figure.run", patterns: [
            "sports", "football", "basketball", "baseball", "soccer", "olympics",
            "tennis", "athletes", "hockey", "golf", "running", "marathon"]),
        Rule(topic: "Style", icon: "tshirt", patterns: [
            "fashion", "style", "beauty", "clothing", "shopping", "weddings"]),
        Rule(topic: "Home", icon: "house", patterns: [
            "real estate", "housing", "home", "homes", "interior design", "gardens",
            "gardening", "architecture", "renovation", "furniture"]),
        Rule(topic: "Travel", icon: "airplane", patterns: [
            "travel", "travels", "tourism", "hotels", "airlines", "vacation"]),
        Rule(topic: "Work", icon: "briefcase", patterns: [
            "career", "careers", "job", "jobs", "workplace", "remote work", "management",
            "productivity", "burnout", "hiring", "leadership", "freelance", "founders"]),
        Rule(topic: "Life", icon: "heart", patterns: [
            "friendship", "friends", "relationships", "marriage", "divorce", "dating",
            "grief", "loneliness", "memoir", "middle age", "midlife", "in-laws",
            "self-help", "personal finance"]),
        Rule(topic: "Crime", icon: "shield.lefthalf.filled", patterns: [
            "crime", "murders", "homicides", "police", "shootings", "prisons",
            "lawsuits", "decisions and verdicts", "fraud", "courts"])
    ]

    static let icons: [String: String] = {
        Dictionary(rules.map { ($0.topic, $0.icon) }, uniquingKeysWith: { a, _ in a })
    }()

    static func icon(for topic: String) -> String {
        icons[topic] ?? "tag"
    }

    private static let compiled: [(String, NSRegularExpression)] = {
        rules.compactMap { rule in
            let joined = rule.patterns
                .map { "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b" }
                .joined(separator: "|")
            guard let regex = try? NSRegularExpression(pattern: joined, options: .caseInsensitive) else { return nil }
            return (rule.topic, regex)
        }
    }()

    /// Derives up to `limit` canonical topics. Publisher categories are the strongest signal;
    /// the headline and feed name are the fallback for feeds that publish no categories at all.
    static func derive(categories: [String],
                       title: String,
                       summary: String,
                       feedTitle: String,
                       limit: Int = 2) -> [String] {

        // Publisher categories are a deliberate label; words in a headline are a coincidence.
        // Use the headline only when the feed supplies no categories at all.
        let categoryText = categories.joined(separator: " \n ")
        if !categoryText.isEmpty {
            let strong = score(categoryText)
            if !strong.isEmpty { return rank(strong, limit: limit) }
        }

        // No categories (most Substacks and personal blogs): fall back to the headline,
        // the feed's own name and the opening of the summary. A single boundary-matched
        // keyword is enough here — requiring two left two thirds of the library untagged.
        let fallbackText = "\(title) \n \(sanitize(feedTitle)) \n \(summary.prefix(400))"
        return rank(score(fallbackText), limit: limit)
    }

    /// A feed's name is a useful hint ("NYT — Books") but section names are not topics.
    /// "NYT — Home Page" was filing every front-page story under Home.
    private static let feedNoise = try! NSRegularExpression(
        pattern: "\\b(home page|homepage|home|top stories|main|latest|headlines|feed|rss|all)\\b",
        options: .caseInsensitive)

    private static func sanitize(_ feedTitle: String) -> String {
        let range = NSRange(location: 0, length: (feedTitle as NSString).length)
        return feedNoise.stringByReplacingMatches(in: feedTitle, range: range, withTemplate: " ")
    }

    /// Publishers write some phrases in ways that collide with unrelated topics:
    /// "Food and Drug Administration" is not a Food story, and the NYT writes AI as "A.I.".
    private static func normalize(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "Food and Drug Administration", with: " FDA ",
                                   options: .caseInsensitive)
        t = t.replacingOccurrences(of: "A.I.", with: " AI ", options: .caseInsensitive)
        t = t.replacingOccurrences(of: "U.S.", with: " US ", options: .caseInsensitive)
        return t
    }

    private static func score(_ rawText: String) -> [String: Int] {
        let text = normalize(rawText)
        var scores: [String: Int] = [:]
        for (topic, regex) in compiled {
            let n = matches(regex, in: text)
            if n > 0 { scores[topic] = n }
        }
        return scores
    }

    private static func rank(_ scores: [String: Int], limit: Int) -> [String] {
        scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.numberOfMatches(in: text, range: range)
    }
}
