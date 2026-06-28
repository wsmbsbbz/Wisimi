import SwiftUI

struct WorksListView: View {
    private let client: ASMRClient
    @StateObject private var player: WorkAudioPlayer
    @StateObject private var auth: AuthSession
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
    @State private var isFilterPresented = false
    @State private var isLoginPresented = false
    @State private var pendingMode: WorksMode?
    @FocusState private var isSearchFocused: Bool

    init() {
        let client = ASMRClient()
        self.client = client
        _player = StateObject(wrappedValue: WorkAudioPlayer(client: client))
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
                    if auth.isLoggedIn {
                        Menu {
                            Button("退出登录", role: .destructive) {
                                auth.logout()
                                if selectedMode.requiresLogin {
                                    selectedMode = .latest
                                    Task { await reloadFromFirstPage() }
                                }
                            }
                        } label: {
                            Label(auth.username ?? "已登录", systemImage: "person.crop.circle.fill")
                        }
                    } else {
                        Button {
                            isLoginPresented = true
                        } label: {
                            Label("登录", systemImage: "person.crop.circle")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isLoading && !works.isEmpty {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    MiniPlayerBar(player: player) {
                        openPlayer()
                    }
                }
            }
            .navigationDestination(for: WorksRoute.self) { route in
                switch route {
                case .detail(let workID):
                    WorkDetailView(workID: workID, client: client, player: player, onTagSearch: searchTag)
                        .safeAreaInset(edge: .bottom) {
                            if player.currentTrack != nil {
                                MiniPlayerBar(player: player) {
                                    openPlayer(from: workID)
                                }
                            }
                        }
                case .player:
                    PlayerView(player: player)
                }
            }
            .sheet(isPresented: $isFilterPresented) {
                WorksFilterSheet(filter: filter) { newFilter in
                    filter = newFilter
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
        }
        .task {
            await loadWorks(page: currentPage)
        }
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

    private func searchTag(_ tagName: String) {
        searchText = "$tag:\(tagName)$"
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
                    response = try await client.fetchFavorites(page: page, token: token)
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
}

private enum WorksRoute: Hashable {
    case detail(Int)
    case player
}

private enum WorksMode: String, CaseIterable, Identifiable {
    case latest
    case popular
    case favorites
    case recommended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: "最新"
        case .popular: "热门作品"
        case .favorites: "收藏"
        case .recommended: "为你推荐"
        }
    }

    var systemImage: String {
        switch self {
        case .latest: "clock"
        case .popular: "flame"
        case .favorites: "heart"
        case .recommended: "sparkles"
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .latest, .popular: false
        case .favorites, .recommended: true
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

            if !activeSearchText.isEmpty || filter != .default {
                HStack(spacing: 8) {
                    if !activeSearchText.isEmpty {
                        Text("搜索：\(activeSearchText)")
                    }
                    if filter.hasSubtitle {
                        Text("有字幕")
                    }
                    if activeSearchText.isEmpty && selectedMode == .popular {
                        Text("热门作品")
                    } else {
                        Text("\(filter.order.title) \(filter.sort.title)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }
}

private struct WorksFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorksFilter
    let onApply: (WorksFilter) -> Void

    init(filter: WorksFilter, onApply: @escaping (WorksFilter) -> Void) {
        _draft = State(initialValue: filter)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("筛选")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("重置") {
                        draft = .default
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(draft)
                        dismiss()
                    }
                }
            }
        }
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
