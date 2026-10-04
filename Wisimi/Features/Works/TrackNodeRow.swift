import SwiftUI

struct TrackNodeRow: View {
    let track: TrackNode
    var workID: Int? = nil
    @State private var downloads = DownloadStore.shared

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
            if let workID, let entry = downloads.entry(for: track, workID: workID) {
                let cached = downloads.localURL(for: track, workID: workID) != nil
                Label(entry.state == .completed && !cached ? "文件缺失" : entry.state.title,
                      systemImage: cached ? "checkmark.circle.fill" : entry.state.symbol)
                    .font(.caption)
                    .foregroundStyle(cached ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 76)
            }
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
