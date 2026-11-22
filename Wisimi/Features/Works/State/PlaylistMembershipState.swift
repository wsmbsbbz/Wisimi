import Foundation
import Observation

@MainActor
@Observable
final class PlaylistMembershipState {
    let page = PagedState<PlaylistSummary>()
    private(set) var updatingIDs: Set<String> = []
    private let workID: Int
    private let client: ASMRClient

    var playlists: [PlaylistSummary] { page.items }
    var pagination: WorksPagination? { page.pagination }
    var currentPage: Int { page.currentPage }
    var isLoading: Bool { page.isLoading }
    var errorMessage: String? { page.errorMessage }

    init(workID: Int, client: ASMRClient) {
        self.workID = workID
        self.client = client
    }

    func load(page number: Int, token: String) async {
        await page.load(page: number) { [client, workID] in
            let response = try await client.fetchPlaylistStatus(workID: workID, page: number, token: token)
            return PagedResponse(items: response.playlists, pagination: response.pagination)
        }
    }

    func toggle(_ playlist: PlaylistSummary, token: String) async {
        guard !updatingIDs.contains(playlist.id) else { return }
        let newExist = !playlist.exist
        setExist(newExist, for: playlist.id)
        updatingIDs.insert(playlist.id)
        page.setError(nil)
        defer { updatingIDs.remove(playlist.id) }
        do {
            if newExist {
                try await client.addWorkToPlaylist(playlistID: playlist.id, workID: workID, token: token)
            } else {
                try await client.removeWorkFromPlaylist(playlistID: playlist.id, workID: workID, token: token)
            }
        } catch {
            setExist(!newExist, for: playlist.id)
            if !Task.isCancelled, !(error is CancellationError) { page.setError(error.userFacingMessage) }
        }
    }

    private func setExist(_ exist: Bool, for id: String) {
        page.updateItems { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[index].worksCount = max(playlists[index].worksCount + (exist ? 1 : -1), 0)
            playlists[index].exist = exist
        }
    }
}
