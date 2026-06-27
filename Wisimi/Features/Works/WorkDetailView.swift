import SwiftUI

struct WorkDetailView: View {
    let workID: Int
    let client: ASMRClient

    @State private var work: WorkDetail?
    @State private var tracks: [TrackNode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var audioTracks: [TrackNode] {
        tracks.audioTracks
    }

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
                            SectionHeader(title: "音轨", count: audioTracks.count)
                            if audioTracks.isEmpty {
                                Text("暂无可展示音轨")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(audioTracks) { track in
                                        TrackRow(track: track)
                                    }
                                }
                            }
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
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct DetailHero: View {
    let work: WorkDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(url: work.mainCoverURL, cornerRadius: 18)
                .aspectRatio(4 / 3, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

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
                    MetricPill(text: "\(work.dlCount)", systemImage: "arrow.down.circle", prominence: .strong)

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
}
