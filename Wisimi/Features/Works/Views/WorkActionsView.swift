import SwiftUI

struct ReviewActionButton: View {
    let currentStatus: ReviewStatus?
    let isLoggedIn: Bool
    let isLoading: Bool
    @Binding var isMenuPresented: Bool
    let message: String?
    let onLoginRequired: () -> Void
    let onStatusSelected: (ReviewStatus?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            markButton

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var markButton: some View {
        Button {
            guard isLoggedIn else {
                onLoginRequired()
                return
            }
            isMenuPresented = true
        } label: {
            WorkActionLabel(
                title: "标记",
                systemImage: currentStatus == nil ? "bookmark" : "bookmark.fill",
                detail: currentStatus?.title,
                isLoading: isLoading
            )
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
        .sheet(isPresented: $isMenuPresented) {
            markMenu
                .presentationDetents([.medium, .large])
        }
    }

    private var markMenu: some View {
        FormSheet(title: "标记") {
            Section("状态") {
                ForEach(ReviewStatus.allCases) { status in
                    SelectionRow(title: status.title, isSelected: currentStatus == status, style: .single) {
                        select(status)
                    }
                }
            }

            if currentStatus != nil {
                Section {
                    Button("删除标记", role: .destructive) {
                        select(nil)
                    }
                }
            }
        }
    }

    private func select(_ status: ReviewStatus?) {
        isMenuPresented = false
        if status != currentStatus { onStatusSelected(status) }
    }
}

struct PlaylistActionButton: View {
    let workID: Int
    let client: ASMRClient
    let token: String?
    @Binding var isMenuPresented: Bool
    let onLoginRequired: () -> Void

    var body: some View {
        Button {
            guard token != nil else {
                onLoginRequired()
                return
            }
            isMenuPresented.toggle()
        } label: {
            WorkActionLabel(title: "添加到播放列表", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .sheet(isPresented: $isMenuPresented) {
            if let token {
                PlaylistMembershipSheet(workID: workID, client: client, token: token)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

/// 状态随弹层创建，每次打开都从第一页重新加载。
private struct PlaylistMembershipSheet: View {
    let token: String
    @State private var state: PlaylistMembershipState

    init(workID: Int, client: ASMRClient, token: String) {
        self.token = token
        _state = State(initialValue: PlaylistMembershipState(workID: workID, client: client))
    }

    var body: some View {
        FormSheet(title: "添加到播放列表", errorMessage: state.errorMessage) {
            Section("播放列表") {
                if state.playlists.isEmpty {
                    if state.errorMessage == nil {
                        if state.pagination == nil {
                            ProgressView("加载播放列表...")
                        } else {
                            Text("暂无播放列表")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(state.playlists) { playlist in
                        SelectionRow(
                            playlist: playlist,
                            isSelected: playlist.exist,
                            style: .multiple,
                            isLoading: state.updatingIDs.contains(playlist.id)
                        ) {
                            Task { await state.toggle(playlist, token: token) }
                        }
                    }
                }
            }

            if let pagination = state.pagination, pagination.totalPages > 1 {
                Section {
                    PaginationControls(
                        currentPage: state.currentPage,
                        totalPages: pagination.totalPages,
                        isLoading: state.isLoading
                    ) { page in
                        Task { await state.load(page: page, token: token) }
                    }
                }
            }
        }
        .task {
            await state.load(page: 1, token: token)
        }
    }
}

extension SelectionRow {
    init(
        playlist: PlaylistSummary,
        isSelected: Bool,
        style: SelectionRowStyle,
        isLoading: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.init(
            title: playlist.displayName,
            subtitle: playlist.countText,
            systemImage: playlist.systemImage,
            isSelected: isSelected,
            style: style,
            isLoading: isLoading,
            action: action,
            accessory: accessory
        )
    }
}

extension SelectionRow where Accessory == EmptyView {
    init(
        playlist: PlaylistSummary,
        isSelected: Bool,
        style: SelectionRowStyle,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(playlist: playlist, isSelected: isSelected, style: style, isLoading: isLoading, action: action) {
            EmptyView()
        }
    }
}

private struct WorkActionLabel: View {
    let title: String
    let systemImage: String
    var detail: String?
    var isLoading = false

    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}
