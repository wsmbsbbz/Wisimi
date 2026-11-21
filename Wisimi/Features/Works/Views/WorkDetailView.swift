import SwiftUI

struct WorkDetailView: View {
    let workID: Int
    let client: ASMRClient
    @ObservedObject var auth: AuthSession
    let player: WorkAudioPlayer
    let reservesMiniPlayerSpace: Bool
    let onSearch: (String, String) -> Void
    let onLoginRequired: () -> Void
    let onOpenWork: (WorkReference) -> Void
    var onOpenLocalLibrary: (() -> Void)? = nil

    @State private var downloads = DownloadStore.shared
    @State private var pageState: WorkDetailPageState
    @State private var similarWorks: SimilarWorksState
    @State private var scrollPosition = ScrollPosition()
    @State private var isMarkMenuPresented = false
    @State private var isPlaylistMenuPresented = false

    init(workID: Int, client: ASMRClient, auth: AuthSession, player: WorkAudioPlayer,
         reservesMiniPlayerSpace: Bool, onSearch: @escaping (String, String) -> Void,
         onLoginRequired: @escaping () -> Void, onOpenWork: @escaping (WorkReference) -> Void,
         onOpenLocalLibrary: (() -> Void)? = nil) {
        self.workID = workID
        self.client = client
        self.auth = auth
        self.player = player
        self.reservesMiniPlayerSpace = reservesMiniPlayerSpace
        self.onSearch = onSearch
        self.onLoginRequired = onLoginRequired
        self.onOpenWork = onOpenWork
        self.onOpenLocalLibrary = onOpenLocalLibrary
        _pageState = State(initialValue: WorkDetailPageState(client: client))
        _similarWorks = State(initialValue: SimilarWorksState(workID: workID, client: client))
    }

