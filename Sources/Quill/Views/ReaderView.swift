import SwiftUI
import WebKit
import AppKit

struct ReaderView: View {
    @EnvironmentObject var state: AppState
    @Binding var showSaveSheet: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @State private var preferFeedVersion = false
    @State private var addingTag = false
    @State private var newTag = ""

    var body: some View {
        Group {
            if let article = state.selectedArticle {
                reader(article)
            } else {
                ContentUnavailableView(
                    "Pick something to read",
                    systemImage: "book",
                    description: Text("Select an article from the list.\n\u{2318}\u{21E7}S saves the open article to Notion.")
                )
            }
        }
        .toolbar { toolbar }
    }

    private func reader(_ article: Article) -> some View {
        let showingFull = article.hasFullText && !preferFeedVersion
        return VStack(spacing: 0) {
            header(article)
            statusStrip(article)
            Divider()
            ArticleWebView(html: renderHTML(article, useFullText: showingFull),
                           baseURL: article.link,
                           contentID: "\(article.id)-\(showingFull)-\(colorScheme)-\(Int(fontSize))")
        }
        .task(id: article.id) {
            preferFeedVersion = false
            guard state.settings.autoLoadFullText,
                  article.feedIsThin,
                  !article.hasFullText,
                  article.fullTextError == nil else { return }
            await state.loadFullText(for: article)
        }
    }

