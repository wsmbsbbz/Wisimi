import SwiftUI

struct PagedWorksContent<EmptyContent: View>: View {
    let works: [WorkCardSummary]
    let pagination: WorksPagination?
    let currentPage: Int
    let isLoading: Bool
    let errorMessage: String?
    let loadingTitle: String
    let onRetry: () async -> Void
    let onPageChanged: (Int) async -> Void
    let onSelect: (WorkReference) -> Void
    @ViewBuilder let emptyContent: () -> EmptyContent

    var body: some View {
        if isLoading && works.isEmpty {
            ProgressView(loadingTitle)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let errorMessage, works.isEmpty {
            RetryView(message: errorMessage, retry: onRetry)
        } else if works.isEmpty {
            emptyContent()
        } else {
            VStack(spacing: 18) {
                if let errorMessage {
                    InlineRetryView(message: errorMessage) {
                        Task { await onRetry() }
                    }
                }
                MasonryGrid(works: works, onSelect: onSelect)
                PaginationControls(
                    currentPage: currentPage,
                    totalPages: pagination?.totalPages,
                    isLoading: isLoading
                ) { page in
                    Task { await onPageChanged(page) }
                }
            }
        }
    }
}
