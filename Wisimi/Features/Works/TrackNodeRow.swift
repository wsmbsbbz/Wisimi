import SwiftUI

struct TrackNodeRow: View {
    let track: TrackNode

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if track.isPlayable {
                    Text(track.isVideo ? "视频 · \(track.durationText)" : track.durationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.background.opacity(0.65), in: .rect(cornerRadius: 12))
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
