import SwiftUI

struct WorksListView: View {
    private let client: ASMRClient
    @StateObject private var player: WorkAudioPlayer
    @StateObject private var auth: AuthSession
    @StateObject private var ttsSettings: TTSMixSettings
    @State private var path: [WorksRoute] = []
    @State private var works: [WorkSummary] = []
    @State private var pagination: WorksPagination?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage = 1
    @State private var selectedMode: WorksMode = .latest
    @State private var searchText = ""
    @State private var activeSearchText = ""
    @State private var filter = WorksFilter.default
    @State private var reviewFilter = ReviewFilter.default
    @State private var playlists: [PlaylistSummary] = []
    @State private var selectedPlaylistID: String?
    @State private var isFilterPresented = false
    @State private var isLoginPresented = false
    @State private var isNarrationSettingsPresented = false
    @State private var pendingMode: WorksMode?
    @FocusState private var isSearchFocused: Bool

    init() {
        let client = ASMRClient()
        let ttsSettings = TTSMixSettings()
        self.client = client
        _ttsSettings = StateObject(wrappedValue: ttsSettings)
        _player = StateObject(wrappedValue: WorkAudioPlayer(client: client, ttsSettings: ttsSettings))
        _auth = StateObject(wrappedValue: AuthSession(client: client))
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
                            activeSearchText: activeSearchText,
                            selectedMode: selectedMode,
                            filter: filter,
                            reviewFilter: reviewFilter,
                            selectedPlaylist: selectedPlaylist,
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
                                await loadWorks(page: currentPage)
                            }
                        } else if works.isEmpty {
                            EmptyStateView {
                                await loadWorks(page: 1)
                            }
                        } else {
                            VStack(spacing: 18) {
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
                                if selectedMode.requiresLogin {
                                    selectedMode = .latest
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
                        onSearch: search,
                        onLoginRequired: { isLoginPresented = true }
                    )
                case .player:
                    PlayerView(player: player)
                }
            }
            .sheet(isPresented: $isFilterPresented) {
                WorksFilterSheet(
                    mode: selectedMode,
                    filter: filter,
                    reviewFilter: reviewFilter,
                    playlists: playlists,
                    selectedPlaylistID: selectedPlaylistID,
                    client: client,
                    token: auth.token
                ) { newFilter in
                    filter = newFilter
                    Task { await reloadFromFirstPage() }
                } onApplyReviewFilter: { newFilter in
                    reviewFilter = newFilter
                    Task { await reloadFromFirstPage() }
                } onApplyPlaylist: { playlistID in
                    selectedPlaylistID = playlistID
                    Task { await reloadFromFirstPage() }
                } onPlaylistCreated: { playlist in
                    upsertPlaylist(playlist)
                    selectedPlaylistID = playlist.id
                    Task { await reloadFromFirstPage() }
                } onPlaylistUpdated: { playlist in
                    upsertPlaylist(playlist)
                } onPlaylistDeleted: { playlistID in
                    deleteLocalPlaylist(id: playlistID)
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
                    .presentationDetents([.medium])
            }
        }
        .safeAreaInset(edge: .bottom) {
            if shouldShowMiniPlayer {
                MiniPlayerBar(player: player) {
                    openPlayer()
                }
            }
        }
        .task {
            await loadWorks(page: currentPage)
        }
    }

    private var shouldShowMiniPlayer: Bool {
        guard player.currentTrack != nil else { return false }
        if case .player? = path.last { return false }
        return true
    }

    private func openPlayer(from detailWorkID: Int? = nil) {
        guard let workID = player.workID else {
            path.append(.player)
            return
        }

        if detailWorkID == workID {
            path.append(.player)
        } else {
            path = [.detail(workID), .player]
        }
    }

    private func runSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            clearSearch()
            return
        }

        activeSearchText = keyword
        isSearchFocused = false
        Task { await reloadFromFirstPage() }
    }

    private func clearSearch() {
        searchText = ""
        activeSearchText = ""
        Task { await reloadFromFirstPage() }
    }

    private func search(prefix: String, name: String) {
        searchText = "$\(prefix):\(name)$"
        activeSearchText = searchText
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

        selectedMode = mode
        activeSearchText = ""
        searchText = ""
        isSearchFocused = false
        Task { await reloadFromFirstPage() }
    }

    private func reloadFromFirstPage() async {
        pagination = nil
        await loadWorks(page: 1)
    }

    private var selectedPlaylist: PlaylistSummary? {
        guard let selectedPlaylistID else { return nil }
        return playlists.first { $0.id == selectedPlaylistID }
    }

    private func loadWorks(page: Int = 1) async {
        guard !isLoading else { return }
        if let totalPages = pagination?.totalPages, page > totalPages { return }
        guard page >= 1 else { return }

        isLoading = true
        errorMessage = nil
        do {
            let response: WorksResponse
            if !activeSearchText.isEmpty {
                response = try await client.searchWorks(keyword: activeSearchText, page: page, filter: filter)
            } else {
                switch selectedMode {
                case .latest:
                    response = try await client.fetchWorks(page: page, filter: filter)
                case .popular:
                    response = try await client.fetchPopular(page: page, filter: filter)
                case .favorites:
                    guard let token = auth.token else { throw ASMRClientError.loginRequired }
                    response = try await client.fetchFavorites(page: page, token: token, filter: reviewFilter)
                case .playlists:
                    guard let token = auth.token else { throw ASMRClientError.loginRequired }
                    let playlistID = try await ensureSelectedPlaylist(token: token)
                    response = try await client.fetchPlaylistWorks(id: playlistID, page: page, token: token)
                case .recommended:
                    guard let token = auth.token else { throw ASMRClientError.loginRequired }
                    guard let uuid = auth.recommenderUuid, !uuid.isEmpty else { throw ASMRClientError.missingRecommenderUuid }
                    response = try await client.fetchRecommended(page: page, uuid: uuid, token: token, filter: filter)
                }
            }
            works = response.works
            pagination = response.pagination
            currentPage = response.pagination.currentPage
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func ensureSelectedPlaylist(token: String) async throws -> String {
        if let selectedPlaylistID, playlists.contains(where: { $0.id == selectedPlaylistID }) {
            return selectedPlaylistID
        }

        let response = try await client.fetchPlaylists(token: token)
        playlists = response.playlists
        guard let first = response.playlists.first else { throw ASMRClientError.noPlaylists }
        selectedPlaylistID = first.id
        return first.id
    }

    private func upsertPlaylist(_ playlist: PlaylistSummary) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    private func deleteLocalPlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        if selectedPlaylistID == id {
            selectedPlaylistID = playlists.first?.id
            Task { await reloadFromFirstPage() }
        }
    }
}

