import SwiftUI

struct WorksListView: View {
    private let client: ASMRClient
    @StateObject private var player: WorkAudioPlayer
    @State private var works: [WorkSummary] = []
    @State private var pagination: WorksPagination?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedWorkID: Int?
    @State private var isShowingPlayer = false
    @State private var currentPage = 1

    init() {
        let client = ASMRClient()
        self.client = client
        _player = StateObject(wrappedValue: WorkAudioPlayer(client: client))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && works.isEmpty {
                    ProgressView("加载作品中...")
                } else if let errorMessage, works.isEmpty {
                    RetryView(message: errorMessage) {
                        await loadWorks(page: currentPage)
                    }
                } else if works.isEmpty {
                    EmptyStateView {
                        await loadWorks(page: 1)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear
                                .frame(height: 0)
                                .id("top")

                            VStack(spacing: 18) {
                                MasonryGrid(works: works) { work in
                                    selectedWorkID = work.id
                                }

                                PaginationControls(
                                    currentPage: currentPage,
                                    totalPages: pagination?.totalPages,
                                    isLoading: isLoading
                                ) { page in
                                    Task {
                                        await loadWorks(page: page)
                                        withAnimation {
                                            proxy.scrollTo("top", anchor: .top)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .background(.background)
                        .refreshable {
                            await loadWorks(page: 1)
                            withAnimation {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Wisimi")
            .toolbar {
                if isLoading && !works.isEmpty {
                    ProgressView()
                }
            }
            .navigationDestination(isPresented: isShowingDetail) {
                if let selectedWorkID {
                    WorkDetailView(workID: selectedWorkID, client: client, player: player)
                }
            }
            .navigationDestination(isPresented: $isShowingPlayer) {
                PlayerView(player: player)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerBar(player: player) {
                    isShowingPlayer = true
                }
            }
        }
        .task {
            await loadWorks(page: currentPage)
        }
    }

    private var isShowingDetail: Binding<Bool> {
        Binding {
            selectedWorkID != nil
        } set: { isPresented in
            if !isPresented {
                selectedWorkID = nil
            }
        }
    }

    private func loadWorks(page: Int = 1) async {
        guard !isLoading else { return }
        if let totalPages = pagination?.totalPages, page > totalPages { return }
        guard page >= 1 else { return }

        isLoading = true
        errorMessage = nil
        do {
            let response = try await client.fetchWorks(page: page)
            works = response.works
            pagination = response.pagination
            currentPage = response.pagination.currentPage
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MiniPlayerBar: View {
    @ObservedObject var player: WorkAudioPlayer
    let openPlayer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openPlayer) {
                HStack(spacing: 10) {
                    CoverImage(url: player.coverURL, cornerRadius: 6, size: CGSize(width: 42, height: 42))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.currentTrack?.title ?? "未播放")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(player.currentSubtitle?.text ?? player.workTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

private struct MasonryGrid: View {
    private let columnSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 12

    let works: [WorkSummary]
    let onSelect: (WorkSummary) -> Void
    @State private var availableWidth: CGFloat = 0

    private var leftColumn: [WorkSummary] {
        works.enumerated().compactMap { index, work in
            index.isMultiple(of: 2) ? work : nil
        }
    }

    private var rightColumn: [WorkSummary] {
        works.enumerated().compactMap { index, work in
            index.isMultiple(of: 2) ? nil : work
        }
    }

    private var columnWidth: CGFloat {
        max(floor((availableWidth - columnSpacing) / 2), 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    availableWidth = width
                }

            if columnWidth > 0 {
                HStack(alignment: .top, spacing: columnSpacing) {
                    column(leftColumn)
                    column(rightColumn)
                }
                .frame(width: availableWidth, alignment: .leading)
                .clipped()
            }
        }
    }

    private func column(_ works: [WorkSummary]) -> some View {
        LazyVStack(spacing: rowSpacing) {
            ForEach(works) { work in
                Button {
                    onSelect(work)
                } label: {
                    WorkRow(work: work, width: columnWidth)
                }
                .buttonStyle(.plain)
                .frame(width: columnWidth)
                .clipped()
            }
        }
        .frame(width: columnWidth, alignment: .top)
        .clipped()
    }
}

private struct PaginationControls: View {
    let currentPage: Int
    let totalPages: Int?
    let isLoading: Bool
    let onPageChanged: (Int) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button {
                onPageChanged(currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPage <= 1 || isLoading)

            Text("\(currentPage)/\(totalPages.map(String.init) ?? "?")")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 64)

            Button {
                onPageChanged(currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(totalPages.map { currentPage >= $0 } ?? true || isLoading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

#Preview {
    WorksListView()
}
