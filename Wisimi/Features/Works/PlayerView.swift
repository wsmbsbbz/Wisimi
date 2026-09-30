import SwiftUI

struct PlayerView: View {
    @ObservedObject var player: WorkAudioPlayer
    let openWorkDetail: () -> Void
    @State private var isShowingSubtitles = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerMainContent(player: player, isShowingSubtitles: $isShowingSubtitles)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            VStack(spacing: 14) {
                if let message = player.playbackError {
                    InlineRetryView(message: message, retry: player.retryPlayback)
                } else if player.playbackState == .preparing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在准备播放…").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                PlayerProgress(player: player)
                PlayerControls(player: player)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .navigationTitle("播放器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openWorkDetail) {
                    Label("作品详情", systemImage: "info.circle")
                }
            }
        }
    }
}

private struct PlayerMainContent: View {
    @ObservedObject var player: WorkAudioPlayer
    @Binding var isShowingSubtitles: Bool

    var body: some View {
        Group {
            if isShowingSubtitles {
                SubtitleListView(player: player) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isShowingSubtitles = false
                    }
                }
            } else {
                PlayerCoverContent(player: player, isShowingSubtitles: $isShowingSubtitles)
            }
        }
    }
}

private struct PlayerCoverContent: View {
    @ObservedObject var player: WorkAudioPlayer
    @Binding var isShowingSubtitles: Bool

    var body: some View {
        GeometryReader { proxy in
            let coverWidth = min(max(proxy.size.width - 32, 0), max(proxy.size.height - 112, 0) * 4 / 3, 420)
            let coverSize = CGSize(width: coverWidth, height: coverWidth * 3 / 4)

            VStack(spacing: 18) {
                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isShowingSubtitles = true
                    }
                } label: {
                    CoverImage(url: player.coverURL, cornerRadius: 20, size: coverSize)
                        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                }
                .buttonStyle(.plain)

                VStack(spacing: 6) {
                    Text(player.currentTrack?.title ?? "未播放")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .copyContextMenu(player.currentTrack?.title ?? "未播放", label: "文件名")
                    Text(player.circleName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .copyContextMenu(player.circleName, label: "社团名称")
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PlayerProgress: View {
    @ObservedObject var player: WorkAudioPlayer
    @State private var isSeeking = false
    @State private var seekValue: TimeInterval = 0

    private var value: Binding<Double> {
        Binding {
            isSeeking ? seekValue : player.position
        } set: { newValue in
            seekValue = newValue
            isSeeking = true
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: value, in: 0...max(player.duration, 1)) { editing in
                if editing {
                    isSeeking = true
                } else {
                    player.seek(to: seekValue)
                    isSeeking = false
                }
            }

            HStack {
                Text((isSeeking ? seekValue : player.position).formattedDuration)
                Spacer()
                Text(player.duration.formattedDuration)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private struct PlayerControls: View {
    @ObservedObject var player: WorkAudioPlayer

    var body: some View {
        HStack(spacing: 28) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }

            PlaybackToggleButton(state: player.playbackState, action: player.togglePlayback)
                .disabled(player.currentTrack == nil)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SubtitleListView: View {
    @ObservedObject var player: WorkAudioPlayer
    let hideSubtitles: () -> Void
    @GestureState private var isTouchingSubtitleList = false
    @State private var subtitleAutoScrollResumeAt = Date.distantPast
    @State private var subtitleInteractionToken = 0

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                Color.clear

                if player.subtitles.isEmpty {
                    Text("暂无字幕")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(player.subtitles.enumerated()), id: \.element.id) { index, subtitle in
                                Button {
                                    player.seek(to: subtitle)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        NarrationStatusIcon(status: player.narrationStatuses[subtitle.id])

                                        Text(subtitle.text)
                                            .font(.subheadline)
                                            .fontWeight(index == player.currentSubtitleIndex ? .semibold : .regular)
                                            .foregroundStyle(index == player.currentSubtitleIndex ? .primary : .secondary)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .animation(.easeOut(duration: 0.25), value: player.currentSubtitleIndex)
                                }
                                .buttonStyle(.plain)
                                .copyContextMenu(subtitle.text, label: "字幕")
                                .id(index)
                            }
                        }
                        .padding(.vertical, 18)
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouchingSubtitleList) { _, state, _ in
                        state = true
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                TapGesture().onEnded(hideSubtitles),
                including: .gesture
            )
            .background(.thinMaterial, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: 20))
            .onChange(of: player.currentSubtitleIndex) {
                guard canAutoScrollToCurrentSubtitle else { return }
                scrollToCurrentSubtitle(with: proxy)
            }
            .onChange(of: isTouchingSubtitleList) {
                delaySubtitleAutoScroll()
            }
            .task(id: subtitleInteractionToken) {
                await scrollToCurrentSubtitleAfterIdle(with: proxy)
            }
        }
    }

    private var canAutoScrollToCurrentSubtitle: Bool {
        !isTouchingSubtitleList && Date() >= subtitleAutoScrollResumeAt
    }

    private func delaySubtitleAutoScroll() {
        subtitleAutoScrollResumeAt = Date().addingTimeInterval(3)
        subtitleInteractionToken += 1
    }

    private func scrollToCurrentSubtitleAfterIdle(with proxy: ScrollViewProxy) async {
        guard subtitleInteractionToken > 0 else { return }
        let delay = max(subtitleAutoScrollResumeAt.timeIntervalSinceNow, 0)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled, canAutoScrollToCurrentSubtitle else { return }
        scrollToCurrentSubtitle(with: proxy)
    }

    private func scrollToCurrentSubtitle(with proxy: ScrollViewProxy) {
        guard let index = player.currentSubtitleIndex else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}

private struct NarrationStatusIcon: View {
    let status: TTSGenerationStatus?

    var body: some View {
        Group {
            if let status {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(color(for: status))
                    .accessibilityLabel(label(for: status))
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 12)
    }

    private func color(for status: TTSGenerationStatus) -> Color {
        switch status {
        case .generating: .blue
        case .ready: .green
        case .failed: .red
        }
    }

    private func label(for status: TTSGenerationStatus) -> String {
        switch status {
        case .generating: "TTS 正在生成"
        case .ready: "TTS 已生成"
        case .failed: "TTS 生成失败"
        }
    }
}