private enum WorksRoute: Hashable {
    case detail(Int)
    case player
}

private enum WorksMode: String, CaseIterable, Identifiable {
    case latest
    case popular
    case favorites
    case playlists
    case recommended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: "最新"
        case .popular: "热门作品"
        case .favorites: "收藏"
        case .playlists: "播放列表"
        case .recommended: "推荐作品"
        }
    }

    var systemImage: String {
        switch self {
        case .latest: "clock"
        case .popular: "flame"
        case .favorites: "heart"
        case .playlists: "music.note.list"
        case .recommended: "sparkles"
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .latest, .popular: false
        case .favorites, .playlists, .recommended: true
        }
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
                        .buttonStyle(.borderedProminent)
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

private struct WorksFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: WorksMode
    @State private var draft: WorksFilter
    @State private var reviewDraft: ReviewFilter
    @State private var playlistID: String?
    @State private var managedPlaylists: [PlaylistSummary]
    @State private var playlistEditor: PlaylistEditor?
    @State private var playlistActions: PlaylistSummary?
    @State private var playlistToDelete: PlaylistSummary?
    @State private var isDeleting = false
    @State private var mutationMessage: String?
    let client: ASMRClient
    let token: String?
    let onApply: (WorksFilter) -> Void
    let onApplyReviewFilter: (ReviewFilter) -> Void
    let onApplyPlaylist: (String) -> Void
    let onPlaylistCreated: (PlaylistSummary) -> Void
    let onPlaylistUpdated: (PlaylistSummary) -> Void
    let onPlaylistDeleted: (String) -> Void

    init(
        mode: WorksMode,
        filter: WorksFilter,
        reviewFilter: ReviewFilter,
        playlists: [PlaylistSummary],
        selectedPlaylistID: String?,
        client: ASMRClient,
        token: String?,
        onApply: @escaping (WorksFilter) -> Void,
        onApplyReviewFilter: @escaping (ReviewFilter) -> Void,
        onApplyPlaylist: @escaping (String) -> Void,
        onPlaylistCreated: @escaping (PlaylistSummary) -> Void,
        onPlaylistUpdated: @escaping (PlaylistSummary) -> Void,
        onPlaylistDeleted: @escaping (String) -> Void
    ) {
        self.mode = mode
        _draft = State(initialValue: filter)
        _reviewDraft = State(initialValue: reviewFilter)
        _playlistID = State(initialValue: selectedPlaylistID ?? playlists.first?.id)
        _managedPlaylists = State(initialValue: playlists)
        self.client = client
        self.token = token
        self.onApply = onApply
        self.onApplyReviewFilter = onApplyReviewFilter
        self.onApplyPlaylist = onApplyPlaylist
        self.onPlaylistCreated = onPlaylistCreated
        self.onPlaylistUpdated = onPlaylistUpdated
        self.onPlaylistDeleted = onPlaylistDeleted
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .favorites {
                    Section("状态") {
                        Picker("", selection: $reviewDraft.status) {
                            ForEach(ReviewStatus.allCases) { status in
                                Text(status.title).tag(status)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    Section("排序") {
                        Picker("字段", selection: $reviewDraft.order) {
                            ForEach(ReviewOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }

                        Picker("方向", selection: $reviewDraft.sort) {
                            ForEach(ReviewSort.allCases) { sort in
                                Text(sort.title(for: reviewDraft.order)).tag(sort)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } else if mode == .playlists {
                    Section("播放列表") {
                        if managedPlaylists.isEmpty {
                            Text("暂无播放列表")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(managedPlaylists) { playlist in
                                HStack(spacing: 10) {
                                    Button {
                                        playlistID = playlist.id
                                    } label: {
                                        HStack(spacing: 10) {
                                            if let systemImage = playlist.systemImage {
                                                Image(systemName: systemImage)
                                                    .foregroundStyle(.secondary)
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(playlist.displayName)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(playlist.countText)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            if playlistID == playlist.id {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.primary)
                                            }
                                        }
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)

                                    if !playlist.isSystemPreserved {
                                        Button {
                                            playlistActions = playlist
                                        } label: {
                                            Image(systemName: "pencil")
                                                .frame(width: 34, height: 34)
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("编辑\(playlist.displayName)")
                                    }
                                }
                            }
                        }
                    }

                    Section("管理") {
                        Button {
                            playlistEditor = .create
                        } label: {
                            Label("新建播放列表", systemImage: "plus")
                        }

                        if let mutationMessage {
                            Text(mutationMessage)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Section {
                        Toggle("有字幕", isOn: $draft.hasSubtitle)
                    }

                    Section("排序") {
                        Picker("字段", selection: $draft.order) {
                            ForEach(WorksOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }

                        Picker("方向", selection: $draft.sort) {
                            ForEach(WorksSort.allCases) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle("筛选")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("重置") {
                        if mode == .favorites {
                            reviewDraft = .default
                        } else if mode == .playlists {
                            playlistID = managedPlaylists.first?.id
                        } else {
                            draft = .default
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if mode == .favorites {
                            onApplyReviewFilter(reviewDraft)
                        } else if mode == .playlists {
                            if let playlistID {
                                onApplyPlaylist(playlistID)
                            }
                        } else {
                            onApply(draft)
                        }
                        dismiss()
                    }
                }
            }
            .sheet(item: $playlistEditor) { editor in
                PlaylistEditorSheet(editor: editor, client: client, token: token) { playlist in
                    apply(playlist, from: editor)
                }
            }
            .sheet(item: $playlistActions) { playlist in
                PlaylistActionsSheet(playlist: playlist) {
                    playlistActions = nil
                    playlistEditor = .edit(playlist)
                } onDelete: {
                    playlistActions = nil
                    playlistToDelete = playlist
                }
                    .presentationDetents([.height(220)])
            }
            .confirmationDialog("删除播放列表？", isPresented: deleteConfirmation) {
                Button("删除", role: .destructive) {
                    if let playlistToDelete {
                        Task { await deletePlaylist(playlistToDelete) }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后无法恢复。")
            }
        }
    }

    private var deleteConfirmation: Binding<Bool> {
        Binding {
            playlistToDelete != nil
        } set: { isPresented in
            if !isPresented {
                playlistToDelete = nil
            }
        }
    }

    private func apply(_ playlist: PlaylistSummary, from editor: PlaylistEditor) {
        if let index = managedPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            managedPlaylists[index] = playlist
        } else {
            managedPlaylists.append(playlist)
        }
        playlistID = playlist.id
        mutationMessage = nil

        switch editor {
        case .create:
            onPlaylistCreated(playlist)
        case .edit:
            onPlaylistUpdated(playlist)
        }
    }

    private func deletePlaylist(_ playlist: PlaylistSummary) async {
        guard let token else {
            mutationMessage = "请先登录"
            return
        }

        isDeleting = true
        mutationMessage = nil
        do {
            let deletedID = try await client.deletePlaylist(id: playlist.id, token: token)
            managedPlaylists.removeAll { $0.id == deletedID }
            if playlistID == deletedID {
                playlistID = managedPlaylists.first?.id
            }
            onPlaylistDeleted(deletedID)
            playlistToDelete = nil
        } catch {
            mutationMessage = error.localizedDescription
        }
        isDeleting = false
    }
}

private struct PlaylistActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playlist: PlaylistSummary
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        dismiss()
                        onEdit()
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        dismiss()
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(playlist.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum PlaylistEditor: Identifiable {
    case create
    case edit(PlaylistSummary)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let playlist): "edit-\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case .create: "新建播放列表"
        case .edit: "编辑播放列表"
        }
    }

    var submitTitle: String {
        switch self {
        case .create: "创建"
        case .edit: "保存"
        }
    }
}

private enum PlaylistPrivacy: Int, CaseIterable, Identifiable {
    case `private` = 0
    case unlisted = 1
    case `public` = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .private: "私享"
        case .unlisted: "不公开"
        case .public: "公开"
        }
    }
}

private struct PlaylistEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: PlaylistEditor
    let client: ASMRClient
    let token: String?
    let onSaved: (PlaylistSummary) -> Void
    @State private var name: String
    @State private var description: String
    @State private var privacy: PlaylistPrivacy
    @State private var isSaving = false
    @State private var message: String?

    init(editor: PlaylistEditor, client: ASMRClient, token: String?, onSaved: @escaping (PlaylistSummary) -> Void) {
        self.editor = editor
        self.client = client
        self.token = token
        self.onSaved = onSaved

        switch editor {
        case .create:
            _name = State(initialValue: "")
            _description = State(initialValue: "")
            _privacy = State(initialValue: .private)
        case .edit(let playlist):
            _name = State(initialValue: playlist.displayName)
            _description = State(initialValue: playlist.description)
            _privacy = State(initialValue: PlaylistPrivacy(rawValue: playlist.privacy) ?? .private)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("描述", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("隐私") {
                    Picker("隐私", selection: $privacy) {
                        ForEach(PlaylistPrivacy.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editor.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(editor.submitTitle)
                        }
                    }
                    .disabled(isSaving || trimmedName.isEmpty || token == nil)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        guard let token else {
            message = "请先登录"
            return
        }

        isSaving = true
        message = nil
        do {
            let playlist: PlaylistSummary
            switch editor {
            case .create:
                playlist = try await client.createPlaylist(
                    name: trimmedName,
                    privacy: privacy.rawValue,
                    description: description,
                    token: token
                )
            case .edit(let existing):
                playlist = try await client.updatePlaylistMetadata(
                    id: existing.id,
                    name: trimmedName,
                    privacy: privacy.rawValue,
                    description: description,
                    token: token
                )
            }
            onSaved(playlist)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
        isSaving = false
    }
}

private struct TTSMixSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: TTSMixSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("开启混音", isOn: $settings.isEnabled)
                } footer: {
                    Text("开启后，播放有字幕的作品时会直接请求 Edge 在线 TTS 并叠加旁白。")
                }

                Section("音量") {
                    Slider(value: $settings.volume, in: 0...1)
                        .accessibilityLabel("混音音量")
                        .accessibilityValue(volumeText)

                    HStack {
                        Text("TTS 旁白")
                        Spacer()
                        Text(volumeText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Section("语速") {
                    Slider(value: $settings.maxSpeechRate, in: 1...1.25, step: 0.05)
                        .accessibilityLabel("最大语速")
                        .accessibilityValue(speechRateText)

                    HStack {
                        Text("最大语速")
                        Spacer()
                        Text(speechRateText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .navigationTitle("混音")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var volumeText: String {
        "\(Int((settings.volume * 100).rounded()))%"
    }

    private var speechRateText: String {
        "\(String(format: "%.2f", settings.maxSpeechRate))x"
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
