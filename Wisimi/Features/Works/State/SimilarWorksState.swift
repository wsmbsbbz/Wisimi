import Foundation
import Observation

@MainActor
@Observable
final class SimilarWorksState {
    let workID: Int
    let page = WorksPageState()
    var isExpanded = false
    private(set) var previewWorks: [WorkSummary] = []
    private(set) var isRetrying = false
    private let client: ASMRClient

    init(workID: Int, client: ASMRClient) {
        self.workID = workID
        self.client = client
    }

    var shouldShowSection: Bool {
        !previewWorks.isEmpty || page.errorMessage != nil || isRetrying
    }

    var displayedWorks: [WorkSummary] { isExpanded ? page.works : previewWorks }

    func loadIfNeeded() async {
        guard page.pagination == nil, page.errorMessage == nil, !page.isLoading else { return }
        await loadPage(1)
    }

    func loadPage(_ number: Int) async {
        guard number > 0, !Task.isCancelled else { return }
        if let pagination = page.pagination {
            guard number <= pagination.totalPages else { return }
            if number == page.currentPage, page.errorMessage == nil { return }
        } else if number != 1 { return }

        await page.load(page: number) { [client, workID] in
            let response = try await client.fetchSimilarWorks(workID: workID, page: number)
            var seen = Set<Int>()
            return WorksResponse(
                works: response.works.filter { $0.id != workID && seen.insert($0.id).inserted },
                pagination: response.pagination
            )
        }
        guard !Task.isCancelled, page.errorMessage == nil, page.pagination != nil, page.currentPage == 1 else { return }
        previewWorks = Array(page.works.prefix(4))
    }

    func retry() async {
        guard !page.isLoading else { return }
        isRetrying = true
        defer { isRetrying = false }
        await loadPage(page.requestedPage)
    }
}
