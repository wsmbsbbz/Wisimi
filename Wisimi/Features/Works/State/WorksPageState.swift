import Foundation
import Observation

struct PagedResponse<Item> {
    let items: [Item]
    let pagination: WorksPagination
}

typealias WorksPageState = PagedState<WorkSummary>

@MainActor
@Observable
final class PagedState<Item> {
    private(set) var items: [Item] = []
    private(set) var pagination: WorksPagination?
    private(set) var currentPage = 1
    private(set) var requestedPage = 1
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var requestID = UUID()
    private var loadTask: Task<Void, Never>?

    func reset() {
        loadTask?.cancel()
        requestID = UUID()
        items = []
        pagination = nil
        currentPage = 1
        requestedPage = 1
        isLoading = false
        errorMessage = nil
    }

    func updateItems(_ transform: (inout [Item]) -> Void) {
        transform(&items)
    }

    func setError(_ message: String?) {
        errorMessage = message
    }

    @discardableResult
    func load(page: Int, operation: @escaping @MainActor () async throws -> PagedResponse<Item>) async -> Bool {
        loadTask?.cancel()
        let id = UUID()
        requestID = id
        requestedPage = page
        isLoading = true
        errorMessage = nil
        var didApply = false
        let task = Task {
            defer {
                if requestID == id {
                    isLoading = false
                    loadTask = nil
                }
            }
            do {
                let response = try await operation()
                guard requestID == id, !Task.isCancelled else { return }
                items = response.items
                pagination = response.pagination
                currentPage = response.pagination.currentPage
                didApply = true
            } catch {
                guard requestID == id, !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.userFacingMessage
            }
        }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return didApply
    }
}

extension PagedState where Item == WorkSummary {
    var works: [WorkSummary] { items }

    func loadWorks(page: Int, operation: @escaping @MainActor () async throws -> WorksResponse) async {
        await load(page: page) {
            let response = try await operation()
            return PagedResponse(items: response.works, pagination: response.pagination)
        }
    }
}


