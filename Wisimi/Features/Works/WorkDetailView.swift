import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WorkDetailView: View {
    let workID: Int
    let client: ASMRClient
    @ObservedObject var auth: AuthSession
    let player: WorkAudioPlayer
    let onTagSearch: (String) -> Void
    let onLoginRequired: () -> Void

    @State private var work: WorkDetail?
    @State private var tracks: [TrackNode] = []
    @State private var currentPath: [TrackNode] = []
    @State private var isPathMenuExpanded = false
    @State private var isLoading = false
    @State private var isUpdatingMark = false
    @State private var isMarkMenuPresented = false
    @State private var isPlaylistMenuPresented = false
    @State private var errorMessage: String?
    @State private var markMessage: String?

    var body: some View {
        Group {
            if isLoading && work == nil {
                ProgressView("加载详情中...")
            } else if let errorMessage, work == nil {
                RetryView(message: errorMessage, retry: loadDetail)
            } else if let work {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DetailHero(work: work, onTagSearch: onTagSearch)

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
                                tracks: tracks,
                                currentPath: $currentPath,
                                isPathMenuExpanded: $isPathMenuExpanded,
                                player: player
                            )
                        }
                    }
                    .padding()
                }
            } else {
                EmptyStateView(retry: loadDetail)
            }
        }
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDetail()
        }
        .onChange(of: auth.token) {
            Task { await loadDetail() }
        }
    }

    private func loadDetail() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let detail = client.fetchWork(id: workID, token: auth.token)
            async let trackList = client.fetchTracks(workID: workID)
            work = try await detail
            tracks = try await trackList
            currentPath = tracks.defaultDirectoryPath
            isPathMenuExpanded = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleMark() {
        guard let work else { return }
        guard let token = auth.token else {
            onLoginRequired()
            return
        }

        guard work.progress != nil else {
            isMarkMenuPresented.toggle()
            return
        }

        Task {
            isUpdatingMark = true
            markMessage = nil
            do {
                try await client.unmarkWork(id: work.id, token: token)
                self.work = try await client.fetchWork(id: work.id, token: token)
            } catch {
                markMessage = error.localizedDescription
            }
            isUpdatingMark = false
        }
    }

    private func mark(_ status: ReviewStatus) {
        guard let work, let token = auth.token else { return }

        Task {
            isUpdatingMark = true
            markMessage = nil
            do {
                try await client.markWork(id: work.id, status: status, token: token)
                self.work = try await client.fetchWork(id: work.id, token: token)
            } catch {
                markMessage = error.localizedDescription
            }
            isUpdatingMark = false
        }
    }

    private func reviewAction(for work: WorkDetail) -> some View {
        ReviewActionButton(
            isMarked: work.progress != nil,
            currentStatus: work.progress,
            isLoading: isUpdatingMark,
            isMenuPresented: $isMarkMenuPresented,
            message: markMessage,
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

private struct TrackBrowserView: View {
    let work: WorkDetail
    let tracks: [TrackNode]
    @Binding var currentPath: [TrackNode]
    @Binding var isPathMenuExpanded: Bool
    let player: WorkAudioPlayer

    private var isSingleRootFolder: Bool {
        tracks.count == 1 && tracks[0].isFolder
    }

    private var currentTitle: String {
        currentPath.last?.title ?? "/"
    }

    private var currentItems: [TrackNode] {
        currentPath.last?.children ?? tracks
    }

    private var playableItems: [TrackNode] {
        currentItems.filter { $0.isAudio && $0.audioURL != nil }
    }

    private var visiblePath: [TrackPathItem] {
        var items: [TrackPathItem] = []
        if !isSingleRootFolder {
            items.append(TrackPathItem(id: "root", title: "/", depth: 0))
        }

        for (index, node) in currentPath.enumerated() {
            items.append(TrackPathItem(id: pathID(through: index), title: node.title, depth: index + 1))
        }
        return items
    }

    private var itemRows: [TrackDisplayItem] {
        currentItems.enumerated().map { index, node in
            TrackDisplayItem(id: "\(currentPathID)/\(index)-\(node.id)", node: node)
        }
    }

    private var currentPathID: String {
        guard !currentPath.isEmpty else { return "root" }
        return currentPath.enumerated().map { "\($0.offset)-\($0.element.id)" }.joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isPathMenuExpanded {
                pathStack
            }

            if currentItems.isEmpty {
                Text("暂无文件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(itemRows) { item in
                        TrackBrowserNode(item: item, openFolder: openFolder) { node in
                            player.play(queue: playableItems, start: node, siblings: currentItems, work: work)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                isPathMenuExpanded.toggle()
            } label: {
                Label(currentTitle, systemImage: "folder")
                    .font(.headline)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)

            Image(systemName: isPathMenuExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(currentItems.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var pathStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visiblePath) { item in
                Button {
                    jump(to: item.depth)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .lineLimit(2)
                        Spacer()
                    }
                    .font(.subheadline)
                    .padding(.leading, CGFloat(item.depth * 14))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.background.opacity(0.45), in: .rect(cornerRadius: 12))
    }

    private func jump(to depth: Int) {
        currentPath = Array(currentPath.prefix(depth))
        isPathMenuExpanded = false
    }

    private func openFolder(_ node: TrackNode) {
        currentPath.append(node)
        isPathMenuExpanded = false
    }

    private func pathID(through index: Int) -> String {
        currentPath.prefix(index + 1).enumerated().map { "\($0.offset)-\($0.element.id)" }.joined(separator: "/")
    }
}

private struct TrackBrowserNode: View {
    let item: TrackDisplayItem
    let openFolder: (TrackNode) -> Void
    let playAudio: (TrackNode) -> Void

    var body: some View {
        if item.node.isFolder {
            Button {
                openFolder(item.node)
            } label: {
                TrackNodeRow(track: item.node)
            }
            .buttonStyle(.plain)
        } else if item.node.isAudio, item.node.audioURL != nil {
            Button {
                playAudio(item.node)
            } label: {
                TrackNodeRow(track: item.node)
            }
            .buttonStyle(.plain)
        } else {
            TrackNodeRow(track: item.node)
        }
    }

}

private struct ReviewActionButton: View {
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
        }
        .buttonStyle(.borderedProminent)
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

private struct PlaylistActionButton: View {
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
                Image(systemName: "playlist.badge.plus")
                Text("添加到播放列表")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
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

private struct TrackPathItem: Identifiable {
    let id: String
    let title: String
    let depth: Int
}

private struct TrackDisplayItem: Identifiable {
    let id: String
    let node: TrackNode
}

struct DetailHero: View {
    let work: WorkDetail
    let onTagSearch: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(url: work.mainCoverURL, cornerRadius: 18)
                .aspectRatio(4 / 3, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .overlay(alignment: .bottomLeading) {
                    Text(work.rjCode)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(10)
                        .contextMenu {
                            Button("复制 \(work.rjCode)") {
                                copy(work.rjCode)
                            }
                        }
                }

            VStack(alignment: .leading, spacing: 12) {
                Text(work.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                        VoiceActorChip(text: actor.name)
                    }

                    CircleChip(text: work.name)

                    ForEach(work.tags) { tag in
                        Button {
                            onTagSearch(tag.name)
                        } label: {
                            TagChip(text: tag.name)
                        }
                        .buttonStyle(.plain)
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

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
