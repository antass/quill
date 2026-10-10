import SwiftUI
import AppKit

struct ArticleListView: View {
    @EnvironmentObject var state: AppState
    @Binding var showSaveSheet: Bool
    @State private var taggingArticle: Article?

    var body: some View {
        List(selection: $state.selectedArticleID) {
            ForEach(state.visibleArticles) { article in
                ArticleRow(article: article, feedTitle: state.feed(article.feedID)?.title ?? "")
                    .tag(article.id)
                    .contextMenu { menu(for: article) }
            }
        }
        .listStyle(.inset)
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search articles")
        .overlay {
            if state.visibleArticles.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "text.page",
                    description: Text(emptyHint)
                )
            }
        }
        .onChange(of: state.selectedArticleID) { _, newValue in
            guard state.settings.markReadOnOpen,
                  let id = newValue,
                  let article = state.articles.first(where: { $0.id == id }) else { return }
            state.markRead(article)
        }
        .sheet(item: $taggingArticle) { article in AddTagSheet(article: article) }
        .navigationTitle(listTitle)
        .navigationSubtitle(state.visibleArticles.isEmpty ? "" : "\(state.visibleArticles.count) articles")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $state.settings.sort) {
                        ForEach(ArticleSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button("Mark All as Read") { state.markAllRead() }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for article: Article) -> some View {
        Button(article.isRead ? "Mark as Unread" : "Mark as Read") { state.toggleRead(article) }
        Button(article.isStarred ? "Remove Star" : "Star") { state.toggleStar(article) }
        Menu("Tags") {
            ForEach(state.allTagNames, id: \.self) { tag in
                Button {
                    state.toggleTag(tag, on: article)
                } label: {
                    Label(tag, systemImage: article.hasTag(tag) ? "checkmark" : "tag")
                }
            }
            if !state.allTagNames.isEmpty { Divider() }
            Button("New Tag\u{2026}") { taggingArticle = article }
        }
        Divider()
        Button("Save to Notion\u{2026}") {
            state.selectedArticleID = article.id
            showSaveSheet = true
        }
        if let url = article.link {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    private var listTitle: String {
        switch state.selection {
        case .all: return "All Articles"
        case .unread: return "Unread"
        case .starred: return "Starred"
        case .savedToNotion: return "Saved to Notion"
        case .feed(let id): return state.feed(id)?.title ?? "Feed"
        case .folder(let f): return f
        case .topic(let t): return t == AppState.untaggedTopic ? "Untagged" : t
        }
    }

    private var emptyTitle: String {
        if !state.searchText.isEmpty { return "No matches" }
        if case .unread = state.selection { return "All caught up" }
        return "Nothing here yet"
    }

    private var emptyHint: String {
        if !state.searchText.isEmpty { return "Try a different search." }
        if case .unread = state.selection { return "Refresh with \u{2318}R, or browse All Articles." }
        return "Add a feed with \u{2318}N, then refresh with \u{2318}R."
    }
}

struct ArticleRow: View {
    let article: Article
    let feedTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.system(size: 13, weight: article.isRead ? .regular : .semibold))
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .lineLimit(3)

                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(feedTitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("\u{00B7}").font(.caption2).foregroundStyle(.tertiary)
                    Text(article.displayDate, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(article.topics.prefix(2), id: \.self) { topic in
                        Text(topic)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 2)
                    if article.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if article.savedToNotion {
                        Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
                            .help("Saved to Notion")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddTagSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let article: Article
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Tag").font(.headline)
            Text(article.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }
            if !state.allTagNames.isEmpty {
                Text("Existing").font(.caption).foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.allTagNames, id: \.self) { tag in
                            Button(tag) { name = tag }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func apply() {
        state.addTag(name, to: article)
        dismiss()
    }
}
