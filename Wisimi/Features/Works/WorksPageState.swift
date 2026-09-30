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

#if DEBUG
@MainActor
enum WorksPageStateSelfCheck {
    static func run() async {
        let state = WorksPageState()
        let json = #"{"id":2,"title":"new search","name":"circle","has_subtitle":true,"tags":[],"vas":[]}"#
        let work = try! JSONDecoder().decode(WorkSummary.self, from: Data(json.utf8))
        let response = WorksResponse(works: [work], pagination: WorksPagination(currentPage: 2, pageSize: 12, totalCount: 36))
        var oldRequest: CheckedContinuation<WorksResponse, Error>?
        let old = Task {
            await state.load(page: 1) {
                try await withCheckedThrowingContinuation { oldRequest = $0 }
            }
        }
        while oldRequest == nil { await Task.yield() }
        await state.load(page: 2) { response }
        oldRequest?.resume(returning: WorksResponse(works: [], pagination: WorksPagination(currentPage: 1, pageSize: 12, totalCount: 12)))
        await old.value
        assert(state.works.first?.id == 2 && state.currentPage == 2 && state.pagination?.totalCount == 36 && !state.isLoading)

        oldRequest = nil
        let failedOld = Task {
            await state.load(page: 1) {
                try await withCheckedThrowingContinuation { oldRequest = $0 }
            }
        }
        while oldRequest == nil { await Task.yield() }
        await state.load(page: 2) { response }
        oldRequest?.resume(throwing: URLError(.timedOut))
        await failedOld.value
        assert(state.errorMessage == nil && state.currentPage == 2)
        await state.load(page: 3) { throw URLError(.notConnectedToInternet) }
        assert(state.errorMessage == "网络未连接，请检查网络后重试" && state.works.first?.id == 2 && state.currentPage == 2 && state.requestedPage == 3)
        await state.load(page: state.requestedPage) { response }
        assert(state.errorMessage == nil && !state.isLoading)
        oldRequest = nil
        let resetOld = Task {
            await state.load(page: 1) {
                try await withCheckedThrowingContinuation { oldRequest = $0 }
            }
        }
        while oldRequest == nil { await Task.yield() }
        state.reset()
        oldRequest?.resume(returning: response)
        await resetOld.value
        assert(state.pagination == nil && state.works.isEmpty && state.currentPage == 1)
        print("Works request race checks passed")
    }
}
#endif
