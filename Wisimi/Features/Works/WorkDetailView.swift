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

                        if !work.vas.isEmpty || !work.tags.isEmpty {
                            InfoCard {
                                if !work.vas.isEmpty {
                                    ChipSection(title: "声优", values: work.vas.map(\.name))
                                }

                                if !work.tags.isEmpty {
                                    ChipSection(title: "标签", values: work.tags.map(\.name))
                                }
                            }
                        }

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
        VStack(spacing: 14) {
            CoverImage(url: work.mainCoverURL, cornerRadius: 18)
                .aspectRatio(4 / 3, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

            VStack(spacing: 6) {
                Text(work.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(work.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                MetricPill(text: work.ratingText, systemImage: "star.fill", prominence: .strong)
                MetricPill(text: work.durationText, systemImage: "clock", prominence: .strong)
                MetricPill(text: "\(work.dlCount)", systemImage: "arrow.down.circle", prominence: .strong)
                MetricPill(text: work.hasSubtitle ? "有字幕" : "无字幕", systemImage: "captions.bubble", prominence: .strong)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }
}

struct ChipSection: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, count: values.count)
            FlowLayout(values: values)
        }
    }
}
