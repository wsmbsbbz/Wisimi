import Foundation
import Observation

@MainActor
@Observable
final class SimilarWorksState: Hashable {
    let workID: Int
    private(set) var works: [WorkSummary] = []
    private(set) var pagination: WorksPagination?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var requestedPage = 1
    private var loadTask: Task<Void, Never>?
    private let client: ASMRClient

    init(workID: Int, client: ASMRClient) {
        self.workID = workID
        self.client = client
    }

    // 路由按页面实例标识，分页更新不会改变导航身份。
    nonisolated static func == (lhs: SimilarWorksState, rhs: SimilarWorksState) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var hasMore: Bool {
        guard let pagination else { return false }
        return pagination.currentPage < pagination.totalPages
    }

    func loadIfNeeded() async {
        if let loadTask { await loadTask.value }
        guard pagination == nil, errorMessage == nil, !Task.isCancelled else { return }
        await load(page: 1)
    }

    func loadMore() async {
        guard let pagination, hasMore else { return }
        await load(page: pagination.currentPage + 1)
    }

    func retry() async { await load(page: requestedPage) }

    private func load(page: Int) async {
        guard !isLoading, !Task.isCancelled else { return }
        requestedPage = page
        isLoading = true
        errorMessage = nil
        let task = Task {
            defer { isLoading = false; loadTask = nil }
            do {
                let response = try await client.fetchSimilarWorks(workID: workID, page: page)
                try Task.checkCancellation()
                var seen = Set(works.map(\.id))
                let additions = response.works.filter { $0.id != workID && seen.insert($0.id).inserted }
                works.append(contentsOf: additions)
                pagination = response.pagination
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = error.userFacingMessage }
            }
        }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
