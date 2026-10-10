import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            NotionSettings().tabItem { Label("Notion", systemImage: "square.and.arrow.down") }
            ReadingSettings().tabItem { Label("Reading", systemImage: "book") }
            FeedSettings().tabItem { Label("Feeds", systemImage: "dot.radiowaves.up.forward") }
        }
        .frame(width: 640, height: 640)
    }
}

// MARK: - Notion

struct NotionSettings: View {
    @EnvironmentObject var state: AppState

    @State private var token = ""
    @State private var revealToken = false
    @State private var databases: [NotionDatabaseRef] = []
    @State private var connecting = false
    @State private var status: Status = .idle
    @State private var tagText = ""

    enum Status: Equatable {
        case idle
        case working(String)
        case ok(String)
        case bad(String)

        var text: String? {
            switch self {
            case .idle: return nil
            case .working(let s), .ok(let s), .bad(let s): return s
            }
        }
    }

    var body: some View {
        Form {
            tokenSection
            databaseSection
            optionsSection
        }
        .formStyle(.grouped)
        .onAppear {
            Diag.log("settings.notion.appear (existing token \(Diag.shape(token)))")
            if let imported = TokenImport.importIfPresent() {
                status = .ok(imported)
            }
            // Only seed from the Keychain when the field is untouched, so re-appearing
            // (tab switches, window refocus) can never wipe what was just typed.
            if token.isEmpty, let stored = Keychain.get("notion-token") {
                token = stored
                status = .ok("Token loaded from Keychain.")
            }
            tagText = state.settings.defaultTags.joined(separator: ", ")
            if !token.isEmpty && databases.isEmpty { Task { await fetchDatabases() } }
        }
    }

    // MARK: Step 1

