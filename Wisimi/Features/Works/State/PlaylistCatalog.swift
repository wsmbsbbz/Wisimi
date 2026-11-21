import Foundation
import Observation

@MainActor
@Observable
final class PlaylistCatalog {
    private(set) var playlists: [PlaylistSummary] = []
    var selectedID: String?
    private let client: ASMRClient
    private var generation = UUID()

    init(client: ASMRClient) { self.client = client }

    var selectedPlaylist: PlaylistSummary? {
        playlists.first { $0.id == selectedID }
    }

    func reset() {
        generation = UUID()
        playlists = []
        selectedID = nil
    }

    func ensureSelection(token: String) async throws -> String {
        let id = generation
        if let selectedPlaylist { return selectedPlaylist.id }
        let response = try await client.fetchPlaylists(token: token)
        try checkActive(id)
        playlists = response.playlists
        guard let first = playlists.first else { throw ASMRClientError.noPlaylists }
        selectedID = first.id
        return first.id
    }

    func save(id: String?, name: String, privacy: Int, description: String, token: String) async throws -> PlaylistSummary {
        let generation = generation
        let playlist: PlaylistSummary
        if let id {
            playlist = try await client.updatePlaylistMetadata(id: id, name: name, privacy: privacy, description: description, token: token)
        } else {
            playlist = try await client.createPlaylist(name: name, privacy: privacy, description: description, token: token)
        }
        try checkActive(generation)
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[index] = playlist }
        else { playlists.append(playlist) }
        return playlist
    }

    func delete(id: String, token: String) async throws {
        let generation = generation
        let deletedID = try await client.deletePlaylist(id: id, token: token)
        try checkActive(generation)
        playlists.removeAll { $0.id == deletedID }
        if selectedID == deletedID { selectedID = playlists.first?.id }
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == generation else { throw CancellationError() }
    }
}
