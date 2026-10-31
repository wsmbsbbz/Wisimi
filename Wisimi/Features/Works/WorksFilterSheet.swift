import SwiftUI

struct WorksFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: WorksFilterContext
    @State private var draft: WorksFilter
    @State private var reviewDraft: ReviewFilter
    @State private var playlistID: String?
    let catalog: PlaylistCatalog
    private var managedPlaylists: [PlaylistSummary] { catalog.playlists }
    @State private var playlistEditor: PlaylistEditor?
    @State private var mutationMessage: String?
    let token: String?
    let onApply: (WorksFilter) -> Void
    let onApplyReviewFilter: (ReviewFilter) -> Void
    let onApplyPlaylist: (String) -> Void
    let onCatalogChanged: () -> Void

    init(
        context: WorksFilterContext,
        filter: WorksFilter,
        reviewFilter: ReviewFilter,
        catalog: PlaylistCatalog,
        token: String?,
        onApply: @escaping (WorksFilter) -> Void,
        onApplyReviewFilter: @escaping (ReviewFilter) -> Void,
        onApplyPlaylist: @escaping (String) -> Void,
        onCatalogChanged: @escaping () -> Void
    ) {
        self.context = context
        _draft = State(initialValue: filter)
        _reviewDraft = State(initialValue: reviewFilter)
        _playlistID = State(initialValue: catalog.selectedID ?? catalog.playlists.first?.id)
        self.catalog = catalog
        self.token = token
        self.onApply = onApply
        self.onApplyReviewFilter = onApplyReviewFilter
        self.onApplyPlaylist = onApplyPlaylist
        self.onCatalogChanged = onCatalogChanged
    }

    var body: some View {
        NavigationStack {
            Form {
                switch context {
                case .favorites:
                    ReviewFilterSections(filter: $reviewDraft)
                case .playlists:
                    PlaylistFilterSections(
                        playlists: managedPlaylists,
                        selectedID: $playlistID,
                        editor: $playlistEditor,
                        onDelete: { playlist in
                            Task { await deletePlaylist(playlist) }
                        }
                    )
                case .works:
                    WorksFilterSections(filter: $draft)
                }
            }
            .sheetErrorBar(mutationMessage)
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("重置") {
                        switch context {
                        case .favorites: reviewDraft = .default
                        case .playlists: playlistID = managedPlaylists.first?.id
                        case .works: draft = .default
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        switch context {
                        case .favorites: onApplyReviewFilter(reviewDraft)
                        case .playlists: if let playlistID { onApplyPlaylist(playlistID) }
                        case .works: onApply(draft)
                        }
                        dismiss()
                    }
                }
            }
            .sheet(item: $playlistEditor) { editor in
                PlaylistEditorSheet(editor: editor, catalog: catalog, token: token) { playlist in
                    apply(playlist, from: editor)
                }
            }
        }
    }

    private func apply(_ playlist: PlaylistSummary, from editor: PlaylistEditor) {
        playlistID = playlist.id
        mutationMessage = nil
        if case .create = editor {
            catalog.selectedID = playlist.id
            onCatalogChanged()
        }
    }

    private func deletePlaylist(_ playlist: PlaylistSummary) async {
        guard let token else {
            mutationMessage = "请先登录"
            return
        }

        mutationMessage = nil
        do {
            let wasSelected = catalog.selectedID == playlist.id
            try await catalog.delete(id: playlist.id, token: token)
            if playlistID == playlist.id { playlistID = catalog.playlists.first?.id }
            if wasSelected { onCatalogChanged() }
        } catch {
            mutationMessage = error.userFacingMessage
        }
    }
}

private struct ReviewFilterSections: View {
    @Binding var filter: ReviewFilter

    var body: some View {
        Section("状态") {
            Picker("", selection: $filter.status) {
                ForEach(ReviewStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("排序") {
            Picker("字段", selection: $filter.order) {
                ForEach(ReviewOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }

            Picker("方向", selection: $filter.sort) {
                ForEach(ReviewSort.allCases) { sort in
                    Text(sort.title(for: filter.order)).tag(sort)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct PlaylistFilterSections: View {
    let playlists: [PlaylistSummary]
    @Binding var selectedID: String?
    @Binding var editor: PlaylistEditor?
    let onDelete: (PlaylistSummary) -> Void

    var body: some View {
        Section("播放列表") {
            if playlists.isEmpty {
                Text("暂无播放列表")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playlists) { playlist in
                    SelectionRow(playlist: playlist, isSelected: selectedID == playlist.id, style: .single) {
                        selectedID = playlist.id
                    } accessory: {
                        if !playlist.isSystemPreserved {
                            PlaylistActionsButton(
                                playlistName: playlist.displayName,
                                onEdit: { editor = .edit(playlist) },
                                onDelete: { onDelete(playlist) }
                            )
                        }
                    }
                }
            }
        }

        Section("管理") {
            Button {
                editor = .create
            } label: {
                Label("新建播放列表", systemImage: "plus")
            }
        }
    }
}

/// 用 Menu 而不是 confirmationDialog：后者在弹层内总是锚定到弹层顶部，Menu 才从铅笔位置弹出。
private struct PlaylistActionsButton: View {
    let playlistName: String
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Menu {
            Button("编辑", action: onEdit)
            Button("删除", role: .destructive) {
                isDeleteConfirmationPresented = true
            }
        } label: {
            Image(systemName: "pencil")
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("编辑\(playlistName)")
        .alert("删除播放列表？", isPresented: $isDeleteConfirmationPresented) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }
}

private struct WorksFilterSections: View {
    @Binding var filter: WorksFilter

    var body: some View {
        Section {
            Toggle("有字幕", isOn: $filter.hasSubtitle)
        }

        Section("排序") {
            Picker("字段", selection: $filter.order) {
                ForEach(WorksOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }

            Picker("方向", selection: $filter.sort) {
                ForEach(WorksSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
