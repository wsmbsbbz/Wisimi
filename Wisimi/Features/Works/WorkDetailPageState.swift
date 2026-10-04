import Foundation
import Observation

@MainActor
@Observable
final class WorkDetailPageState {
    private(set) var work: WorkDetail?
    private(set) var tracks: [TrackNode] = []
    var currentPath: [TrackNode] = []
    var isPathMenuExpanded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isUpdatingMark = false
    private(set) var markMessage: String?
    private var loadedWorkID: Int?
    private var requestID = UUID()
    private var requestedWorkID: Int?
    private var requestedToken: String?
    private var workGeneration = UUID()
    private var markRevision = 0
    private var loadTask: Task<Void, Never>?
    private let client: ASMRClient
    private let cachedWork: @MainActor (Int) -> DownloadedWork?

    init(client: ASMRClient, cachedWork: @escaping @MainActor (Int) -> DownloadedWork? = { DownloadStore.shared.savedWork(id: $0) }) {
        self.client = client
        self.cachedWork = cachedWork
    }

    func load(workID: Int, token: String?, force: Bool = false) async {
        if requestedWorkID != workID || requestedToken != token {
            requestedWorkID = workID
            requestedToken = token
            workGeneration = UUID()
        }
        let saved = cachedWork(workID)
        if work == nil, let saved { apply(work: saved.work, tracks: saved.tracks, workID: workID) }
        guard force || saved != nil || loadedWorkID != workID || work == nil else { return }
        loadTask?.cancel()
        let id = UUID()
        let revision = markRevision
        requestID = id
        isLoading = true
        errorMessage = nil
        let task = Task {
            defer { if requestID == id { isLoading = false; loadTask = nil } }
            do {
                async let detail = client.fetchWork(id: workID, token: token)
                async let directory = client.fetchTracks(workID: workID)
                let (work, tracks) = try await (detail, directory)
                guard requestID == id, !Task.isCancelled else { return }
                let displayedWork: WorkDetail
                if revision != markRevision, let current = self.work, current.id == workID { displayedWork = current }
                else { displayedWork = work }
                apply(work: displayedWork, tracks: tracks, workID: workID)
            } catch {
                guard requestID == id, !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = error.userFacingMessage
            }
        }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func mark(_ status: ReviewStatus?, token: String) async {
        guard let work, !isUpdatingMark else { return }
        let generation = workGeneration
        isUpdatingMark = true
        markMessage = nil
        defer { isUpdatingMark = false }
        do {
            if let status { try await client.markWork(id: work.id, status: status, token: token) }
            else { try await client.unmarkWork(id: work.id, token: token) }
            let updated = try await client.fetchWork(id: work.id, token: token)
            try Task.checkCancellation()
            guard workGeneration == generation else { return }
            self.work = updated
            markRevision += 1
        } catch is CancellationError {
        } catch {
            if workGeneration == generation { markMessage = error.userFacingMessage }
        }
    }

    private func apply(work: WorkDetail, tracks: [TrackNode], workID: Int) {
        let previousPath = loadedWorkID == workID && self.work != nil ? currentPath.map(\.id) : nil
        self.work = work
        self.tracks = tracks
        currentPath = previousPath.flatMap { tracks.resolvingDirectoryPath(ids: $0) } ?? tracks.defaultDirectoryPath
        if previousPath == nil { isPathMenuExpanded = false }
        loadedWorkID = workID
    }

    #if DEBUG
    func prepareDebugSnapshot(_ saved: DownloadedWork) {
        apply(work: saved.work, tracks: saved.tracks, workID: saved.id)
    }
    #endif
}
