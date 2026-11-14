import SwiftUI
import UIKit

struct TrackBrowserView: View {
    let work: WorkPresentation
    var onlineWork: WorkDetail? = nil
    let tracks: [TrackNode]
    @Binding var currentPath: [TrackNode]
    @Binding var isPathMenuExpanded: Bool
    let player: WorkAudioPlayer
    var localWorkID: UUID? = nil
    var onOpenLocalLibrary: (() -> Void)? = nil
    var onDeleteEntry: ((DownloadEntry) -> Void)? = nil
    @State private var imagePreview: TrackImagePreview?
    @State private var downloads = DownloadStore.shared
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var submissionMessage: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private func isAlreadyDownloaded(_ node: TrackNode) -> Bool {
        guard let onlineWork else { return false }
        return downloads.localURL(for: node, workID: onlineWork.id) != nil
    }

    private func selectableFiles(in nodes: [TrackNode]) -> [TrackNode] {
        guard onlineWork != nil else { return [] }
        return nodes.downloadableFiles.filter { !isAlreadyDownloaded($0) }
    }

    private var selectedFiles: [TrackNode] {
        guard let onlineWork else { return [] }
        return selectableFiles(in: tracks).filter { selection.contains(DownloadStore.key(for: $0, workID: onlineWork.id)) }
    }

    private func keys(for nodes: [TrackNode]) -> Set<String> {
        guard let onlineWork else { return [] }
        return Set(selectableFiles(in: nodes).map { DownloadStore.key(for: $0, workID: onlineWork.id) })
    }

