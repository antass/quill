import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Binding var showAddFeed: Bool

    @State private var renaming: Feed?
    @State private var renamingTag: String?
    @AppStorage("sidebarShowsSources") private var showSources = false

    var body: some View {
        List(selection: $state.selection) {
            Section("Library") {
                libraryRow(.unread, "Unread", "circle.inset.filled")
                libraryRow(.all, "All Articles", "tray.full")
                libraryRow(.starred, "Starred", "star")
                libraryRow(.savedToNotion, "Saved to Notion", "square.and.arrow.down.on.square")
            }

            Section("Topics") {
                if state.topicIndex.isEmpty {
                    Text("Refresh to sort your articles into topics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.topicIndex) { entry in
                    topicRow(entry)
                }
                if state.untaggedCount > 0 {
                    Label("Untagged", systemImage: "questionmark.circle")
                        .badge(state.untaggedCount)
                        .tag(SidebarSelection.topic(AppState.untaggedTopic))
                }
            }

            Section(isExpanded: $showSources) {
                ForEach(state.folders, id: \.self) { folder in
                    DisclosureGroup {
                        ForEach(state.feeds.filter { $0.folder == folder }
                            .sorted(by: { $0.title < $1.title })) { feed in
                            feedRow(feed)
                        }
                    } label: {
                        Label(folder, systemImage: "folder")
                            .badge(state.unreadCount(for: .folder(folder)))
                            .tag(SidebarSelection.folder(folder))
                    }
                }
            } header: {
                Text("Sources")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(item: $renaming) { feed in RenameFeedSheet(feed: feed) }
        .sheet(item: $renamingTag) { tag in RenameTagSheet(tag: tag) }
        .toolbar {
            ToolbarItem {
                Button { showAddFeed = true } label: { Image(systemName: "plus") }
                    .help("Add a feed (\u{2318}N)")
            }
        }
    }

    private func libraryRow(_ sel: SidebarSelection, _ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .badge(state.unreadCount(for: sel))
            .tag(sel)
    }

    private func topicRow(_ entry: AppState.TopicEntry) -> some View {
        Label {
            HStack(spacing: 5) {
                Text(entry.name).lineLimit(1)
                if entry.isManual {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("Your own tag")
                }
            }
        } icon: {
            Image(systemName: entry.isManual ? "tag.fill" : Topics.icon(for: entry.name))
                .foregroundStyle(entry.isManual ? Color.accentColor : Color.secondary)
        }
        .badge(entry.unread)
        .tag(SidebarSelection.topic(entry.name))
        .help("\(entry.total) article\(entry.total == 1 ? "" : "s")")
        .contextMenu {
            Button("Mark All Read") {
                for a in state.articles where a.topics.contains(where: { $0.caseInsensitiveCompare(entry.name) == .orderedSame }) {
                    state.markRead(a)
                }
            }
            if entry.isManual {
                Divider()
                Button("Rename Tag\u{2026}") { renamingTag = entry.name }
                Button("Delete Tag", role: .destructive) { state.deleteTag(entry.name) }
            }
        }
    }

    private func feedRow(_ feed: Feed) -> some View {
        Label {
            Text(feed.title).lineLimit(1)
        } icon: {
            Image(systemName: feed.lastError == nil ? "dot.radiowaves.up.forward" : "exclamationmark.triangle")
                .foregroundStyle(feed.lastError == nil ? Color.accentColor : Color.orange)
        }
        .badge(state.unreadCount(for: .feed(feed.id)))
        .tag(SidebarSelection.feed(feed.id))
        .help(feed.lastError ?? feed.feedURL.absoluteString)
        .contextMenu {
            Button("Refresh") { Task { await state.refresh(feed) } }
            Button("Rename\u{2026}") { renaming = feed }
            if let site = feed.siteURL {
                Button("Open Website") { NSWorkspace.shared.open(site) }
            }
            Button("Copy Feed URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(feed.feedURL.absoluteString, forType: .string)
            }
            Divider()
            Button("Mark All Read") {
                for a in state.articles where a.feedID == feed.id { state.markRead(a) }
            }
            Divider()
            Button("Unsubscribe", role: .destructive) { state.remove(feed) }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text(state.refreshProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Button {
                        Task { await state.refreshAll() }
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if state.settings.notionDatabaseID.isEmpty {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help("Notion isn't connected yet \u{2014} open Settings (\u{2318},)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

// String needs an identity to drive .sheet(item:)
extension String: @retroactive Identifiable {
    public var id: String { self }
}

struct RenameTagSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let tag: String
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Tag").font(.headline)
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = tag }
    }

    private func apply() {
        state.renameTag(tag, to: name)
        dismiss()
    }
}

struct RenameFeedSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let feed: Feed
    @State private var title = ""
    @State private var folder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Feed").font(.headline)
            Form {
                TextField("Name", text: $title)
                TextField("Folder", text: $folder)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    state.rename(feed, to: title, folder: folder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { title = feed.title; folder = feed.folder }
    }
}