    private var tokenSection: some View {
        Section {
            HStack(spacing: 6) {
                // A visible field by default: with a SecureField you can't tell whether a
                // paste or a password-manager autofill actually landed.
                Group {
                    if revealToken {
                        TextField("ntn_… or secret_…", text: $token)
                    } else {
                        SecureField("ntn_… or secret_…", text: $token)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { connect() }

                Button {
                    revealToken.toggle()
                } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye")
                }
                .help(revealToken ? "Hide token" : "Show token")

                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        token = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        revealToken = true
                        status = .idle
                    } else {
                        status = .bad("Clipboard is empty.")
                    }
                }
                .help("Paste the token straight from the clipboard")
            }

            HStack(spacing: 10) {
                // Deliberately never disabled — a disabled button that does nothing when
                // clicked is indistinguishable from a broken one.
                Button("Connect to Notion") { connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                if connecting { ProgressView().controlSize(.small) }

                if let text = status.text {
                    Label(text, systemImage: statusIcon)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if !state.settings.notionWorkspace.isEmpty {
                HStack {
                    Label("Connected to \(state.settings.notionWorkspace)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Spacer()
                    Button("Disconnect") {
                        Keychain.delete("notion-token")
                        token = ""
                        databases = []
                        state.settings.notionWorkspace = ""
                        state.settings.notionDatabaseID = ""
                        state.settings.notionDatabaseTitle = ""
                        status = .ok("Token removed.")
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Step 1 \u{2014} Integration token")
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("a. notion.so/my-integrations \u{2192} New integration \u{2192} copy the Internal Integration Secret.")
                Text("b. Open the database you want to save into \u{2192} \u{22EF} menu \u{2192} Connections \u{2192} add that integration.")
                Text("Step b is the one people skip \u{2014} without it Notion hides every database from the token.")
                    .foregroundStyle(.orange)
                Button("Open notion.so/my-integrations") {
                    NSWorkspace.shared.open(URL(string: "https://www.notion.so/my-integrations")!)
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Step 2

    private var databaseSection: some View {
        Section {
            if databases.isEmpty {
                Text(state.settings.notionDatabaseTitle.isEmpty
                     ? "Connect above and your databases will appear here."
                     : "Currently saving to: \(state.settings.notionDatabaseTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Database", selection: $state.settings.notionDatabaseID) {
                    Text("\u{2014} none \u{2014}").tag("")
                    ForEach(databases) { db in Text(db.title).tag(db.id) }
                }
                .onChange(of: state.settings.notionDatabaseID) { _, new in
                    state.settings.notionDatabaseTitle = databases.first { $0.id == new }?.title ?? ""
                    Task { await NotionClient.shared.clearSchemaCache() }
                }
            }

            Button("Refresh database list") { Task { await fetchDatabases() } }
                .font(.callout)
                .disabled(connecting)
        } header: {
            Text("Step 2 \u{2014} Where articles go")
        } footer: {
            Text("Quill matches your database's own properties by name and type \u{2014} Title, URL, Source, Author, Published, Summary, Notes, Tags, Status. It fills what exists and ignores the rest, so no particular schema is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Button("Reveal diagnostics log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Diag.logURL])
            }
            .font(.callout)
            TextField("Default tags", text: $tagText)
                .onChange(of: tagText) { _, new in
                    state.settings.defaultTags = new.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
        }
    }

    private var statusIcon: String {
        switch status {
        case .idle: return "info.circle"
        case .working: return "clock"
        case .ok: return "checkmark.circle.fill"
        case .bad: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle, .working: return .secondary
        case .ok: return .green
        case .bad: return .orange
        }
    }

    // MARK: Actions

    private func connect() {
        Diag.log("connect.pressed token=\(Diag.shape(token)) connecting=\(connecting)")
        guard !connecting else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            Diag.log("connect.abort empty field")
            status = .bad("Paste your integration token into the field first.")
            return
        }
        guard trimmed.count > 20 else {
            Diag.log("connect.abort too short \(Diag.shape(trimmed))")
            status = .bad("That looks too short to be a Notion token (got \(trimmed.count) characters).")
            return
        }

        connecting = true
        status = .working("Saving token\u{2026}")

        if let keychainError = Keychain.set(trimmed, for: "notion-token") {
            Diag.log("connect.keychain FAILED \(keychainError)")
            status = .bad(keychainError)
            connecting = false
            return
        }
        Diag.log("connect.keychain stored ok")

        status = .working("Checking with Notion\u{2026}")
        Task {
            do {
                let workspace = try await NotionClient.shared.validateToken()
                Diag.log("connect.validate ok workspace=\(workspace)")
                state.settings.notionWorkspace = workspace
                status = .working("Connected to \(workspace) \u{2014} loading databases\u{2026}")
                await fetchDatabases()
            } catch {
                Diag.log("connect.validate FAILED \(error.localizedDescription)")
                state.settings.notionWorkspace = ""
                status = .bad(error.localizedDescription)
            }
            connecting = false
        }
    }

    private func fetchDatabases() async {
        do {
            let found = try await NotionClient.shared.listDatabases()
            databases = found
            if found.isEmpty {
                status = .bad("Token works, but no databases are shared with it yet. In Notion, open your database \u{2192} \u{22EF} \u{2192} Connections \u{2192} add this integration, then hit Refresh.")
            } else {
                if state.settings.notionDatabaseID.isEmpty, let first = found.first {
                    state.settings.notionDatabaseID = first.id
                    state.settings.notionDatabaseTitle = first.title
                }
                status = .ok("Ready \u{2014} \(found.count) database\(found.count == 1 ? "" : "s") available.")
            }
        } catch {
            status = .bad(error.localizedDescription)
        }
    }
}

// MARK: - Reading

struct ReadingSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Refreshing") {
                Picker("Check feeds every", selection: $state.settings.refreshMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                }
                .onChange(of: state.settings.refreshMinutes) { _, _ in state.restartTimer() }
            }

            Section {
                Toggle("Load full articles automatically", isOn: $state.settings.autoLoadFullText)
            } header: {
                Text("Full text")
            } footer: {
                Text("When a feed publishes only a teaser, Quill opens the publisher's page in the background and pulls out the article body. Sites that block automated readers — the NYT among them — will say so instead, and you can open those in your browser. Feeds that already syndicate full posts are used as-is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Mark articles read when opened", isOn: $state.settings.markReadOnOpen)
                Picker("Sort articles", selection: $state.settings.sort) {
                    ForEach(ArticleSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Keep \(state.settings.keepPerFeed) articles per feed",
                        value: $state.settings.keepPerFeed, in: 50...1000, step: 50)
            }

            Section("Shortcuts") {
                LabeledContent("Refresh all feeds", value: "\u{2318}R")
                LabeledContent("Add a feed", value: "\u{2318}N")
                LabeledContent("Save to Notion", value: "\u{21E7}\u{2318}S")
                LabeledContent("Open in browser", value: "\u{21E7}\u{2318}O")
                LabeledContent("Star / unstar", value: "\u{2318}L")
                LabeledContent("Toggle read", value: "\u{2318}U")
                LabeledContent("Mark all read", value: "\u{21E7}\u{2318}U")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Feeds

struct FeedSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(state.feeds.sorted { $0.folder + $0.title < $1.folder + $1.title }) {
                TableColumn("Feed") { feed in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feed.title).lineLimit(1)
                        Text(feed.feedURL.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                TableColumn("Folder") { feed in Text(feed.folder) }.width(90)
                TableColumn("Status") { feed in
                    if let error = feed.lastError {
                        Text(error).foregroundStyle(.orange).lineLimit(1).help(error)
                    } else if let date = feed.lastFetched {
                        Text(date, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never fetched").foregroundStyle(.tertiary)
                    }
                }
                .width(130)
            }

            Divider()

            HStack {
                Text("\(state.feeds.count) feeds \u{00B7} \(state.articles.count) articles stored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export OPML\u{2026}") { exportOPML() }
                Button("Refresh All") { Task { await state.refreshAll() } }
                    .disabled(state.isRefreshing)
            }
            .padding(12)
        }
    }

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "quill-feeds.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0"><head><title>Quill Feeds</title></head><body>
        """
        for folder in state.folders {
            xml += "\n<outline text=\"\(escape(folder))\">"
            for feed in state.feeds where feed.folder == folder {
                xml += "\n  <outline type=\"rss\" text=\"\(escape(feed.title))\" xmlUrl=\"\(escape(feed.feedURL.absoluteString))\"/>"
            }
            xml += "\n</outline>"
        }
        xml += "\n</body></opml>\n"
        try? xml.write(to: url, atomically: true, encoding: .utf8)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
