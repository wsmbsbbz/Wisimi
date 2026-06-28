import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WorkDetailView: View {
    let workID: Int
    let client: ASMRClient
    let player: WorkAudioPlayer

    @State private var work: WorkDetail?
    @State private var tracks: [TrackNode] = []
    @State private var currentPath: [TrackNode] = []
    @State private var isPathMenuExpanded = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && work == nil {
                ProgressView("加载详情中...")
            } else if let errorMessage, work == nil {
                RetryView(message: errorMessage, retry: loadDetail)
            } else if let work {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DetailHero(work: work)

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
    }

    private func loadDetail() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let detail = client.fetchWork(id: workID)
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
                        TagChip(text: tag.name)
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
