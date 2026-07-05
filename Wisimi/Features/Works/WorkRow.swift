import SwiftUI

private let maxTagRows = 10
private let tagRowHeight: CGFloat = 30

struct WorkRow: View {
    let work: WorkSummary
    let width: CGFloat

    var body: some View {
        let contentWidth = max(width - 20, 0)

        VStack(alignment: .leading, spacing: 0) {
            CoverImage(
                url: work.thumbnailCoverURL,
                cornerRadius: 0,
                size: CGSize(width: width, height: width * 3 / 4),
                contentMode: .fit
            )

            VStack(alignment: .leading, spacing: 12) {
                TitleBlock(work: work)

                WorkChipsFlow(work: work, maxWidth: contentWidth)
            }
            .padding(10)
        }
        .frame(width: width, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.quaternary, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct TitleBlock: View {
    let work: WorkSummary

    var body: some View {
        Text(work.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(10)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkChipsFlow: View {
    let work: WorkSummary
    let maxWidth: CGFloat

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            if let rateAverage = work.rateAverage, rateAverage > 0 {
                MetricPill(text: work.ratingText, systemImage: "star.fill")
            }

            MetricPill(text: work.durationText, systemImage: "clock")

            if work.hasSubtitle {
                MetricPill(text: "字幕", systemImage: "captions.bubble")
            }

            ForEach(work.visibleVoiceActors, id: \.self) { actor in
                VoiceActorChip(text: actor)
            }
            if work.hiddenVoiceActorCount > 0 {
                VoiceActorChip(text: "+\(work.hiddenVoiceActorCount)")
            }

            CircleChip(text: work.name)

            ForEach(work.tags) { tag in
                TagChip(text: tag.name)
            }
        }
        .frame(width: maxWidth, alignment: .leading)
        .frame(maxHeight: CGFloat(maxTagRows) * tagRowHeight, alignment: .top)
        .clipped()
    }
}

struct VoiceActorChip: View {
    let text: String

    var body: some View {
        TextChip(text: text, tint: .green, weight: .semibold)
    }
}

struct CircleChip: View {
    let text: String

    var body: some View {
        TextChip(text: text, tint: .blue, weight: .semibold)
    }
}

struct TagChip: View {
    let text: String

    var body: some View {
        TextChip(text: text)
    }
}

private struct TextChip: View {
    let text: String
    var tint: Color?
    var weight: Font.Weight = .medium

    var body: some View {
        if let tint {
            label
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: .capsule)
                .overlay {
                    Capsule()
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                }
        } else {
            label
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                }
        }
    }

    private var label: some View {
        Text(text)
            .font(.caption.weight(weight))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
    }
}

struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        guard maxWidth > 0 else {
            let size = subviews.reduce(CGSize.zero) { result, subview in
                let size = subview.sizeThatFits(.unspecified)
                return CGSize(width: max(result.width, size.width), height: result.height + size.height + spacing)
            }
            return CGSize(width: size.width, height: max(size.height - spacing, 0))
        }

        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = boundedSize(for: subview, maxWidth: maxWidth)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth == 0 ? size.width : spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        return CGSize(width: maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = boundedSize(for: subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func boundedSize(for subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return CGSize(width: min(size.width, maxWidth), height: size.height)
    }
}
