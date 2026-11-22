import SwiftUI
import UIKit

struct WorksListView: View {
    private let client: ASMRClient
    private let source: WorkSource
    @StateObject private var player: WorkAudioPlayer
    @StateObject private var auth: AuthSession
    @StateObject private var ttsSettings: TTSMixSettings
    @State private var path: [WorksRoute] = []
    @State private var browser: WorksBrowserState
    @State private var showsLocalLibrary = false
    @State private var localRevision = 0
    @State private var localImportTrigger = 0
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
    @State private var onlineScrollPosition = ScrollPosition()
    @FocusState private var isSearchFocused: Bool
    #if DEBUG
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    init() {
        #if DEBUG
        let debugConfig = DebugLaunchConfig.current
        let client = debugConfig.makeClient()
        #else
        let client = ASMRClient()
        #endif
        let ttsSettings = TTSMixSettings()
        self.client = client
        let source = WorkSource(client: client, library: .shared)
        self.source = source
        _browser = State(initialValue: WorksBrowserState(client: client, catalog: PlaylistCatalog(client: client)))
        _ttsSettings = StateObject(wrappedValue: ttsSettings)
        let player = WorkAudioPlayer(source: source, ttsSettings: ttsSettings)
        _player = StateObject(wrappedValue: player)
        _auth = StateObject(wrappedValue: AuthSession(client: client))
        #if DEBUG
        let debugState = debugConfig.configureInitialState(player: player)
        _path = State(initialValue: debugState.path)
        _showsLocalLibrary = State(initialValue: debugState.showsLocalLibrary)
        _isNarrationSettingsPresented = State(initialValue: debugState.isNarrationSettingsPresented)
        #endif
    }

    @ViewBuilder var body: some View {
        #if DEBUG
        Group {
            if DebugLaunchConfig.current.isWorkActionsPreview {
                DebugWorkActionsPreview()
            } else {
                browserContent
            }
        }
        .environment(\.dynamicTypeSize, DebugLaunchConfig.current.usesLargeText ? .accessibility3 : dynamicTypeSize)
        #else
        browserContent
        #endif
    }

