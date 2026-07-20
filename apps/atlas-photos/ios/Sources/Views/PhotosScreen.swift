import SwiftUI

struct PhotosScreen: View {
    var library: Library
    @State private var showAccount = false
    @State private var pick: Asset?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if library.sections.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("Fotos")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAccount = true } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 22))
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
        }
        .sheet(isPresented: $showAccount) {
            AccountSheet(library: library)
        }
        .fullScreenCover(item: $pick) { asset in
            ViewerScreen(library: library, assets: library.assets, start: asset)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(library.sections) { section in
                    Section {
                        LazyVGrid(columns: cols, spacing: 2) {
                            ForEach(section.assets) { asset in
                                cell(asset)
                            }
                        }
                        .padding(.horizontal, 2)
                    } header: {
                        Text(section.date.sectionTitle())
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.85))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await library.refresh() }
    }

    private func cell(_ asset: Asset) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                Thumb(url: library.client.thumbURL(asset.id, 256))
                    .clipped()
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { pick = asset }
            .task { await library.loadMoreIfNeeded(current: asset) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if library.online {
                ProgressView().tint(.white)
                Text("lade Bibliothek …")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.3))
                Text("atlas nicht erreichbar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("im Tailnet? atlas wach?")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}
