import Foundation
import Observation

@MainActor
@Observable
final class WorksPageState {
    private(set) var works: [WorkSummary] = []
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
        works = []
        pagination = nil
        currentPage = 1
        requestedPage = 1
        isLoading = false
        errorMessage = nil
    }

    func load(page: Int, operation: @escaping @MainActor () async throws -> WorksResponse) async {
        loadTask?.cancel()
        let id = UUID()
        requestID = id
        requestedPage = page
        isLoading = true
        errorMessage = nil
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
                works = response.works
                pagination = response.pagination
                currentPage = response.pagination.currentPage
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
    }
}


