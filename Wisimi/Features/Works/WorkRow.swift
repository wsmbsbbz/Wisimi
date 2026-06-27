import SwiftUI

private let workRowCoverSize = CGSize(width: 144, height: 108)

struct WorkRow: View {
    let work: WorkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                CoverImage(url: work.thumbnailCoverURL, cornerRadius: 12, size: workRowCoverSize)

                WorkMetaColumn(work: work)
            }

            TitleBlock(work: work)

            TagsRow(work: work)
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TitleBlock: View {
    let work: WorkSummary

    var body: some View {
        Text(work.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkMetaColumn: View {
    let work: WorkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !work.visibleVoiceActors.isEmpty {
                HStack(spacing: 6) {
                    ForEach(work.visibleVoiceActors, id: \.self) { actor in
                        VoiceActorChip(text: actor)
                    }
                    if work.hiddenVoiceActorCount > 0 {
                        VoiceActorChip(text: "+\(work.hiddenVoiceActorCount)")
                    }
                }
            }

            Spacer(minLength: 0)

            CircleChip(text: work.name)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                MetricPill(text: work.ratingText, systemImage: "star.fill")
                MetricPill(text: work.durationText, systemImage: "clock")
                if work.hasSubtitle {
                    MetricPill(text: "字幕", systemImage: "captions.bubble")
                }
            }
        }
        .frame(height: workRowCoverSize.height)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct VoiceActorChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.green)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.green.opacity(0.12), in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.green.opacity(0.25), lineWidth: 1)
            }
    }
}

private struct CircleChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.blue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.blue.opacity(0.12), in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.blue.opacity(0.25), lineWidth: 1)
            }
    }
}

private struct TagsRow: View {
    let work: WorkSummary

    var body: some View {
        if !work.visibleTags.isEmpty {
            HStack(spacing: 8) {
                ForEach(work.visibleTags, id: \.self) { tag in
                    TagChip(text: tag)
                }
                if work.hiddenTagCount > 0 {
                    TagChip(text: "+\(work.hiddenTagCount)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}
