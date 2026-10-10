import Foundation
import WebKit

struct ExtractedArticle {
    var html: String
    var textLength: Int
    var title: String?
    var leadImage: String?
}

enum ExtractError: LocalizedError {
    case noContent
    case timedOut
    case load(String)

    var errorDescription: String? {
        switch self {
        case .noContent: return "Couldn't find an article body on that page."
        case .timedOut:  return "The page took too long to load."
        case .load(let m): return m
        }
    }
}

/// Loads the real page in an off-screen WebKit view and pulls the article body out of the
/// live DOM. Regex over raw HTML is far too brittle for real publisher markup.
@MainActor
final class FullTextExtractor {

    /// One user agent everywhere, so the login window and the fetcher look like one browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func extract(from url: URL, timeout: TimeInterval = 25) async throws -> ExtractedArticle {
        let session = Session()
        return try await session.run(url: url, timeout: timeout)
    }

    @MainActor
    private final class Session: NSObject, WKNavigationDelegate {
        private var webView: WKWebView?
        private var continuation: CheckedContinuation<ExtractedArticle, Error>?
        private var finished = false
        private var timeoutTask: Task<Void, Never>?
        private var selfRef: Session?

        func run(url: URL, timeout: TimeInterval) async throws -> ExtractedArticle {
            selfRef = self   // keep alive until the navigation resolves

            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            // Persistent, so a sign-in done in the login window carries over here.
            config.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 2000), configuration: config)
            view.navigationDelegate = self
            // Ask for the desktop page; some publishers serve a stub to unknown agents.
            view.customUserAgent = FullTextExtractor.userAgent
            webView = view

            return try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                view.load(request)

                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self, !self.finished else { return }
                    // A slow page may still have a usable body — try before giving up.
                    await self.harvest(fallbackError: .timedOut)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                // Let late-arriving content settle briefly.
                try? await Task.sleep(nanoseconds: 700_000_000)
                await self.harvest(fallbackError: .noContent)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            complete(.failure(ExtractError.load(error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            complete(.failure(ExtractError.load(error.localizedDescription)))
        }

        private func harvest(fallbackError: ExtractError) async {
            guard !finished, let webView else { return }
            do {
                let result = try await webView.evaluateJavaScript(Self.script)
                guard let dict = result as? [String: Any],
                      let html = dict["html"] as? String,
                      let length = dict["length"] as? Int,
                      length > 200 else {
                    complete(.failure(fallbackError))
                    return
                }
                complete(.success(ExtractedArticle(
                    html: html,
                    textLength: length,
                    title: dict["title"] as? String,
                    leadImage: dict["image"] as? String
                )))
            } catch {
                complete(.failure(ExtractError.load(error.localizedDescription)))
            }
        }

        private func complete(_ result: Result<ExtractedArticle, Error>) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
            let cont = continuation
            continuation = nil
            switch result {
            case .success(let value): cont?.resume(returning: value)
            case .failure(let error): cont?.resume(throwing: error)
            }
            selfRef = nil
        }

        // MARK: The extraction script
        //
        // A compact Readability: try known article containers first, then fall back to
        // scoring every block by text density, punctuation and class/id hints.
        static let script = #"""
        (function () {
          const STRIP = 'script,style,noscript,form,button,input,select,textarea,svg,canvas,' +
            'nav,aside,footer,header,link,meta,ins,object,embed,' +
            '[aria-hidden="true"],[role="navigation"],[role="banner"],[role="complementary"],[role="contentinfo"]';

          const BAD = /(ad|ads|advert|promo|sponsor|carbon|share|social|newsletter|signup|subscribe|paywall|meter|comment|disqus|related|recirc|recommend|trending|popular|nav|menu|sidebar|footer|header|masthead|breadcrumb|toolbar|widget|cookie|banner|modal|popup|skip-link|site-|global-)/i;
          const GOOD = /(^|[\s_-])(article|articlebody|story|storybody|post|postbody|postcontent|entry|content|entrytext|prose|markup|available-content|richtext)([\s_-]|$)|(article|story|post|entry|content)-(body|content|text|wrap)/i;

          function attr(el) { return ((el.className || '') + ' ' + (el.id || '')).toString(); }

          function linkDensity(el) {
            const text = (el.innerText || '').trim().length;
            if (!text) return 1;
            let linkLen = 0;
            el.querySelectorAll('a').forEach(a => { linkLen += (a.innerText || '').trim().length; });
            return Math.min(1, linkLen / text);
          }

          function classWeight(el) {
            let w = 0;
            const a = attr(el);
            if (GOOD.test(a)) w += 40;
            if (BAD.test(a)) w -= 40;
            if (el.tagName === 'ARTICLE') w += 30;
            if (el.tagName === 'MAIN') w += 15;
            return w;
          }

          const doc = document.cloneNode(true);
          doc.querySelectorAll(STRIP).forEach(n => n.remove());

          // ---- Readability-style scoring: score the PARENTS of real paragraphs,
          // never whole-page wrappers by raw text volume.
          const scores = new Map();
          function bump(el, amount) {
            if (!el || !el.tagName) return;
            if (['BODY', 'HTML'].includes(el.tagName)) return;
            if (!scores.has(el)) scores.set(el, classWeight(el));
            scores.set(el, scores.get(el) + amount);
          }

          const blocks = doc.querySelectorAll('p, pre, blockquote, h2, h3, figure');
          blocks.forEach(el => {
            const text = (el.innerText || '').trim();
            if (text.length < 25 && !el.querySelector('img')) return;
            const commas = (text.match(/[,;:—–]/g) || []).length;
            const base = 1 + Math.min(commas, 6) + Math.min(text.length / 60, 10);
            bump(el.parentElement, base);
            const gp = el.parentElement && el.parentElement.parentElement;
            bump(gp, base / 2);
            bump(gp && gp.parentElement, base / 4);
          });

          let best = null, bestScore = 0;
          scores.forEach((score, el) => {
            const final = score * (1 - linkDensity(el));
            if (final > bestScore) { bestScore = final; best = el; }
          });

          // Climb only while the parent genuinely scores better (handles bodies split
          // across a wrapper), never as far as a page-level container.
          if (best) {
            let parent = best.parentElement;
            while (parent && !['BODY', 'HTML'].includes(parent.tagName)) {
              const ps = (scores.get(parent) || 0) * (1 - linkDensity(parent));
              if (ps > bestScore * 1.15) { best = parent; bestScore = ps; }
              parent = parent.parentElement;
            }
          }

          if (!best || ['BODY', 'HTML'].includes(best.tagName)) return { html: '', length: 0 };

          // ---- Clean the winner.
          best.querySelectorAll('*').forEach(n => {
            if (!n.tagName) return;
            const text = (n.innerText || '').trim();
            const hasMedia = n.querySelector('img,video,picture,iframe') || n.tagName === 'IMG';
            if (['P','DIV','SECTION','SPAN','LI','UL','OL','FIGURE'].includes(n.tagName)) {
              if (!text && !hasMedia) { n.remove(); return; }
              // Link lists (share bars, tag clouds, "more from us") are not prose.
              if (text.length < 300 && linkDensity(n) > 0.75 && !hasMedia) { n.remove(); return; }
              if (BAD.test(attr(n)) && text.length < 250 && !hasMedia) { n.remove(); return; }
            }
          });

          best.querySelectorAll('img').forEach(img => {
            const cand = img.getAttribute('src') || img.getAttribute('data-src') ||
                         img.getAttribute('data-original') || img.getAttribute('data-lazy-src');
            if (cand) { try { img.src = new URL(cand, document.baseURI).href; } catch (e) {} }
            if (!img.getAttribute('src')) { img.remove(); return; }
            const w = parseInt(img.getAttribute('width') || '0', 10);
            if (w && w < 60) img.remove();
            img.removeAttribute('srcset');
            img.removeAttribute('sizes');
          });

          best.querySelectorAll('a[href]').forEach(a => {
            try { a.href = new URL(a.getAttribute('href'), document.baseURI).href; } catch (e) {}
          });

          best.querySelectorAll('*').forEach(n => {
            [...n.attributes].forEach(at => {
              const keep = ['src','href','alt','title','colspan','rowspan','datetime'];
              if (!keep.includes(at.name)) n.removeAttribute(at.name);
            });
          });

          const ogImage = (document.querySelector('meta[property="og:image"]') || {}).content || null;

          return {
            html: best.innerHTML,
            length: (best.innerText || '').trim().length,
            title: document.title || null,
            image: ogImage
          };
        })();
        """#
    }
}
