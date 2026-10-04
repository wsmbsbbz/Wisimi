import SwiftUI
import UIKit

struct WorksListView: View {
    private let client: ASMRClient
    @StateObject private var player: WorkAudioPlayer
    @StateObject private var auth: AuthSession
    @StateObject private var ttsSettings: TTSMixSettings
    @State private var path: [WorksRoute] = []
    @State private var browser: WorksBrowserState
    private var pageState: WorksPageState { browser.page }

    private var works: [WorkSummary] { pageState.works }
    private var pagination: WorksPagination? { pageState.pagination }
    private var isLoading: Bool { pageState.isLoading }
    private var errorMessage: String? { pageState.errorMessage }
    private var currentPage: Int { pageState.currentPage }
    @State private var searchText = ""
    private var catalog: PlaylistCatalog { browser.catalog }
    @State private var isFilterPresented = false
    @State private var isLoginPresented = false
    @State private var isNarrationSettingsPresented = false
    @State private var pendingMode: WorksMode?
    @FocusState private var isSearchFocused: Bool

    init() {
        let client = ASMRClient()
        let ttsSettings = TTSMixSettings()
        self.client = client
        _browser = State(initialValue: WorksBrowserState(client: client, catalog: PlaylistCatalog(client: client)))
        _ttsSettings = StateObject(wrappedValue: ttsSettings)
        let player = WorkAudioPlayer(client: client, ttsSettings: ttsSettings)
        _player = StateObject(wrappedValue: player)
        _auth = StateObject(wrappedValue: AuthSession(client: client))
        #if DEBUG
        let debugScreen = ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"]
        _isNarrationSettingsPresented = State(initialValue: debugScreen == "tts-settings" || debugScreen == "openrouter-credentials")
        if debugScreen?.hasPrefix("downloads") == true {
            _path = State(initialValue: [.downloads])
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_DOWNLOAD_MINIPLAYER"] == "1" {
                try? player.prepareDebugPlayback()
            }
        }
        if debugScreen == "download-detail" || debugScreen == "download-selection" { _path = State(initialValue: [.detail(99999999)]) }
        if debugScreen == "player" || debugScreen == "mini-player" || debugScreen == "video" {
            try? player.prepareDebugPlayback()
            if ProcessInfo.processInfo.environment["WISIMI_SLEEP_TIMER"] == "1" {
                player.setSleepTimer(.deadline(.now.addingTimeInterval(1800)))
            }
            _path = State(initialValue: debugScreen != "mini-player" ? [.player] : [])
        }
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("top")

