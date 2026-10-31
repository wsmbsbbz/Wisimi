import SwiftUI

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
