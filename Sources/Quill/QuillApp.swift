import SwiftUI
import AppKit

@main
struct QuillApp: App {
    @StateObject private var state = AppState()
    @State private var showAddFeed = false
    @State private var showSaveSheet = false
    @State private var showTagSheet = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView(showAddFeed: $showAddFeed, showSaveSheet: $showSaveSheet, showTagSheet: $showTagSheet)
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 620)
                .task { await state.refreshAll() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Feed\u{2026}") { showAddFeed = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Reading") {
                Button("Refresh All Feeds") {
                    Task { await state.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isRefreshing)

                Divider()

                Button("Save to Notion\u{2026}") { showSaveSheet = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(state.selectedArticle == nil)

                Button("Open in Browser") {
                    if let url = state.selectedArticle?.link { NSWorkspace.shared.open(url) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(state.selectedArticle?.link == nil)

                Divider()

                Button("Toggle Star") {
                    if let a = state.selectedArticle { state.toggleStar(a) }
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(state.selectedArticle == nil)

                Button("Toggle Read") {
                    if let a = state.selectedArticle { state.toggleRead(a) }
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(state.selectedArticle == nil)

                Button("Mark All as Read") { state.markAllRead() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                Button("Add Tag\u{2026}") { showTagSheet = true }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(state.selectedArticle == nil)
            }

            CommandGroup(after: .appSettings) {
                Button("Sign In to a Publisher\u{2026}") { openWindow(id: "publisher-login") }
            }
        }

        Window("Sign In to a Publisher", id: "publisher-login") {
            PublisherLoginView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}
