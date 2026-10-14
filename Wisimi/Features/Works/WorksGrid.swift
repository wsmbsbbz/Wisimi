import SwiftUI

struct MasonryGrid: View {
    private let columnSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 12

    let works: [WorkSummary]
    let onSelect: (WorkSummary) -> Void
    @State private var availableWidth: CGFloat = 0

    private var leftColumn: [WorkSummary] {
        works.enumerated().compactMap { index, work in
            index.isMultiple(of: 2) ? work : nil
        }
    }

    private var rightColumn: [WorkSummary] {
        works.enumerated().compactMap { index, work in
            index.isMultiple(of: 2) ? nil : work
        }
    }

    private var columnWidth: CGFloat {
        max(floor((availableWidth - columnSpacing) / 2), 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    availableWidth = width
                }

            if columnWidth > 0 {
                HStack(alignment: .top, spacing: columnSpacing) {
                    column(leftColumn)
                    column(rightColumn)
                }
                .frame(width: availableWidth, alignment: .leading)
                .clipped()
            }
        }
    }

    private func column(_ works: [WorkSummary]) -> some View {
        LazyVStack(spacing: rowSpacing) {
            ForEach(works) { work in
                Button {
                    onSelect(work)
                } label: {
                    WorkRow(work: work, width: columnWidth)
                }
                .buttonStyle(.plain)
                .copyContextMenu(work.title, label: "作品标题")
                .frame(width: columnWidth)
                .clipped()
            }
        }
        .frame(width: columnWidth, alignment: .top)
        .clipped()
    }
}

struct PaginationControls: View {
    let currentPage: Int
    let totalPages: Int?
    let isLoading: Bool
    let onPageChanged: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            pageButton(
                symbol: "chevron.left",
                label: "上一页",
                page: currentPage - 1,
                disabled: currentPage <= 1 || isLoading
            )

            Text("\(currentPage)/\(totalPages.map(String.init) ?? "?")")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 44)

            pageButton(
                symbol: "chevron.right",
                label: "下一页",
                page: currentPage + 1,
                disabled: (totalPages.map { currentPage >= $0 } ?? true) || isLoading
            )

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func pageButton(symbol: String, label: String, page: Int, disabled: Bool) -> some View {
        Button {
            onPageChanged(page)
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .circle)
                .opacity(disabled ? 0.35 : 1)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(disabled)
    }
}
