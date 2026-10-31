import Foundation
import Observation

@MainActor
@Observable
final class PlaylistMembershipState {
    private(set) var playlists: [PlaylistSummary] = []
    private(set) var pagination: WorksPagination?
    private(set) var currentPage = 1
    private(set) var isLoading = false
    private(set) var updatingIDs: Set<String> = []
    private(set) var errorMessage: String?
    private var requestID = UUID()
    private let workID: Int
    private let client: ASMRClient

    init(workID: Int, client: ASMRClient) {
        self.workID = workID
        self.client = client
    }

    func load(page: Int, token: String) async {
        let id = UUID()
        requestID = id
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }
        do {
            let response = try await client.fetchPlaylistStatus(workID: workID, page: page, token: token)
            guard requestID == id, !Task.isCancelled else { return }
            playlists = response.playlists
            pagination = response.pagination
            currentPage = page
        } catch {
            guard requestID == id, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.userFacingMessage
        }
    }

    func toggle(_ playlist: PlaylistSummary, token: String) async {
        guard !updatingIDs.contains(playlist.id) else { return }
        let newExist = !playlist.exist
        setExist(newExist, for: playlist.id)
        updatingIDs.insert(playlist.id)
        errorMessage = nil
        defer { updatingIDs.remove(playlist.id) }
        do {
            if newExist {
                try await client.addWorkToPlaylist(playlistID: playlist.id, workID: workID, token: token)
            } else {
                try await client.removeWorkFromPlaylist(playlistID: playlist.id, workID: workID, token: token)
            }
        } catch {
            setExist(!newExist, for: playlist.id)
            if !Task.isCancelled, !(error is CancellationError) { errorMessage = error.userFacingMessage }
        }
    }

    private func setExist(_ exist: Bool, for id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].worksCount = max(playlists[index].worksCount + (exist ? 1 : -1), 0)
        playlists[index].exist = exist
    }
}
