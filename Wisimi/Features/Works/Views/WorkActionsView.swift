import SwiftUI

struct ReviewActionButton: View {
    let currentStatus: ReviewStatus?
    let isLoggedIn: Bool
    let isLoading: Bool
    let message: String?
    let onLoginRequired: () -> Void
    let onStatusSelected: (ReviewStatus?) -> Void
    @State private var isMenuPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkActionSheetButton(
                title: "标记",
                systemImage: currentStatus == nil ? "bookmark" : "bookmark.fill",
                detail: currentStatus?.title,
                isLoggedIn: isLoggedIn,
                isLoading: isLoading,
                isPresented: $isMenuPresented,
                onLoginRequired: onLoginRequired
            ) {
                markMenu
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
    let onLoginRequired: () -> Void
    @State private var isMenuPresented = false

    var body: some View {
        WorkActionSheetButton(
            title: "添加到播放列表",
            systemImage: "plus",
            isLoggedIn: token != nil,
            isPresented: $isMenuPresented,
            onLoginRequired: onLoginRequired
        ) {
            if let token {
                PlaylistMembershipSheet(workID: workID, client: client, token: token)
            }
        }
        .tint(.blue)
    }
}

private struct WorkActionSheetButton<SheetContent: View>: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    let isLoggedIn: Bool
    var isLoading = false
    @Binding var isPresented: Bool
    let onLoginRequired: () -> Void
    @ViewBuilder let sheetContent: () -> SheetContent

    var body: some View {
        Button {
            guard isLoggedIn else {
                onLoginRequired()
                return
            }
            isPresented = true
        } label: {
            WorkActionLabel(
                title: title,
                systemImage: systemImage,
                detail: detail,
                isLoading: isLoading
            )
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
        .sheet(isPresented: $isPresented) {
            sheetContent()
                .presentationDetents([.medium, .large])
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

            if (state.pagination?.totalPages ?? 1) > 1 {
                Section {
                    PaginationControls(
                        currentPage: state.currentPage,
                        totalPages: state.pagination?.totalPages,
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
