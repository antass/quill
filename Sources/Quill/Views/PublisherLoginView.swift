import SwiftUI
import WebKit

/// A real browser window sharing Quill's persistent cookie jar. Sign in here and the
/// full-text extractor reuses the session, so subscriber-only articles can be fetched.
struct PublisherLoginView: View {
    @State private var address = "https://myaccount.nytimes.com/auth/login"
    @State private var loadedURL: URL? = URL(string: "https://myaccount.nytimes.com/auth/login")
    @State private var reloadToken = 0

    private let shortcuts: [(String, String)] = [
        ("New York Times", "https://myaccount.nytimes.com/auth/login"),
        ("Substack", "https://substack.com/sign-in"),
        ("The Atlantic", "https://accounts.theatlantic.com/login")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("https://\u{2026}", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
                Button("Go", action: go)
                Menu("Sites") {
                    ForEach(shortcuts, id: \.0) { name, url in
                        Button(name) { address = url; go() }
                    }
                }
                .fixedSize()
            }
            .padding(10)

            Divider()

            if let url = loadedURL {
                LoginWebView(url: url, reloadToken: reloadToken)
            } else {
                Spacer()
                Text("Enter a site address to sign in.").foregroundStyle(.secondary)
                Spacer()
            }

            Divider()
            Text("Signing in here stores that publisher's cookies for Quill only. Close this window when you're done \u{2014} the session is remembered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(minWidth: 900, minHeight: 700)
        .navigationTitle("Sign In to a Publisher")
    }

    private func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        loadedURL = url
        reloadToken += 1
    }
}

private struct LoginWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The shared, on-disk store — this is what makes the login stick.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = FullTextExtractor.userAgent
        view.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastToken = -1 }
}
