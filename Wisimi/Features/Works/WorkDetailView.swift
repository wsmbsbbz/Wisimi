import SwiftUI
import Observation

@MainActor
@Observable
final class WorkDetailPageState {
    private(set) var loadedWorkID: Int?
    var work: WorkDetail?
    var tracks: [TrackNode] = []
    var currentPath: [TrackNode] = []
    var isPathMenuExpanded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    static func shouldLoad(requestedWorkID: Int, loadedWorkID: Int?, hasWork: Bool, force: Bool) -> Bool {
        force || loadedWorkID != requestedWorkID || !hasWork
    }

    func beginLoading(workID: Int, force: Bool) -> Bool {
        guard !isLoading else { return false }
        guard Self.shouldLoad(
            requestedWorkID: workID,
            loadedWorkID: loadedWorkID,
            hasWork: work != nil,
            force: force
        ) else { return false }

        isLoading = true
        errorMessage = nil
        return true
    }

    func finishLoading(work: WorkDetail, tracks: [TrackNode], workID: Int) {
        let previousPathIDs = loadedWorkID == workID && self.work != nil ? currentPath.map(\.id) : nil

        self.work = work
        self.tracks = tracks
        if let previousPathIDs {
            currentPath = tracks.resolvingDirectoryPath(ids: previousPathIDs) ?? tracks.defaultDirectoryPath
        } else {
            currentPath = tracks.defaultDirectoryPath
            isPathMenuExpanded = false
        }
        loadedWorkID = workID
        isLoading = false
        errorMessage = nil
    }

    func finishLoading(with error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
    }
}

extension Array where Element == TrackNode {
    func resolvingDirectoryPath(ids: [TrackNode.ID]) -> [TrackNode]? {
        guard !ids.isEmpty else { return [] }

        var siblings = self
        var resolvedPath: [TrackNode] = []
        for id in ids {
            guard let folder = siblings.first(where: { $0.id == id && $0.isFolder }) else { return nil }
            resolvedPath.append(folder)
            siblings = folder.children ?? []
        }
        return resolvedPath
    }
}

#if DEBUG
enum WorkDetailStateSelfCheck {
    static func run() {
        assert(WorkDetailPageState.shouldLoad(requestedWorkID: 1, loadedWorkID: nil, hasWork: false, force: false))
        assert(!WorkDetailPageState.shouldLoad(requestedWorkID: 1, loadedWorkID: 1, hasWork: true, force: false))
        assert(WorkDetailPageState.shouldLoad(requestedWorkID: 1, loadedWorkID: 1, hasWork: true, force: true))
        assert(WorkDetailPageState.shouldLoad(requestedWorkID: 2, loadedWorkID: 1, hasWork: true, force: false))

        let json = #"[{"type":"folder","title":"root","children":[{"type":"folder","title":"chapter","children":[{"type":"audio","title":"01.mp3","hash":"track-1"}]}]}]"#
        let tracks = try? JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))
        let restored = tracks?.resolvingDirectoryPath(ids: ["folder-root", "folder-chapter"])
        assert(restored?.map(\.title) == ["root", "chapter"])
        assert(tracks?.resolvingDirectoryPath(ids: ["folder-root", "folder-missing"]) == nil)
    }
}
#endif

struct WorkDetailView: View {
    let workID: Int
    let client: ASMRClient
    @ObservedObject var auth: AuthSession
    let player: WorkAudioPlayer
    let reservesMiniPlayerSpace: Bool
    let onSearch: (String, String) -> Void
    let onLoginRequired: () -> Void

    @State private var pageState = WorkDetailPageState()
    @State private var scrollPosition = ScrollPosition()
    @State private var isUpdatingMark = false
    @State private var isMarkMenuPresented = false
    @State private var isPlaylistMenuPresented = false
    @State private var markMessage: String?

    var body: some View {
        Group {
            if pageState.isLoading && pageState.work == nil {
                ProgressView("加载详情中...")
            } else if let errorMessage = pageState.errorMessage, pageState.work == nil {
                RetryView(message: errorMessage) {
                    await loadDetail(force: true)
                }
            } else if let work = pageState.work {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DetailHero(work: work, onSearch: onSearch)

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
                                tracks: pageState.tracks,
                                currentPath: $pageState.currentPath,
                                isPathMenuExpanded: $pageState.isPathMenuExpanded,
                                player: player
                            )
                        }

                        if reservesMiniPlayerSpace {
                            Color.clear.frame(height: miniPlayerAvoidanceHeight)
                        }
                    }
                    .padding()
                }
                .scrollPosition($scrollPosition)
            } else {
                EmptyStateView {
                    await loadDetail(force: true)
                }
            }
        }
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDetail(force: false)
        }
        .onChange(of: auth.token) {
            Task { await loadDetail(force: true) }
        }
    }

    private func loadDetail(force: Bool) async {
        guard pageState.beginLoading(workID: workID, force: force) else { return }
        do {
            async let detail = client.fetchWork(id: workID, token: auth.token)
            async let trackList = client.fetchTracks(workID: workID)
            let loadedWork = try await detail
            let loadedTracks = try await trackList
            pageState.finishLoading(work: loadedWork, tracks: loadedTracks, workID: workID)
        } catch {
            pageState.finishLoading(with: error)
        }
    }

    private func toggleMark() {
        guard let work = pageState.work else { return }
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
                pageState.work = try await client.fetchWork(id: work.id, token: token)
            } catch {
                markMessage = error.localizedDescription
            }
            isUpdatingMark = false
        }
    }

    private func mark(_ status: ReviewStatus) {
        guard let work = pageState.work, let token = auth.token else { return }

        Task {
            isUpdatingMark = true
            markMessage = nil
            do {
                try await client.markWork(id: work.id, status: status, token: token)
                pageState.work = try await client.fetchWork(id: work.id, token: token)
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
    @State private var imagePreview: TrackImagePreview?

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
        currentItems.playableTracks
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
                        TrackBrowserNode(
                            item: item,
                            openFolder: openFolder,
                            previewImage: previewImage
                        ) { node in
                            player.play(queue: playableItems, start: node, siblings: currentItems, work: work)
                        }
                    }
                }
            }
        }
        .sheet(item: $imagePreview) { preview in
            ImagePreviewSheet(preview: preview)
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
            .copyContextMenu(currentTitle, label: "文件夹名称")

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
                .copyContextMenu(item.title, label: "文件夹名称")
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

    private func previewImage(_ item: TrackDisplayItem) {
        guard let url = item.node.imagePreviewURL else { return }
        imagePreview = TrackImagePreview(id: item.id, title: item.node.title, url: url)
    }

    private func pathID(through index: Int) -> String {
        currentPath.prefix(index + 1).enumerated().map { "\($0.offset)-\($0.element.id)" }.joined(separator: "/")
    }
}

