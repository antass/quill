import SwiftUI
import AppKit

struct SaveToNotionSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let article: Article

    @State private var notes = ""
    @State private var tagText = ""
    @State private var status = ""
    @State private var statusOptions: [String] = []
    @State private var saving = false
    @State private var error: String?
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.settings.notionDatabaseID.isEmpty {
                notConnected
            } else {
                form
            }
        }
        .frame(width: 540)
        .task { await loadStatusOptions() }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Notion isn't connected yet", systemImage: "link.badge.plus")
                .font(.title3.bold())
            Text("Open Settings (\u{2318},) \u{2192} Notion, paste an integration token, and pick the database you want articles saved to.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open Settings") {
                    dismiss()
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save to Notion").font(.title3.bold())
                Text(state.settings.notionDatabaseTitle.isEmpty
                     ? "Selected database"
                     : state.settings.notionDatabaseTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title)
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(state.feed(article.feedID)?.title ?? "")
                            if let link = article.link {
                                Text("\u{00B7}")
                                Text(link.host ?? "").lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Why it's interesting").font(.callout.weight(.medium))
                        TextEditor(text: $notes)
                            .font(.system(size: 12.5))
                            .frame(height: 84)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.25)))
                            .focused($notesFocused)
                        Text("Goes into a Notes property if your database has one, and into a callout at the top of the page.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Tags").font(.callout.weight(.medium))
                        TextField("comma, separated", text: $tagText)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !statusOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Status").font(.callout.weight(.medium))
                            Picker("", selection: $status) {
                                Text("Default").tag("")
                                ForEach(statusOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            .frame(maxHeight: 380)

            Divider()

            HStack {
                if article.savedToNotion {
                    Label("Already saved once", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .onAppear {
            status = state.settings.defaultStatus
            // Seed from the article's own tags and topics, then the configured defaults.
            let seeded = article.topics + state.settings.defaultTags
            var seen = Set<String>()
            tagText = seeded.filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { notesFocused = true }
        }
    }

    private func loadStatusOptions() async {
        guard !state.settings.notionDatabaseID.isEmpty else { return }
        guard let props = try? await NotionClient.shared.schema(for: state.settings.notionDatabaseID) else { return }
        let candidates = props.filter {
            ($0.type == "status" || $0.type == "select")
            && ($0.name.lowercased().contains("status") || $0.name.lowercased().contains("stage"))
        }
        statusOptions = candidates.flatMap(\.options)
    }

    private func save() {
        saving = true
        error = nil
        let tags = tagText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            do {
                try await state.saveToNotion(article, notes: notes, tags: tags, status: status)
                saving = false
                dismiss()
            } catch {
                saving = false
                self.error = error.localizedDescription
            }
        }
    }
}