    var body: some View {
        Group {
            if pageState.isLoading && pageState.work == nil {
                ProgressView("加载详情中...")
            } else if let errorMessage = pageState.errorMessage, pageState.work == nil {
                RetryView(message: errorMessage) {
                    await loadDetail(force: true)
                }
            } else if let work = pageState.work {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DetailHero(work: work.presentation, onSearch: onSearch)

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                reviewAction(for: work)
                                playlistAction(for: work)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                reviewAction(for: work)
                                playlistAction(for: work)
                            }
                        }

                        if let saved = downloads.savedWork(id: work.id),
                           let summary = downloads.summary(forLocalWork: saved.localWorkID) {
                            InfoCard {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) {
                                        localCopyStatus(summary: summary)
                                        Spacer(minLength: 8)
                                        openLocalCopyButton(localWorkID: saved.localWorkID)
                                    }
                                    VStack(alignment: .leading, spacing: 10) {
                                        localCopyStatus(summary: summary)
                                        openLocalCopyButton(localWorkID: saved.localWorkID)
                                    }
                                }
                            }
                        }

                        InfoCard {
                            TrackBrowserView(
                                work: work.presentation,
                                onlineWork: work,
                                tracks: pageState.tracks,
                                currentPath: $pageState.currentPath,
                                isPathMenuExpanded: $pageState.isPathMenuExpanded,
                                player: player,
                                onOpenLocalLibrary: onOpenLocalLibrary
                            )
                        }

                        if let error = pageState.errorMessage {
                            Text("更新失败，保留已加载目录：\(error)")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if similarWorks.shouldShowSection {
                            SimilarWorksSection(state: similarWorks, onSelect: onOpenWork, onReposition: {
                                scrollPosition.scrollTo(id: "similar-works", anchor: .top)
                            })
                            .id("similar-works")
                        }

                        if reservesMiniPlayerSpace {
                            Color.clear.frame(height: miniPlayerAvoidanceHeight)
                        }
                    }
                    .padding()
                    .scrollTargetLayout()
                }
                .scrollPosition($scrollPosition)
            } else {
                EmptyStateView {
                    await loadDetail(force: true)
                }
            }
        }
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDetail(force: false)
        }
        .task(id: pageState.work?.id) {
            guard pageState.work?.id == workID else { return }
            await similarWorks.loadIfNeeded()
        }
        #if DEBUG
        .onChange(of: similarWorks.shouldShowSection) {
            if similarWorks.shouldShowSection, ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"]?.hasPrefix("similar") == true {
                similarWorks.isExpanded = ProcessInfo.processInfo.environment["WISIMI_DEBUG_SIMILAR_EXPANDED"] == "1"
                scrollPosition.scrollTo(id: "similar-works", anchor: .top)
            }
        }
        #endif
        .onChange(of: auth.token) {
            Task { await loadDetail(force: true) }
        }
    }

    private func loadDetail(force: Bool) async {
        await pageState.load(workID: workID, token: auth.token, force: force)
    }

    private func localCopyStatus(summary: DownloadSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("已下载 \(summary.completed)/\(summary.total) 个文件到本地", systemImage: "folder.fill")
                .font(.subheadline.weight(.medium))
            if summary.hasUnfinished, !summary.statusText.isEmpty {
                Text(summary.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openLocalCopyButton(localWorkID: UUID) -> some View {
        Button("打开本地作品") {
            onOpenWork(.local(localWorkID))
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }

    private func mark(_ status: ReviewStatus?) {
        guard let token = auth.token else { return }
        Task { await pageState.mark(status, token: token) }
    }

    private func reviewAction(for work: WorkDetail) -> some View {
        ReviewActionButton(
            currentStatus: work.progress,
            isLoggedIn: auth.token != nil,
            isLoading: pageState.isUpdatingMark,
            isMenuPresented: $isMarkMenuPresented,
            message: pageState.markMessage,
            onLoginRequired: onLoginRequired,
            onStatusSelected: mark
        )
    }

    private func playlistAction(for work: WorkDetail) -> some View {
        PlaylistActionButton(
            workID: work.id,
            client: client,
            token: auth.token,
            isMenuPresented: $isPlaylistMenuPresented,
            onLoginRequired: onLoginRequired
        )
    }
}

struct DetailHero: View {
    let work: WorkPresentation
    var onSearch: ((String, String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                CoverImage(
                    url: work.coverURL,
                    cornerRadius: 18,
                    size: CGSize(width: proxy.size.width, height: proxy.size.width * 3 / 4),
                    placeholderWhenMissing: work.reference.localID != nil
                )
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .overlay(alignment: .bottomLeading) {
                    if let code = work.catalogCode {
                        Text(code)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(10)
                            .copyContextMenu(code, label: work.reference.onlineID == nil ? "作品编号" : "RJ 号")
                    }
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 12) {
                Text(work.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                ChipFlowLayout(spacing: 6) {
                    if let rating = work.rating, rating > 0 {
                        MetricPill(text: String(format: "%.1f", rating), systemImage: "star.fill", prominence: .strong)
                    }

                    if work.duration != nil || work.reference.onlineID != nil {
                        MetricPill(text: work.duration.formattedDuration, systemImage: "clock", prominence: .strong)
                    }
                    if let sales = work.sales {
                        MetricPill(text: "\(sales)", systemImage: "cart", prominence: .strong)
                    }

                    if work.hasSubtitle {
                        MetricPill(text: "字幕", systemImage: "captions.bubble", prominence: .strong)
                    }

                    ForEach(work.voiceActors) { actor in
                        metadataChip(kind: "va", name: actor.name, label: "声优名称") {
                            VoiceActorChip(text: actor.name)
                        }
                    }

                    if let circle = work.circle {
                        metadataChip(kind: "circle", name: circle, label: "社团名称") {
                            CircleChip(text: circle)
                        }
                    }

                    ForEach(work.tags) { tag in
                        metadataChip(kind: "tag", name: tag.name, label: "标签") {
                            TagChip(text: tag.name)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func metadataChip<Content: View>(kind: String, name: String, label: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        Group {
            if let onSearch {
                Button { onSearch(kind, name) } label: { content() }
                    .buttonStyle(.plain)
            } else {
                content()
            }
        }
        .copyContextMenu(name, label: label)
    }
}
