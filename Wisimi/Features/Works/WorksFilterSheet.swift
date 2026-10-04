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
    @State private var playlistActions: PlaylistSummary?
    @State private var playlistToDelete: PlaylistSummary?
    @State private var isDeleting = false
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
                if context == .favorites {
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
                } else if context == .playlists {
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
                        if context == .favorites {
                            reviewDraft = .default
                        } else if context == .playlists {
                            playlistID = managedPlaylists.first?.id
                        } else {
                            draft = .default
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if context == .favorites {
                            onApplyReviewFilter(reviewDraft)
                        } else if context == .playlists {
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
                PlaylistEditorSheet(editor: editor, catalog: catalog, token: token) { playlist in
                    apply(playlist, from: editor)
                }
            }
            .confirmationDialog("管理播放列表", item: $playlistActions) { playlist in
                Button("编辑") {
                    playlistEditor = .edit(playlist)
                }
                Button("删除", role: .destructive) {
                    playlistToDelete = playlist
                }
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

        isDeleting = true
        mutationMessage = nil
        do {
            let wasSelected = catalog.selectedID == playlist.id
            try await catalog.delete(id: playlist.id, token: token)
            if playlistID == playlist.id { playlistID = catalog.playlists.first?.id }
            if wasSelected { onCatalogChanged() }
            playlistToDelete = nil
        } catch {
            mutationMessage = error.localizedDescription
        }
        isDeleting = false
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
    let catalog: PlaylistCatalog
    let token: String?
    let onSaved: (PlaylistSummary) -> Void
    @State private var name: String
    @State private var description: String
    @State private var privacy: PlaylistPrivacy
    @State private var isSaving = false
    @State private var message: String?

    init(editor: PlaylistEditor, catalog: PlaylistCatalog, token: String?, onSaved: @escaping (PlaylistSummary) -> Void) {
        self.editor = editor
        self.catalog = catalog
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
            let id: String?
            switch editor {
            case .create: id = nil
            case .edit(let playlist): id = playlist.id
            }
            let playlist = try await catalog.save(id: id, name: trimmedName, privacy: privacy.rawValue,
                                                   description: description, token: token)
            onSaved(playlist)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
        isSaving = false
    }
}

let miniPlayerAvoidanceHeight: CGFloat = 70
