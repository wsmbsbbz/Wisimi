import SwiftUI

struct TrackDownloadStatus: Equatable {
    enum Tone: Equatable {
        case active
        case completed
        case failed
        case neutral
    }

    let title: String
    let symbol: String
    let tone: Tone
    var progress: Double? = nil
    var errorMessage: String? = nil
    var sizeText: String? = nil

    var foregroundColor: Color {
        switch tone {
        case .active: .accentColor
        case .completed: .green
        case .failed: .red
        case .neutral: .secondary
        }
    }
}

struct TrackNodeRow: View {
    let track: TrackNode
    var status: TrackDownloadStatus? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize.isAccessibilitySize, let status {
                mainRow
                statusLabel(status)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    mainRow
                    if let status {
                        statusLabel(status)
                    }
                }
            }

            if let sizeText = status?.sizeText {
                Text(sizeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if status?.tone == .active {
                if let progress = status?.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("文件下载进度")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("文件大小未知")
                }
            }

            if let errorMessage = status?.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.background.opacity(0.65), in: .rect(cornerRadius: 12))
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private var mainRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                if track.isPlayable {
                    Text(track.isVideo ? "视频 · \(track.durationText)" : track.durationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusLabel(_ status: TrackDownloadStatus) -> some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(status.foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: typeSize.isAccessibilitySize ? nil : 92, alignment: .trailing)
    }

    private var iconName: String {
        if track.isFolder { return "folder" }
        if track.isVideo { return "video" }
        if track.isAudio { return "play.circle" }
        if track.isSubtitle { return "captions.bubble" }
        if track.isImage { return "photo" }
        return "doc"
    }
}
