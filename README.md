# Quill — a native Mac RSS reader that saves to Notion

A real SwiftUI/AppKit app. No Electron, no Xcode required to build it.

**Installed at:** `/Applications/Quill.app` — launch from Spotlight or `open -a Quill`
**Source:** this folder
**Your data:** `~/Library/Application Support/Quill/library.json` (Notion token lives in the macOS Keychain, never on disk)

---

## If the Settings window won't take your token

Run this from the Quill folder — it prompts for the token (hidden), hands it to Quill, and Quill
writes it to your Keychain and deletes the temporary file:

```bash
./add-notion-token.sh
```

Quill also logs what happens during Connect to
`~/Library/Application Support/Quill/diagnostics.log` (Settings → Notion → *Reveal diagnostics log
in Finder*). It records the token's **length and first four characters only** — never the token.

## Set up Notion — 3 steps, once

1. Go to **notion.so/my-integrations** → **New integration** → name it "Quill" → copy the **Internal Integration Secret**.
2. Open the Notion database you want articles saved into → **⋯** menu (top right) → **Connections** → add **Quill**.
   *This step is the one people skip. Without it the integration can't see the database.*
3. In Quill: **⌘,** → **Notion** tab → paste the secret → **Connect** → pick your database from the dropdown.

### Your database schema doesn't need to match anything

Quill reads your database's properties and matches them by name and type, so it works with whatever
you already have. It fills whichever of these exist:

| Your property | Gets |
|---|---|
| the Title property (any name) | article headline |
| any URL property | link to the article |
| `Source` / `Feed` / `Publication` / `Site` | which feed it came from |
| `Author` / `Byline` | byline |
| `Published` / any date property | publication date |
| `Summary` / `Excerpt` / `Description` | article snippet |
| `Notes` / `Comment` | what you typed in the save sheet |
| `Tags` / `Topics` / `Category` | your tags |
| `Status` / `Stage` | "To read" if that option exists, else the first option |

The page body always gets: your note as a callout, the excerpt as a quote, a bookmark to the
original, and a byline line. Nothing needed in Notion beyond a title property.

---

## Topics and tags

The sidebar groups by **topic**, not by source. Sources still exist as a collapsible section at
the bottom.

**Topics are automatic.** Most publishers tag their articles, and Quill folds those raw categories
into a canonical set — AI, Politics, Health, Culture, Business, Books, Parenting, Climate and a
dozen more. NYT feeds carry about 9 categories per article, so their topic assignment is dense and
accurate. Feeds with no categories at all (kottke, many personal blogs) fall back to matching the
headline, and anything left over lands in **Untagged**.

Only the publisher's own categories are trusted when they exist; a word that merely appears in a
headline is a much weaker signal and is used only as a fallback.

**Your own tags sit alongside them**, pinned to the top of the sidebar with a filled tag icon and
never rewritten by the classifier.

| | |
|---|---|
| Tag the open article | **⌘T**, or the **+ Tag** menu under the headline |
| Tag from the list | right-click → **Tags** |
| Remove a tag | click the **×** on its chip in the reader |
| Rename / delete a tag | right-click it in the sidebar |
| Show or hide sources | the **Sources** disclosure at the bottom of the sidebar |

Tags and topics pre-fill the Notion save sheet, so what you file under in Quill is what lands in
Notion.

## Using it

| | |
|---|---|
| Add a feed | **⌘N** — paste a site URL *or* a feed URL |
| Refresh everything | **⌘R** (also runs automatically every 30 min) |
| **Save to Notion** | **⇧⌘S** |
| Open original in browser | **⇧⌘O** |
| Star | **⌘L** |
| Toggle read | **⌘U** |
| Mark everything read | **⇧⌘U** |
| Settings | **⌘,** |

**Adding feeds is forgiving.** Paste `astralcodexten.substack.com` or
`https://www.nytimes.com/section/technology` and Quill finds the actual feed — it checks the URL
itself, then the page's `<link rel="alternate">` tags, then the usual `/feed`, `/rss`, `/index.xml`
paths. The Add Feed sheet also has one-click buttons for 16 NYT sections.

Right-click a feed in the sidebar to rename it, move it to a different folder, mark it all read, or
unsubscribe. Settings → Feeds shows every feed's last fetch status and exports OPML.

---

## Rebuilding after you change the code

```bash
./build.sh           # rebuild + reinstall to /Applications
./build.sh --local   # leave Quill.app in this folder instead
```

Takes ~40s. Needs only Xcode Command Line Tools, which you already have.

## Layout

```
Sources/Quill/
  QuillApp.swift            app entry, menus, keyboard shortcuts
  Model/Models.swift        Feed, Article, sidebar selection
  Model/AppState.swift      store, refresh, persistence, pruning
  Services/FeedParser.swift RSS 2.0 / RSS 1.0 / Atom parser + date + HTML helpers
  Services/FeedService.swift fetching and feed autodiscovery
  Services/NotionClient.swift Notion API + schema-matching
  Services/Keychain.swift   token storage
  Views/                    sidebar, article list, reader, sheets, settings
Tools/makeicon.swift        draws the app icon
build.sh                    compile → .app bundle → ad-hoc sign → install
```

## Full article text

Many feeds publish only a teaser. When that happens Quill loads the publisher's page in a
background WebKit view and lifts the article body out of the live DOM (a Readability-style pass:
score the parents of real paragraphs, penalise link-heavy blocks, strip nav/ads/comments, make
images and links absolute).

A line under the headline always tells you what you're reading — **Full article**, **Feed
summary**, or the reason it couldn't load — with a one-click switch between the two versions.
The toolbar's ⤓ button re-fetches on demand. Turn the automatic pass off in Settings → Reading.

**A bad extraction never replaces good content.** The result is kept only if it's meaningfully
longer than what the feed already gave you; otherwise the feed version stays and Quill says so.
Feeds that already syndicate full posts (Substack free posts, kottke, most personal blogs) are
used as-is and never fetched.

Measured on real articles: Ars Technica 5,475 chars, Platformer 24,123, Simon Willison 10,532.

### The NYT exception

**The NYT cannot be read in full inside Quill.** They return HTTP 403 and a bot-check page
("Please enable JS and disable any ad blocker") to any non-browser client, so there is no article
body to extract — this is their anti-automation system, separate from the paywall, and it is not
something to work around. Quill says so plainly in the reader and offers **Open in browser**,
where your own logged-in subscription works normally. NYT headlines, summaries, starring, and
saving to Notion all work as usual.

## Known limits

- **Paid Substack posts** are truncated in RSS and gated on the page, even when you subscribe.
- The app is ad-hoc signed, not notarized. That's fine for a locally built app; macOS may ask you to
  confirm the first launch.
- No iCloud sync of read state between machines — it's a single-Mac app.
