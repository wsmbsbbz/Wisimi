import SwiftUI

struct SimilarWorksSection: View {
    let state: SimilarWorksState
    let onSelect: (WorkSummary) -> Void
    let onReposition: () -> Void
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer()
                    disclosureButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    disclosureButton
                }
            }

            if state.isExpanded { pagination }

            if state.isRetrying && state.previewWorks.isEmpty {
                ProgressView("正在重试…")
            } else if state.page.errorMessage != nil {
                retryNotice
            }

            MasonryGrid(works: state.displayedWorks, onSelect: onSelect)

            if state.isExpanded {
                if state.page.works.isEmpty && !state.page.isLoading && state.page.errorMessage == nil {
                    Text("本页暂无相似作品").foregroundStyle(.secondary)
                }
                if state.page.errorMessage != nil { retryNotice }
                pagination
            }
        }
        .onChange(of: state.page.currentPage) {
            if state.isExpanded { onReposition() }
        }
        .onDisappear { requestTask?.cancel() }
    }

    private var title: some View {
        Text("相似作品").font(.title3.weight(.semibold))
    }

    @ViewBuilder private var retryNotice: some View {
        if let error = state.page.errorMessage {
            InlineRetryView(message: "相似作品加载失败：\(error)") {
                runRequest { await state.retry() }
            }
        }
    }

    private var disclosureButton: some View {
        Button {
            state.isExpanded.toggle()
            onReposition()
        } label: {
            Label(state.isExpanded ? "收起" : "展开浏览", systemImage: state.isExpanded ? "chevron.up" : "chevron.down")
                .font(.subheadline)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .disabled(state.previewWorks.isEmpty || state.page.isLoading)
        .accessibilityValue(state.isExpanded ? "已展开" : "已收起")
    }

    private var pagination: some View {
        PaginationControls(
            currentPage: state.page.currentPage,
            totalPages: state.page.pagination?.totalPages,
            isLoading: state.page.isLoading
        ) { number in
            runRequest { await state.loadPage(number) }
        }
    }

    private func runRequest(_ operation: @escaping @MainActor () async -> Void) {
        guard requestTask == nil else { return }
        requestTask = Task {
            defer { requestTask = nil }
            await operation()
        }
    }
}
