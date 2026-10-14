import SwiftUI

struct WorkDetailView: View {
    let workID: Int
    let client: ASMRClient
    @ObservedObject var auth: AuthSession
    let player: WorkAudioPlayer
    let reservesMiniPlayerSpace: Bool
    let onSearch: (String, String) -> Void
    let onLoginRequired: () -> Void

    @State private var downloads = DownloadStore.shared
    @State private var pageState: WorkDetailPageState
    @State private var scrollPosition = ScrollPosition()
    @State private var isMarkMenuPresented = false
    @State private var isPlaylistMenuPresented = false

    init(workID: Int, client: ASMRClient, auth: AuthSession, player: WorkAudioPlayer,
         reservesMiniPlayerSpace: Bool, onSearch: @escaping (String, String) -> Void,
         onLoginRequired: @escaping () -> Void) {
        self.workID = workID
        self.client = client
        self.auth = auth
        self.player = player
        self.reservesMiniPlayerSpace = reservesMiniPlayerSpace
        self.onSearch = onSearch
        self.onLoginRequired = onLoginRequired
        _pageState = State(initialValue: WorkDetailPageState(client: client))
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
                        DetailHero(work: work, onSearch: onSearch)

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

                        InfoCard {
                            TrackBrowserView(
                                work: work,
                                tracks: pageState.tracks,
                                currentPath: $pageState.currentPath,
                                isPathMenuExpanded: $pageState.isPathMenuExpanded,
                                player: player
                            )
                            .id("track-browser")
                        }

                        if let error = pageState.errorMessage {
                            Text("更新失败，保留已加载目录：\(error)")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if reservesMiniPlayerSpace {
                            Color.clear.frame(height: miniPlayerAvoidanceHeight)
                        }
                    }
                    .padding()
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: WorksRoute.downloads) {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
            }
        }
        .task {
            await loadDetail(force: false)
        }
        #if DEBUG
        .onChange(of: pageState.work?.id) {
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"]?.hasPrefix("download") == true {
                scrollPosition.scrollTo(id: "track-browser", anchor: .top)
            }
        }
        #endif
        .onChange(of: auth.token) {
            Task { await loadDetail(force: true) }
        }
    }

    private func loadDetail(force: Bool) async {
        #if DEBUG
        if workID == 99999999, ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"]?.hasPrefix("download") == true {
            while downloads.savedWork(id: workID) == nil { try? await Task.sleep(for: .milliseconds(20)) }
            let saved = downloads.savedWork(id: workID)!
            pageState.prepareDebugSnapshot(saved)
            return
        }
        #endif
        await pageState.load(workID: workID, token: auth.token, force: force)
    }

    private func toggleMark() {
        guard let work = pageState.work else { return }
        guard let token = auth.token else { onLoginRequired(); return }
        guard work.progress != nil else { isMarkMenuPresented.toggle(); return }
        Task { await pageState.mark(nil, token: token) }
    }

    private func mark(_ status: ReviewStatus) {
        guard let token = auth.token else { return }
        Task { await pageState.mark(status, token: token) }
    }

    private func reviewAction(for work: WorkDetail) -> some View {
        ReviewActionButton(
            isMarked: work.progress != nil,
            currentStatus: work.progress,
            isLoading: pageState.isUpdatingMark,
            isMenuPresented: $isMarkMenuPresented,
            message: pageState.markMessage,
            action: toggleMark,
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
    let work: WorkDetail
    let onSearch: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                CoverImage(
                    url: work.mainCoverURL,
                    cornerRadius: 18,
                    size: CGSize(width: proxy.size.width, height: proxy.size.width * 3 / 4)
                )
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .overlay(alignment: .bottomLeading) {
                    Text(work.rjCode)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(10)
                        .copyContextMenu(work.rjCode, label: "RJ 号")
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
                    if let rateAverage = work.rateAverage, rateAverage > 0 {
                        MetricPill(text: work.ratingText, systemImage: "star.fill", prominence: .strong)
                    }

                    MetricPill(text: work.durationText, systemImage: "clock", prominence: .strong)
                    MetricPill(text: "\(work.dlCount)", systemImage: "cart", prominence: .strong)

                    if work.hasSubtitle {
                        MetricPill(text: "字幕", systemImage: "captions.bubble", prominence: .strong)
                    }

                    ForEach(work.vas) { actor in
                        Button {
                            onSearch("va", actor.name)
                        } label: {
                            VoiceActorChip(text: actor.name)
                        }
                        .buttonStyle(.plain)
                        .copyContextMenu(actor.name, label: "声优名称")
                    }

                    Button {
                        onSearch("circle", work.name)
                    } label: {
                        CircleChip(text: work.name)
                    }
                    .buttonStyle(.plain)
                    .copyContextMenu(work.name, label: "社团名称")

                    ForEach(work.tags) { tag in
                        Button {
                            onSearch("tag", tag.name)
                        } label: {
                            TagChip(text: tag.name)
                        }
                        .buttonStyle(.plain)
                        .copyContextMenu(tag.name, label: "标签")
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
}