    private var browserContent: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("作品来源", selection: $showsLocalLibrary) {
                    Text("在线").tag(false)
                    Text("本地").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ZStack {
                    onlineBrowser
                        .opacity(showsLocalLibrary ? 0 : 1)
                        .allowsHitTesting(!showsLocalLibrary)
                        .accessibilityHidden(showsLocalLibrary)
                    LocalWorksView(library: source.library, catalog: source.library,
                                   refreshID: showsLocalLibrary ? localRevision : nil,
                                   reservesMiniPlayerSpace: shouldShowMiniPlayer,
                                   importTrigger: localImportTrigger) { reference in
                        path.append(.detail(reference))
                    }
                    .opacity(showsLocalLibrary ? 1 : 0)
                    .allowsHitTesting(showsLocalLibrary)
                    .accessibilityHidden(!showsLocalLibrary)
                }
            }
            .toolbar { browserToolbar }
            .navigationDestination(for: WorksRoute.self, destination: destination)
            .sheet(isPresented: $isFilterPresented) { filterSheet }
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
        .task { await loadInitialContent() }
    }

    private var onlineBrowser: some View {
        ScrollView {
            VStack(spacing: 18) {
                WorksSearchHeader(
                    searchText: $searchText,
                    activeSearchText: browser.keyword,
                    selectedMode: browser.mode,
                    summaryText: browser.summaryText,
                    isSearchFocused: $isSearchFocused,
                    onSearch: runSearch,
                    onClearSearch: clearSearch,
                    onModeSelected: selectMode,
                    onFilter: { isFilterPresented = true }
                )

                PagedWorksContent(
                    works: works.map(\.card),
                    pagination: pagination,
                    currentPage: currentPage,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    loadingTitle: "加载作品中...",
                    onRetry: { await loadWorks(page: pageState.requestedPage) },
                    onPageChanged: { page in
                        await loadWorks(page: page)
                        withAnimation {
                            onlineScrollPosition.scrollTo(edge: .top)
                        }
                    },
                    onSelect: { reference in
                        path.append(.detail(reference))
                    },
                    emptyContent: {
                        EmptyStateView {
                            await loadWorks(page: 1)
                        }
                    }
                )

                if shouldShowMiniPlayer {
                    Color.clear.frame(height: miniPlayerAvoidanceHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($onlineScrollPosition)
        .background(.background)
        .refreshable {
            await loadWorks(page: 1)
            withAnimation {
                onlineScrollPosition.scrollTo(edge: .top)
            }
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if !showsLocalLibrary, auth.isLoggedIn {
                    Button("退出登录", role: .destructive) {
                        auth.logout()
                        if browser.mode.requiresLogin {
                            browser.mode = .latest
                            Task { await reloadFromFirstPage() }
                        }
                    }
                } else if !showsLocalLibrary {
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
                if showsLocalLibrary {
                    Label("菜单", systemImage: "ellipsis.circle")
                } else {
                    Label(auth.username ?? "菜单", systemImage: auth.isLoggedIn ? "person.crop.circle.fill" : "ellipsis.circle")
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if showsLocalLibrary {
                Button {
                    localImportTrigger += 1
                } label: {
                    Label("导入作品", systemImage: "folder.badge.plus")
                }
            } else if isLoading && !works.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: WorksRoute) -> some View {
        switch route {
        case .detail(.asmrOne(let workID)):
            WorkDetailView(
                workID: workID,
                client: client,
                auth: auth,
                player: player,
                reservesMiniPlayerSpace: shouldShowMiniPlayer,
                onSearch: search,
                onLoginRequired: { isLoginPresented = true },
                onOpenWork: { path.append(.detail($0)) },
                onOpenLocalLibrary: {
                    showsLocalLibrary = true
                    path = []
                }
            )
        case .detail(.local(let id)):
            LocalWorkDetailView(
                id: id,
                source: source,
                player: player,
                reservesMiniPlayerSpace: shouldShowMiniPlayer,
                onOpenOnlineWork: { onlineID in path.append(.detail(.asmrOne(onlineID))) },
                onDeleted: { localRevision += 1 }
            )
        case .player:
            PlayerView(player: player, openWorkDetail: openPlayingWorkDetail)
        }
    }

    private var filterSheet: some View {
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

    private func loadInitialContent() async {
        #if DEBUG
        if case .handled(let newPath) = await DebugLaunchConfig.current.handleInitialLoadIfNeeded(
            pageState: pageState,
            player: player
        ) {
            if let newPath { path = newPath }
            return
        }
        #endif
        await loadWorks(page: currentPage)
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
        guard let reference = player.workReference else { return }
        path = WorksRoute.replacingPlayer(withDetail: reference, in: path)
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
        showsLocalLibrary = false
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
        FormSheet(
            title: "登录",
            submit: SheetSubmit(
                title: "登录",
                isLoading: auth.isLoading,
                isDisabled: name.isEmpty || password.isEmpty
            ) {
                Task {
                    await auth.login(name: name, password: password)
                    if auth.isLoggedIn {
                        dismiss()
                        onSuccess()
                    }
                }
            },
            errorMessage: auth.errorMessage
        ) {
            Section {
                TextField("用户名", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("密码", text: $password)
            }
        }
    }
}

private struct WorksSearchHeader: View {
    @Binding var searchText: String
    let activeSearchText: String
    let selectedMode: WorksMode
    let summaryText: String?
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
}

let miniPlayerAvoidanceHeight: CGFloat = 70

private struct MiniPlayerBar: View {
    @ObservedObject var player: WorkAudioPlayer
    let openPlayer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openPlayer) {
                HStack(spacing: 10) {
                    CoverImage(url: player.coverURL, cornerRadius: 6, size: CGSize(width: 42, height: 42),
                               placeholderWhenMissing: player.workReference?.localID != nil)

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

#Preview {
    WorksListView()
}
