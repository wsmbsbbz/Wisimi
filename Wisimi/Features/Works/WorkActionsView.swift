import SwiftUI

struct ReviewActionButton: View {
    let isMarked: Bool
    let currentStatus: ReviewStatus?
    let isLoading: Bool
    @Binding var isMenuPresented: Bool
    let message: String?
    let action: () -> Void
    let onStatusSelected: (ReviewStatus) -> Void

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
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isMarked ? "bookmark.slash" : "bookmark")
                }

                Text(isMarked ? "删除标记" : "标记")
                    .font(.subheadline.weight(.semibold))

                if let currentStatus {
                    Text(currentStatus.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .tint(isMarked ? .red : .accentColor)
        .disabled(isLoading)
        .sheet(isPresented: $isMenuPresented) {
            markMenu
                .presentationDetents([.medium])
        }
    }

    private var markMenu: some View {
        NavigationStack {
            Form {
                Section("状态") {
                    ForEach(ReviewStatus.allCases) { status in
                        Button {
                            isMenuPresented = false
                            onStatusSelected(status)
                        } label: {
                            HStack {
                                Text(status.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if currentStatus == status {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("标记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        isMenuPresented = false
                    }
                }
            }
        }
    }
}

struct PlaylistActionButton: View {
    let workID: Int
    let client: ASMRClient
    let token: String?
    @Binding var isMenuPresented: Bool
    let onLoginRequired: () -> Void

    @State private var playlists: [PlaylistSummary] = []
    @State private var pagination: WorksPagination?
    @State private var page = 1
    @State private var isLoading = false
    @State private var updatingIDs: Set<String> = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            button

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var button: some View {
        Button {
            guard token != nil else {
                onLoginRequired()
                return
            }
            isMenuPresented.toggle()
        } label: {
            HStack {
                Image(systemName: "plus")
                Text("添加到播放列表")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .sheet(isPresented: $isMenuPresented) {
            menu
                .presentationDetents([.medium, .large])
                .task(id: page) {
                    await loadPlaylists()
                }
        }
    }

    private var menu: some View {
        NavigationStack {
            Form {
                Section("播放列表") {
                    if isLoading && playlists.isEmpty {
                        ProgressView("加载播放列表...")
                    } else if playlists.isEmpty {
                        Text(message ?? "暂无播放列表")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playlists) { playlist in
                            Button {
                                toggle(playlist)
                            } label: {
                                HStack(spacing: 10) {
                                    if updatingIDs.contains(playlist.id) {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: playlist.exist ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(playlist.exist ? Color.primary : Color.secondary)
                                    }

                                    if let systemImage = playlist.systemImage {
                                        Image(systemName: systemImage)
                                            .foregroundStyle(.secondary)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.displayName)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        Text(playlist.countText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(updatingIDs.contains(playlist.id))
                        }
                    }
                }

                if let pagination, pagination.totalPages > 1 {
                    Section {
                        HStack {
                            Button("上一页") {
                                page = max(page - 1, 1)
                            }
                            .foregroundStyle(.primary)
                            .disabled(page <= 1 || isLoading)

                            Spacer()

                            Text("\(page) / \(pagination.totalPages)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("下一页") {
                                page = min(page + 1, pagination.totalPages)
                            }
                            .foregroundStyle(.primary)
                            .disabled(page >= pagination.totalPages || isLoading)
                        }
                    }
                }
            }
            .navigationTitle("添加到播放列表")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        isMenuPresented = false
                    }
                }
            }
        }
    }

    private func loadPlaylists() async {
        guard let token, !isLoading else { return }
        isLoading = true
        message = nil
        do {
            let response = try await client.fetchPlaylistStatus(workID: workID, page: page, token: token)
            playlists = response.playlists
            pagination = response.pagination
        } catch is CancellationError {
        } catch {
            message = error.localizedDescription
        }
        isLoading = false
    }

    private func toggle(_ playlist: PlaylistSummary) {
        guard let token, !updatingIDs.contains(playlist.id) else { return }
        let newExist = !playlist.exist
        updatePlaylist(playlist.id, exist: newExist)
        updatingIDs.insert(playlist.id)
        message = nil

        Task {
            do {
                if newExist {
                    try await client.addWorkToPlaylist(playlistID: playlist.id, workID: workID, token: token)
                } else {
                    try await client.removeWorkFromPlaylist(playlistID: playlist.id, workID: workID, token: token)
                }
            } catch is CancellationError {
                updatePlaylist(playlist.id, exist: !newExist)
            } catch {
                updatePlaylist(playlist.id, exist: !newExist)
                message = error.localizedDescription
            }
            updatingIDs.remove(playlist.id)
        }
    }

    private func updatePlaylist(_ id: String, exist: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].worksCount = max(playlists[index].worksCount + (exist ? 1 : -1), 0)
        playlists[index].exist = exist
    }
}