    /// One line under the header that says exactly what you're reading and why.
    @ViewBuilder
    private func statusStrip(_ article: Article) -> some View {
        let loading = state.isLoadingFullText(article)
        if loading || article.fullTextError != nil || article.hasFullText || article.feedIsThin {
            HStack(spacing: 7) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Fetching the full article\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if article.hasFullText && !preferFeedVersion {
                    Image(systemName: "doc.text.fill").font(.caption2).foregroundStyle(.green)
                    Text("Full article").font(.caption).foregroundStyle(.secondary)
                    Button("Show feed version") { preferFeedVersion = true }
                        .buttonStyle(.link).font(.caption)
                } else if article.hasFullText {
                    Text("Feed summary").font(.caption).foregroundStyle(.secondary)
                    Button("Show full article") { preferFeedVersion = false }
                        .buttonStyle(.link).font(.caption)
                } else if let error = article.fullTextError {
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Feed summary only").font(.caption).foregroundStyle(.secondary)
                    Button("Load full article") {
                        Task { await state.loadFullText(for: article, force: true) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Spacer(minLength: 0)
                if article.fullTextError != nil, article.link != nil {
                    Button("Open in browser") {
                        if let url = article.link { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
    }

    private func header(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(article.title)
                .font(.system(size: 22, weight: .bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(state.feed(article.feedID)?.title ?? "")
                if let author = article.author, !author.isEmpty {
                    Text("\u{00B7}"); Text(author)
                }
                Text("\u{00B7}")
                Text(article.displayDate, format: .dateTime.month(.abbreviated).day().year().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            tagRow(article)

            if article.savedToNotion, let page = article.notionPageURL, let url = URL(string: page) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Saved to Notion \u{2014} open page", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// Topics on the article: your own tags are removable, derived ones are just labels.
    @ViewBuilder
    private func tagRow(_ article: Article) -> some View {
        HStack(spacing: 6) {
            ForEach(article.tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag)
                    Button {
                        state.removeTag(tag, from: article)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
            }

            ForEach(article.derivedTopics.filter { !article.hasTag($0) }, id: \.self) { topic in
                Text(topic)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.secondary.opacity(0.13)))
                    .foregroundStyle(.secondary)
                    .help("Topic derived from the publisher's categories")
            }

            Menu {
                ForEach(state.allTagNames, id: \.self) { tag in
                    Button {
                        state.toggleTag(tag, on: article)
                    } label: {
                        Label(tag, systemImage: article.hasTag(tag) ? "checkmark" : "tag")
                    }
                }
                if !state.allTagNames.isEmpty { Divider() }
                Button("New Tag\u{2026}") { addingTag = true }
            } label: {
                Label("Tag", systemImage: "plus.circle")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.top, 2)
        .sheet(isPresented: $addingTag) { AddTagSheet(article: article) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let article = state.selectedArticle {
                Button {
                    state.toggleStar(article)
                } label: {
                    Image(systemName: article.isStarred ? "star.fill" : "star")
                        .foregroundStyle(article.isStarred ? Color.yellow : Color.secondary)
                }
                .help("Star (\u{2318}L)")

                Button {
                    state.toggleRead(article)
                } label: {
                    Image(systemName: article.isRead ? "envelope.open" : "envelope.badge")
                }
                .help("Toggle read (\u{2318}U)")

                Menu {
                    Button("Larger Text") { fontSize = min(24, fontSize + 1) }
                    Button("Smaller Text") { fontSize = max(13, fontSize - 1) }
                    Button("Reset Text Size") { fontSize = 17 }
                } label: {
                    Image(systemName: "textformat.size")
                }

                Button {
                    Task { await state.loadFullText(for: article, force: true) }
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .help("Fetch the full article from the publisher")
                .disabled(article.link == nil || state.isLoadingFullText(article))

                if let url = article.link {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .help("Open in browser (\u{2318}\u{21E7}O)")
                }

                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save to Notion", systemImage: "square.and.arrow.down")
                }
                .help("Save to Notion (\u{2318}\u{21E7}S)")
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: HTML rendering

    private func renderHTML(_ article: Article, useFullText: Bool) -> String {
        let dark = colorScheme == .dark
        let bg = dark ? "#1e1e1e" : "#ffffff"
        let fg = dark ? "#e8e6e3" : "#1d1d1f"
        let muted = dark ? "#9a9a9a" : "#6b6b70"
        let link = dark ? "#6fb3ff" : "#0a62d0"
        let rule = dark ? "#3a3a3a" : "#e3e3e6"

        var body = (useFullText ? (article.fullContentHTML ?? "") : article.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            body = "<p class='q-empty'>This feed only publishes a headline.</p>"
        }
        if !useFullText, let url = article.link {
            body += "<p class='q-more'><a href=\"\(url.absoluteString)\">Read the full article \u{2192}</a></p>"
        }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          html, body { background: \(bg); color: \(fg); margin: 0; }
          body {
            font: \(Int(fontSize))px/1.62 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
            padding: 20px 24px 60px;
            -webkit-font-smoothing: antialiased;
            word-wrap: break-word;
          }
          p { margin: 0 0 1.05em; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          img, video, iframe { max-width: 100%; height: auto; border-radius: 8px; display: block; margin: 1.2em 0; }
          figure { margin: 1.4em 0; }
          figcaption { font-size: 0.82em; color: \(muted); margin-top: 0.5em; }
          blockquote {
            margin: 1.4em 0; padding: 0.2em 0 0.2em 1.1em;
            border-left: 3px solid \(rule); color: \(muted);
          }
          h1,h2,h3,h4 { line-height: 1.25; margin: 1.6em 0 0.5em; }
          h1 { font-size: 1.5em; } h2 { font-size: 1.28em; } h3 { font-size: 1.12em; }
          hr { border: 0; border-top: 1px solid \(rule); margin: 2em 0; }
          pre, code { font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 0.9em; }
          pre { background: \(dark ? "#262626" : "#f5f5f7"); padding: 12px; border-radius: 8px; overflow-x: auto; }
          table { border-collapse: collapse; width: 100%; font-size: 0.92em; }
          td, th { border: 1px solid \(rule); padding: 6px 8px; text-align: left; }
          ul, ol { padding-left: 1.4em; }
          .q-empty { color: \(muted); font-style: italic; }
          .q-more { margin-top: 2em; padding-top: 1.2em; border-top: 1px solid \(rule); font-weight: 600; }
        </style></head>
        <body>\(body)</body></html>
        """
    }
}

/// WKWebView wrapper: renders feed HTML, sends every clicked link to the default browser.
struct ArticleWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    let contentID: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastID != contentID else { return }
        context.coordinator.lastID = contentID
        view.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastID: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
