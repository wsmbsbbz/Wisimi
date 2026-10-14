import SwiftUI

struct SimilarWorksSection: View {
    let state: SimilarWorksState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visibleWorkID: Int?
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("相似作品").font(.title3.weight(.semibold))
                    Spacer()
                    allWorksLink
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("相似作品").font(.title3.weight(.semibold))
                    allWorksLink
                }
            }

            if !state.works.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(state.works.prefix(6)) { work in
                            NavigationLink(value: WorksRoute.detail(work.id)) {
                                SimilarWorkCard(work: work)
                                    .containerRelativeFrame(.horizontal) { length, _ in
                                        dynamicTypeSize.isAccessibilitySize ? min(length, 360) : min(240, (length - 24) / 2.2)
                                    }
                            }
                            .buttonStyle(PressFeedbackButtonStyle())
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $visibleWorkID)
            } else if state.isLoading || state.pagination == nil && state.errorMessage == nil {
                ProgressView("加载相似作品中…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let error = state.errorMessage {
                InlineRetryView(message: "相似作品加载失败：\(error)") {
                    runRequest { await state.retry() }
                }
            } else {
                Text("暂无相似作品").foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
        }
        .task { await state.loadIfNeeded() }
        .onDisappear { requestTask?.cancel() }
    }

    private func runRequest(_ operation: @escaping @MainActor () async -> Void) {
        guard requestTask == nil else { return }
        requestTask = Task {
            defer { requestTask = nil }
            await operation()
        }
    }

    private var allWorksLink: some View {
        NavigationLink(value: WorksRoute.similarWorks(state)) {
            Label("查看全部", systemImage: "chevron.right")
                .font(.subheadline)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .disabled(state.works.isEmpty)
    }
}

struct SimilarWorksListView: View {
    let state: SimilarWorksState
    let reservesMiniPlayerSpace: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrollPosition = ScrollPosition()
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("基于 RJ\(String(state.workID))")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(state.works) { work in
                        NavigationLink(value: WorksRoute.detail(work.id)) {
                            SimilarWorkCard(work: work)
                        }
                        .buttonStyle(PressFeedbackButtonStyle())
                    }
                }
                footer
                if reservesMiniPlayerSpace {
                    Color.clear.frame(height: miniPlayerAvoidanceHeight)
                }
            }
            .padding()
        }
        .scrollPosition($scrollPosition)
        .navigationTitle("相似作品")
        .navigationBarTitleDisplayMode(.inline)
        .task { await state.loadIfNeeded() }
        .onDisappear { requestTask?.cancel() }
    }

    private func runRequest(_ operation: @escaping @MainActor () async -> Void) {
        guard requestTask == nil else { return }
        requestTask = Task {
            defer { requestTask = nil }
            await operation()
        }
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12, alignment: .top)]
    }

    @ViewBuilder private var footer: some View {
        if state.isLoading {
            ProgressView("加载相似作品中…")
                .frame(maxWidth: .infinity, minHeight: 60)
        } else if let error = state.errorMessage {
            InlineRetryView(message: error) { runRequest { await state.retry() } }
        } else if state.works.isEmpty {
            Text("暂无相似作品").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else if state.hasMore {
            Button("加载更多") { runRequest { await state.loadMore() } }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            Text("已显示全部相似作品")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

private struct SimilarWorkCard: View {
    let work: WorkSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                if let url = work.thumbnailCoverURL {
                    CoverImage(url: url, cornerRadius: 0, size: geometry.size, contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle).foregroundStyle(.secondary)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(.quaternary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(work.title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(work.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3, reservesSpace: true)
                }
                Text(work.visibleVoiceActors.isEmpty ? work.name : work.visibleVoiceActors.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metrics }
                    VStack(alignment: .leading, spacing: 4) { metrics }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if work.hasSubtitle {
                    Label("字幕", systemImage: "captions.bubble")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开作品详情")
    }

    @ViewBuilder private var metrics: some View {
        if let rating = work.rateAverage, rating > 0 {
            Label(work.ratingText, systemImage: "star.fill")
                .accessibilityLabel("评分 \(work.ratingText)")
        }
        Label(work.durationText, systemImage: "clock")
    }
}
