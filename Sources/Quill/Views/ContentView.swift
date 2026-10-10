import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Binding var showAddFeed: Bool
    @Binding var showSaveSheet: Bool
    @Binding var showTagSheet: Bool

    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showAddFeed: $showAddFeed)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } content: {
            ArticleListView(showSaveSheet: $showSaveSheet)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        } detail: {
            ReaderView(showSaveSheet: $showSaveSheet)
        }
        .overlay(alignment: .bottom) { bannerView }
        .sheet(isPresented: $showAddFeed) { AddFeedSheet() }
        .sheet(isPresented: $showSaveSheet) {
            if let article = state.selectedArticle {
                SaveToNotionSheet(article: article)
            }
        }
        .sheet(isPresented: $showTagSheet) {
            if let article = state.selectedArticle {
                AddTagSheet(article: article)
            }
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = state.banner {
            HStack(spacing: 8) {
                Image(systemName: icon(banner.kind))
                Text(banner.text).lineLimit(2)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color(banner.kind).opacity(0.45)))
            .foregroundStyle(color(banner.kind))
            .shadow(radius: 12, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                withAnimation { if state.banner?.id == banner.id { state.banner = nil } }
            }
        }
    }

    private func icon(_ kind: AppState.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: AppState.Banner.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .failure: return .orange
        }
    }
}