    private func toggleSelection(_ nodes: [TrackNode]) {
        let ids = keys(for: nodes)
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    private func downloadEntry(for node: TrackNode) -> DownloadEntry? {
        if let onlineWork {
            return downloads.entry(for: node, workID: onlineWork.id)
        }
        if let localWorkID, !node.isFolder {
            return downloads.entry(for: node, localWorkID: localWorkID)
        }
        return nil
    }

    private func rowStatus(for node: TrackNode) -> TrackDownloadStatus? {
        guard let entry = downloadEntry(for: node) else { return nil }
        let isMissing = entry.state == .completed && downloads.localURL(for: entry) == nil
        let isLocalDetail = localWorkID != nil
        switch entry.state {
        case .completed:
            if isMissing {
                return TrackDownloadStatus(
                    title: "文件缺失",
                    symbol: "exclamationmark.circle",
                    tone: .failed,
                    errorMessage: isLocalDetail ? "本地文件已丢失，请重新下载" : nil
                )
            }
            return TrackDownloadStatus(title: "已下载", symbol: "checkmark.circle.fill", tone: .completed)
        case .downloading:
            let title = entry.progress.map { "下载中 \(Int(($0 * 100).rounded()))%" } ?? entry.displayStatus
            return TrackDownloadStatus(
                title: title,
                symbol: entry.state.symbol,
                tone: .active,
                progress: isLocalDetail ? entry.progress : nil,
                sizeText: isLocalDetail ? entry.sizeText : nil
            )
        case .paused:
            return TrackDownloadStatus(
                title: "已暂停",
                symbol: entry.state.symbol,
                tone: .neutral,
                sizeText: isLocalDetail ? entry.sizeText : nil
            )
        case .failed:
            return TrackDownloadStatus(
                title: "失败",
                symbol: entry.state.symbol,
                tone: .failed,
                errorMessage: isLocalDetail ? entry.error : nil,
                sizeText: isLocalDetail ? entry.sizeText : nil
            )
        }
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(submissionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let onOpenLocalLibrary {
                            Button("前往本地", action: onOpenLocalLibrary)
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(submissionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let onOpenLocalLibrary {
                            Button("前往本地", action: onOpenLocalLibrary)
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                    }
                }
            }
            if (onlineWork != nil || localWorkID != nil), let message = downloads.message {
                HStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("关闭") { downloads.message = nil }
                        .font(.caption)
                        .frame(minHeight: 44)
                }
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
                        let localEntry = localWorkID != nil ? downloadEntry(for: item.node) : nil
                        let row = TrackBrowserNode(
                            item: item,
                            status: rowStatus(for: item.node),
                            localEntry: localEntry,
                            downloads: downloads,
                            onDeleteEntry: onDeleteEntry,
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

                        if isSelecting {
                            HStack(spacing: 8) {
                                selectionIndicator(for: item.node)
                                row
                            }
                        } else if let localEntry {
                            if typeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 4) {
                                    row
                                    localEntryControls(localEntry)
                                }
                            } else {
                                HStack(spacing: 4) {
                                    row
                                    localEntryControls(localEntry)
                                }
                            }
                        } else {
                            row
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
            .buttonStyle(PressFeedbackButtonStyle())
            .copyContextMenu(currentTitle, label: "文件夹名称")

            Image(systemName: isPathMenuExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if onlineWork != nil {
                Button(isSelecting ? "完成" : "选择") {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                    submissionMessage = nil
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .disabled(!isSelecting && selectableFiles(in: tracks).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func selectionIndicator(for node: TrackNode) -> some View {
        let ids = keys(for: [node])
        let allAlreadyDownloaded = ids.isEmpty && !([node].downloadableFiles.isEmpty)
        if allAlreadyDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 44, height: 44)
                .accessibilityLabel("选择 \(node.title)")
                .accessibilityValue("已下载")
        } else {
            Button {
                toggleSelection([node])
            } label: {
                Image(systemName: !ids.isEmpty && ids.isSubset(of: selection) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .disabled(ids.isEmpty)
            .accessibilityLabel("选择 \(node.title)")
            .accessibilityValue(ids.isSubset(of: selection) ? "已选中" : "未选中")
        }
    }

    @ViewBuilder
    private func localEntryControls(_ entry: DownloadEntry) -> some View {
        let transferAction = TrackTransferAction(entry: entry, downloads: downloads)
        HStack(spacing: 0) {
            if let transferAction {
                Button(action: transferAction.perform) {
                    Label(transferAction.shortTitle, systemImage: transferAction.symbol)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(transferAction.shortTitle)：\(entry.track.title)")
            }
            if let onDeleteEntry {
                Menu {
                    if let transferAction {
                        Button(transferAction.menuTitle, systemImage: transferAction.symbol, action: transferAction.perform)
                    }
                    Button("删除文件", systemImage: "trash", role: .destructive) {
                        onDeleteEntry(entry)
                    }
                } label: {
                    Label("文件操作", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("操作：\(entry.track.title)")
            }
        }
        .buttonStyle(.borderless)
        .disabled(!downloads.isReady)
    }

    private var selectionControls: some View {
        let folderKeys = keys(for: currentItems)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(!folderKeys.isEmpty && folderKeys.isSubset(of: selection) ? "取消当前文件夹全选" : "全选当前文件夹") {
                    toggleSelection(currentItems)
                }
                .disabled(folderKeys.isEmpty)
                Spacer()
                Button("清空") { selection.removeAll() }.disabled(selection.isEmpty)
            }
            .font(.subheadline)
            Text("已选 \(selectedFiles.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: selectedFiles.reduce(0) { $0 + Int64($1.size ?? 0) }, countStyle: .file))\(selectedFiles.contains { $0.size == nil } ? "（部分大小未知）" : "")")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                guard let onlineWork else { return }
                let files = DownloadSelection.includingSubtitles(selectedFiles, in: tracks, workID: onlineWork.id)
                if downloads.enqueue(files, work: onlineWork, tracks: tracks) {
                    submissionMessage = "已加入下载，匹配字幕会一并缓存。可在「本地」中查看进度。"
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
                .buttonStyle(PressFeedbackButtonStyle())
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
    let status: TrackDownloadStatus?
    let localEntry: DownloadEntry?
    let downloads: DownloadStore
    let onDeleteEntry: ((DownloadEntry) -> Void)?
    let openFolder: (TrackNode) -> Void
    let previewImage: (TrackDisplayItem) -> Void
    let playMedia: (TrackNode) -> Void

    var body: some View {
        rowContent
            .modifier(TrackNodeMenuModifier(
                title: item.node.title,
                localEntry: localEntry,
                downloads: downloads,
                onDeleteEntry: onDeleteEntry
            ))
    }

    @ViewBuilder
    private var rowContent: some View {
        if let action {
            Button(action: action) {
                TrackNodeRow(track: item.node, status: status)
            }
            .buttonStyle(PressFeedbackButtonStyle())
        } else {
            TrackNodeRow(track: item.node, status: status)
        }
    }

    private var action: (() -> Void)? {
        if item.node.isFolder { return { openFolder(item.node) } }
        if item.node.isPlayable, item.node.playbackURL != nil { return { playMedia(item.node) } }
        if item.node.imagePreviewURL != nil { return { previewImage(item) } }
        return nil
    }
}

private struct TrackTransferAction {
    let shortTitle: String
    let menuTitle: String
    let symbol: String
    let perform: () -> Void

    init?(entry: DownloadEntry, downloads: DownloadStore) {
        let isMissing = entry.state == .completed && downloads.localURL(for: entry) == nil
        switch entry.state {
        case .downloading:
            shortTitle = "暂停"
            menuTitle = "暂停下载"
            symbol = "pause"
            perform = { downloads.pause(entry.id) }
        case .paused:
            shortTitle = "继续"
            menuTitle = "继续下载"
            symbol = "play"
            perform = { downloads.resume(entry.id) }
        case .failed, .completed where isMissing:
            shortTitle = "重试"
            menuTitle = "重试下载"
            symbol = "arrow.clockwise"
            perform = { downloads.retry(entry.id) }
        case .completed:
            return nil
        }
    }
}

private struct TrackNodeMenuModifier: ViewModifier {
    let title: String
    let localEntry: DownloadEntry?
    let downloads: DownloadStore
    let onDeleteEntry: ((DownloadEntry) -> Void)?

    func body(content: Content) -> some View {
        if let localEntry {
            let transferAction = TrackTransferAction(entry: localEntry, downloads: downloads)
            content.contextMenu {
                if let transferAction {
                    Button(transferAction.menuTitle, systemImage: transferAction.symbol, action: transferAction.perform)
                        .disabled(!downloads.isReady)
                }
                Button {
                    UIPasteboard.general.string = title
                } label: {
                    Label("复制文件名", systemImage: "doc.on.doc")
                }
                if let onDeleteEntry {
                    Button("删除文件", systemImage: "trash", role: .destructive) {
                        onDeleteEntry(localEntry)
                    }
                    .disabled(!downloads.isReady)
                }
            }
        } else {
            content.copyContextMenu(title, label: "文件名")
        }
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
                ToolbarItem(placement: .confirmationAction) {
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
