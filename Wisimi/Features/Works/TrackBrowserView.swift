import SwiftUI

struct TrackBrowserView: View {
    let work: WorkDetail
    let tracks: [TrackNode]
    @Binding var currentPath: [TrackNode]
    @Binding var isPathMenuExpanded: Bool
    let player: WorkAudioPlayer
    @State private var imagePreview: TrackImagePreview?
    @State private var downloads = DownloadStore.shared
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var submissionMessage: String?

    private var selectedFiles: [TrackNode] {
        tracks.downloadableFiles.filter { selection.contains(DownloadStore.key(for: $0, workID: work.id)) }
    }

    private func keys(for nodes: [TrackNode]) -> Set<String> {
        Set(nodes.downloadableFiles.map { DownloadStore.key(for: $0, workID: work.id) })
    }

    private func toggleSelection(_ nodes: [TrackNode]) {
        let ids = keys(for: nodes)
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }


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
            if isSelecting {
                selectionControls
            }
            if let submissionMessage {
                Text(submissionMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let message = downloads.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }

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
                        HStack(spacing: 8) {
                            if isSelecting {
                                let ids = keys(for: [item.node])
                                Button {
                                    toggleSelection([item.node])
                                } label: {
                                    Image(systemName: !ids.isEmpty && ids.isSubset(of: selection) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .disabled(ids.isEmpty)
                                .accessibilityLabel("选择 \(item.node.title)")
                                .accessibilityValue(ids.isSubset(of: selection) ? "已选中" : "未选中")
                            }
                            TrackBrowserNode(
                                item: item,
                                workID: work.id,
                                openFolder: openFolder,
                                previewImage: { item in
                                    if isSelecting { toggleSelection([item.node]) }
                                    else { previewImage(item) }
                                }
                            ) { node in
                                if isSelecting {
                                    toggleSelection([node])
                                } else {
                                    player.play(queue: playableItems, start: node, siblings: currentItems, work: work)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] == "download-selection" {
                isSelecting = true
                selection = keys(for: currentItems)
            }
            #endif
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

            Button(isSelecting ? "完成" : "选择") {
                isSelecting.toggle()
                if !isSelecting { selection.removeAll() }
                submissionMessage = nil
            }
            .font(.subheadline)
            .disabled(tracks.downloadableFiles.isEmpty)
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(keys(for: currentItems).isSubset(of: selection) ? "取消当前文件夹全选" : "全选当前文件夹") {
                    toggleSelection(currentItems)
                }
                .disabled(currentItems.downloadableFiles.isEmpty)
                Spacer()
                Button("清空") { selection.removeAll() }.disabled(selection.isEmpty)
            }
            .font(.subheadline)
            Text("已选 \(selectedFiles.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: selectedFiles.reduce(0) { $0 + Int64($1.size ?? 0) }, countStyle: .file))\(selectedFiles.contains { $0.size == nil } ? "（部分大小未知）" : "")")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                let files = DownloadSelection.includingSubtitles(selectedFiles, in: tracks, workID: work.id)
                if downloads.enqueue(files, work: work, tracks: tracks) {
                    submissionMessage = "已加入下载，匹配字幕会一并缓存。可在下载管理中查看进度。"
                    selection.removeAll()
                    isSelecting = false
                }
            } label: {
                Label("下载所选文件", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty || !downloads.isReady)
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
        guard let url = downloads.localURL(for: item.node, workID: work.id) ?? item.node.imagePreviewURL else { return }
        imagePreview = TrackImagePreview(id: item.id, title: item.node.title, url: url)
    }

    private func pathID(through index: Int) -> String {
        currentPath.prefix(index + 1).enumerated().map { "\($0.offset)-\($0.element.id)" }.joined(separator: "/")
    }
}

private struct TrackBrowserNode: View {
    let item: TrackDisplayItem
    let workID: Int
    let openFolder: (TrackNode) -> Void
    let previewImage: (TrackDisplayItem) -> Void
    let playMedia: (TrackNode) -> Void

    var body: some View {
        Group {
            if item.node.isFolder {
                Button {
                    openFolder(item.node)
                } label: {
                    TrackNodeRow(track: item.node, workID: workID)
                }
                .buttonStyle(.plain)
            } else if item.node.isPlayable, item.node.playbackURL != nil {
                Button {
                    playMedia(item.node)
                } label: {
                    TrackNodeRow(track: item.node, workID: workID)
                }
                .buttonStyle(.plain)
            } else if item.node.imagePreviewURL != nil {
                Button {
                    previewImage(item)
                } label: {
                    TrackNodeRow(track: item.node, workID: workID)
                }
                .buttonStyle(.plain)
            } else {
                TrackNodeRow(track: item.node, workID: workID)
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
            let data: Data
            if url.isFileURL { data = try Data(contentsOf: url) }
            else { data = try await URLSession.shared.data(from: url).0 }
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
