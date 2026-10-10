import SwiftUI

struct AddFeedSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var folder = "Feeds"
    @State private var working = false
    @State private var error: String?

    private let nytSections: [(String, String)] = [
        ("Home Page", "HomePage"), ("World", "World"), ("U.S.", "US"),
        ("Business", "Business"), ("Technology", "Technology"), ("Science", "Science"),
        ("Health", "Health"), ("Well", "Well"), ("Food", "Food"), ("Travel", "Travel"),
        ("Books", "Books"), ("Arts", "Arts"), ("Movies", "Movies"),
        ("Real Estate", "RealEstate"), ("Parenting", "NYTParenting"), ("Opinion", "Opinion")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Feed").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                TextField("Paste a website or feed URL", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { add() }
                Text("Works with a plain site address too \u{2014} Quill finds the feed. For Substack, the newsletter's home page is enough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Folder")
                Picker("", selection: $folder) {
                    ForEach(folderOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
            }

            DisclosureGroup("Add a New York Times section") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(nytSections, id: \.1) { name, slug in
                        Button(name) {
                            input = "https://rss.nytimes.com/services/xml/rss/nyt/\(slug).xml"
                            folder = "News"
                            add()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Looking for a feed\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Feed") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var folderOptions: [String] {
        var options = Set(state.feeds.map(\.folder))
        options.formUnion(["Feeds", "News", "Substack", "Blogs"])
        return options.sorted()
    }

    private func add() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let before = state.feeds.count
            await state.addFeed(from: text, folder: folder)
            working = false
            if state.feeds.count > before {
                input = ""
                if let banner = state.banner, banner.kind == .success { error = nil }
            } else if let banner = state.banner, banner.kind == .failure {
                error = banner.text
            }
        }
    }
}