private struct TrackBrowserNode: View {
    let item: TrackDisplayItem
    let openFolder: (TrackNode) -> Void
    let previewImage: (TrackDisplayItem) -> Void
    let playMedia: (TrackNode) -> Void

    var body: some View {
        Group {
            if item.node.isFolder {
                Button {
                    openFolder(item.node)
                } label: {
                    TrackNodeRow(track: item.node)
                }
                .buttonStyle(.plain)
            } else if item.node.isPlayable, item.node.playbackURL != nil {
                Button {
                    playMedia(item.node)
                } label: {
                    TrackNodeRow(track: item.node)
                }
                .buttonStyle(.plain)
            } else if item.node.imagePreviewURL != nil {
                Button {
                    previewImage(item)
                } label: {
                    TrackNodeRow(track: item.node)
                }
                .buttonStyle(.plain)
            } else {
                TrackNodeRow(track: item.node)
            }
        }
        .copyContextMenu(item.node.title, label: "文件名")
    }
}

private struct ImagePreviewSheet: View {
    let preview: TrackImagePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ZoomableRemoteImage(url: preview.url)
                .padding()
            }
            .navigationTitle(preview.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ZoomableRemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else if didFail {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        image = nil
        didFail = false
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let loadedImage = UIImage(data: data) else {
                didFail = true
                return
            }
            image = loadedImage
        } catch {
            didFail = true
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.layoutImage(in: scrollView)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.imageSize = image.size
        context.coordinator.layoutImage(in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var imageSize: CGSize = .zero
        private var lastImageSize: CGSize = .zero
        private var lastBoundsSize: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        func layoutImage(in scrollView: UIScrollView) {
            guard imageSize.width > 0, imageSize.height > 0, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            guard imageSize != lastImageSize || scrollView.bounds.size != lastBoundsSize else { return }
            let scale = min(scrollView.bounds.width / imageSize.width, scrollView.bounds.height / imageSize.height)
            let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView?.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            scrollView.zoomScale = 1
            lastImageSize = imageSize
            lastBoundsSize = scrollView.bounds.size
            centerImage(in: scrollView)
        }

        @objc func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let width = scrollView.bounds.width / 2
                let height = scrollView.bounds.height / 2
                scrollView.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
            }
        }

        private func centerImage(in scrollView: UIScrollView) {
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
        }
    }

    final class ZoomScrollView: UIScrollView {
        var onLayout: ((UIScrollView) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(self)
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

private struct TrackPathItem: Identifiable {
    let id: String
    let title: String
    let depth: Int
}

private struct TrackDisplayItem: Identifiable {
    let id: String
    let node: TrackNode
}

private struct TrackImagePreview: Identifiable {
    let id: String
    let title: String
    let url: URL
}

struct DetailHero: View {
    let work: WorkDetail
    let onSearch: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                CoverImage(
                    url: work.mainCoverURL,
                    cornerRadius: 18,
                    size: CGSize(width: proxy.size.width, height: proxy.size.width * 3 / 4)
                )
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .overlay(alignment: .bottomLeading) {
                    Text(work.rjCode)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(10)
                        .copyContextMenu(work.rjCode, label: "RJ 号")
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 12) {
                Text(work.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

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
                        Button {
                            onSearch("va", actor.name)
                        } label: {
                            VoiceActorChip(text: actor.name)
                        }
                        .buttonStyle(.plain)
                        .copyContextMenu(actor.name, label: "声优名称")
                    }

                    Button {
                        onSearch("circle", work.name)
                    } label: {
                        CircleChip(text: work.name)
                    }
                    .buttonStyle(.plain)
                    .copyContextMenu(work.name, label: "社团名称")

                    ForEach(work.tags) { tag in
                        Button {
                            onSearch("tag", tag.name)
                        } label: {
                            TagChip(text: tag.name)
                        }
                        .buttonStyle(.plain)
                        .copyContextMenu(tag.name, label: "标签")
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
}