                    VStack(spacing: 18) {
                        WorksSearchHeader(
                            searchText: $searchText,
                            activeSearchText: browser.keyword,
                            selectedMode: browser.mode,
                            filter: browser.filter,
                            reviewFilter: browser.reviewFilter,
                            selectedPlaylist: catalog.selectedPlaylist,
                            isSearchFocused: $isSearchFocused,
                            onSearch: runSearch,
                            onClearSearch: clearSearch,
                            onModeSelected: selectMode,
                            onFilter: { isFilterPresented = true }
                        )

                        if isLoading && works.isEmpty {
                            ProgressView("加载作品中...")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if let errorMessage, works.isEmpty {
                            RetryView(message: errorMessage) {
                                await loadWorks(page: pageState.requestedPage)
                            }
                        } else if works.isEmpty {
                            EmptyStateView {
                                await loadWorks(page: 1)
                            }
                        } else {
                            VStack(spacing: 18) {
                                if let errorMessage {
                                    InlineRetryView(message: errorMessage) {
                                        Task { await loadWorks(page: pageState.requestedPage) }
                                    }
                                }
                                MasonryGrid(works: works) { work in
                                    path.append(.detail(work.id))
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
                        }

                        if shouldShowMiniPlayer {
                            Color.clear.frame(height: miniPlayerAvoidanceHeight)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if auth.isLoggedIn {
                            Button("退出登录", role: .destructive) {
                                auth.logout()
                                if browser.mode.requiresLogin {
                                    browser.mode = .latest
                                    Task { await reloadFromFirstPage() }
                                }
                            }
                        } else {
                            Button {
                                isLoginPresented = true
                            } label: {
                                Label("登录", systemImage: "person.crop.circle")
                            }
                        }

                        Button {
                            isNarrationSettingsPresented = true
                        } label: {
                            Label("混音", systemImage: "speaker.wave.2")
                        }
                    } label: {
                        Label(auth.username ?? "菜单", systemImage: auth.isLoggedIn ? "person.crop.circle.fill" : "ellipsis.circle")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(.downloads)
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isLoading && !works.isEmpty {
                        ProgressView()
                    }
                }
            }
            .navigationDestination(for: WorksRoute.self) { route in
                switch route {
                case .detail(let workID):
                    WorkDetailView(
                        workID: workID,
                        client: client,
                        auth: auth,
                        player: player,
                        reservesMiniPlayerSpace: shouldShowMiniPlayer,
                        onSearch: search,
                        onLoginRequired: { isLoginPresented = true }
                    )
                case .downloads:
                    DownloadsView { path.append(.detail($0)) }
                case .player:
                    PlayerView(player: player, openWorkDetail: openPlayingWorkDetail)
                }
            }
            .sheet(isPresented: $isFilterPresented) {
                WorksFilterSheet(
                    context: browser.filterContext,
                    filter: browser.filter,
                    reviewFilter: browser.reviewFilter,
                    catalog: catalog,
                    token: auth.token
                ) { newFilter in
                    browser.filter = newFilter
                    Task { await reloadFromFirstPage() }
                } onApplyReviewFilter: { newFilter in
                    browser.reviewFilter = newFilter
                    Task { await reloadFromFirstPage() }
                } onApplyPlaylist: { playlistID in
                    catalog.selectedID = playlistID
                    Task { await reloadFromFirstPage() }
                } onCatalogChanged: {
                    Task { await reloadFromFirstPage() }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isLoginPresented) {
                LoginSheet(auth: auth) {
                    if let mode = pendingMode {
                        pendingMode = nil
                        selectMode(mode)
                    }
                }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $isNarrationSettingsPresented) {
                TTSMixSettingsSheet(settings: ttsSettings)
                    .presentationDetents([.large])
            }
        }
        .safeAreaInset(edge: .bottom) {
            if shouldShowMiniPlayer {
                MiniPlayerBar(player: player) {
                    openPlayer()
                }
            }
        }
        .onChange(of: auth.token) { catalog.reset() }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["WISIMI_DOWNLOAD_PLAYBACK_CHECKS"] == "1" {
                do { try await player.runDownloadedMediaCheck() }
                catch { assertionFailure("Downloaded media check failed: \(error)") }
                return
            }
            if let screen = ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"], screen.hasPrefix("download") {
                do { try await DownloadStore.shared.prepareDebugDownloads() }
                catch { DownloadStore.shared.message = error.localizedDescription }
                return
            }
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] == "list-error" {
                let json = #"{"works":[{"id":1,"title":"晚安 · 轻声陪伴与耳边细语","name":"Wisimi","has_subtitle":true,"tags":[],"vas":[]}],"pagination":{"currentPage":1,"pageSize":12,"totalCount":36}}"#
                await pageState.load(page: 1) {
                    try JSONDecoder().decode(WorksResponse.self, from: Data(json.utf8))
                }
                await pageState.load(page: 2) { throw URLError(.notConnectedToInternet) }
                return
            }
            if ProcessInfo.processInfo.environment["WISIMI_WORKS_CHECKS"] == "1" {
                await WorksPageStateSelfCheck.run()
                return
            }
            if ProcessInfo.processInfo.environment["WISIMI_VIDEO_CHECKS"] == "1" {
                do { try await player.runVideoChecks() }
                catch { assertionFailure("Video checks failed: \(error)") }
                return
            }
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] == "video" {
                do { try await player.prepareDebugVideoPlayback() }
                catch { assertionFailure("Video preview failed: \(error)") }
                return
            }
            if ProcessInfo.processInfo.environment["WISIMI_PLAYBACK_CHECKS"] == "1" {
                do { try await player.runPlaybackChecks() }
                catch { assertionFailure("Playback checks failed: \(error)") }
                return
            }
            #endif
            await loadWorks(page: currentPage)
        }
    }

    private var shouldShowMiniPlayer: Bool {
        guard player.currentTrack != nil else { return false }
        if case .player? = path.last { return false }
        return true
    }

    private func openPlayer() {
        path.append(.player)
    }

    private func openPlayingWorkDetail() {
        guard let workID = player.workID else { return }
        path = WorksRoute.replacingPlayer(withDetail: workID, in: path)
    }

    private func runSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            clearSearch()
            return
        }

        browser.keyword = keyword
        isSearchFocused = false
        Task { await reloadFromFirstPage() }
    }

    private func clearSearch() {
        searchText = ""
        browser.keyword = ""
        Task { await reloadFromFirstPage() }
    }

    private func search(prefix: String, name: String) {
        searchText = "$\(prefix):\(name)$"
        browser.keyword = searchText
        isSearchFocused = false
        path = []
        Task { await reloadFromFirstPage() }
    }

    private func selectMode(_ mode: WorksMode) {
        guard !mode.requiresLogin || auth.isLoggedIn else {
            pendingMode = mode
            isLoginPresented = true
            return
        }

        browser.mode = mode
        browser.keyword = ""
        searchText = ""
        isSearchFocused = false
        Task { await reloadFromFirstPage() }
    }

    private func reloadFromFirstPage() async {
        await browser.reload(token: auth.token, recommenderUUID: auth.recommenderUuid)
    }

    private func loadWorks(page: Int = 1) async {
        await browser.load(page: page, token: auth.token, recommenderUUID: auth.recommenderUuid)
    }
}

private struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AuthSession
    let onSuccess: () -> Void
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $password)
                }

                if let errorMessage = auth.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("登录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await auth.login(name: name, password: password)
                            if auth.isLoggedIn {
                                dismiss()
                                onSuccess()
                            }
                        }
                    } label: {
                        if auth.isLoading {
                            ProgressView()
                        } else {
                            Text("登录")
                        }
                    }
                    .disabled(auth.isLoading || name.isEmpty || password.isEmpty)
                }
            }
        }
    }
}

private struct WorksSearchHeader: View {
    @Binding var searchText: String
    let activeSearchText: String
    let selectedMode: WorksMode
    let filter: WorksFilter
    let reviewFilter: ReviewFilter
    let selectedPlaylist: PlaylistSummary?
    var isSearchFocused: FocusState<Bool>.Binding
    let onSearch: () -> Void
    let onClearSearch: () -> Void
    let onModeSelected: (WorksMode) -> Void
    let onFilter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("搜索作品 / 标签 / 声优 / RJ号", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused(isSearchFocused)
                        .onSubmit(onSearch)

                    if !searchText.isEmpty {
                        Button {
                            onClearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.background, in: .rect(cornerRadius: 8))

                Button(action: onFilter) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("筛选")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WorksMode.allCases) { mode in
                        Button {
                            onModeSelected(mode)
                        } label: {
                            Label(mode.title, systemImage: mode.systemImage)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedMode == mode && activeSearchText.isEmpty ? .accentColor : .secondary.opacity(0.18))
                        .foregroundStyle(selectedMode == mode && activeSearchText.isEmpty ? .white : .primary)
                    }
                }
                .padding(.vertical, 1)
            }

            if let summaryText {
                Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }

    private var summaryText: String? {
        if !activeSearchText.isEmpty {
            var parts = ["搜索：\(activeSearchText)"]
            if filter.hasSubtitle {
                parts.append("有字幕")
            }
            parts.append("\(filter.order.title) \(filter.sort.title)")
            return parts.joined(separator: " · ")
        }

        if selectedMode == .favorites {
            return "\(reviewFilter.status.title) · \(reviewFilter.order.title) · \(reviewFilter.sort.title(for: reviewFilter.order))"
        }

        if selectedMode == .playlists {
            return selectedPlaylist.map { "\($0.displayName) · \($0.countText)" } ?? "播放列表"
        }

        guard filter != .default else { return nil }
        var parts: [String] = []
        if filter.hasSubtitle {
            parts.append("有字幕")
        }
        parts.append(selectedMode == .popular ? "热门作品" : "\(filter.order.title) \(filter.sort.title)")
        return parts.joined(separator: " · ")
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
                        Text(player.playbackError ?? (player.playbackState == .preparing ? "正在准备播放…" : player.currentSubtitle?.text ?? player.workTitle))
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
            .contextMenu {
                Button("复制文件名", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = player.currentTrack?.title ?? "未播放"
                }
                Button("复制作品标题", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = player.workTitle
                }
            }

            PlaybackToggleButton(state: player.playbackState, isCompact: true, action: player.togglePlayback)
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
                .copyContextMenu(work.title, label: "作品标题")
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
