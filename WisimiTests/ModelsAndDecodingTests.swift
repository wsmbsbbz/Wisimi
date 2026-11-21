import Foundation
import Testing
@testable import Wisimi

@Suite("Models and Decoding")
@MainActor
struct ModelsAndDecodingTests {
    @Test func decodeModels() throws {
        let decoder = JSONDecoder()
        let list = #"{"works":[{"id":1,"title":"Work","name":"Circle","duration":90,"rate_average_2dp":4.8,"has_subtitle":true,"thumbnailCoverUrl":"https://example.com/a.jpg","tags":[{"id":1,"name":"耳かき"}],"vas":[{"id":"va","name":"声优"}]}],"pagination":{"currentPage":1,"pageSize":20,"totalCount":42}}"#
        let playlistWorks = #"{"works":[{"id":1172778,"title":"Work","name":"Circle","duration":11539,"rate_average_2dp":4.85,"has_subtitle":false,"thumbnailCoverUrl":"https://example.com/cover.jpg","tags":[{"id":68,"name":"淫语"}],"vas":[{"id":"va","name":"天知遥"}]}],"pagination":{"page":1,"pageSize":12,"totalCount":1}}"#
        let playlists = #"{"playlists":[{"id":"playlist-id","name":"Playlist","privacy":0,"description":"probe","works_count":1,"exist":true}],"pagination":{"page":1,"pageSize":12,"totalCount":1}}"#
        let detail = #"{"id":1,"title":"Work","name":"Circle","duration":90,"dl_count":2,"rate_average_2dp":4.8,"has_subtitle":true,"mainCoverUrl":"https://example.com/a.jpg","progress":"marked","tags":[{"id":1,"name":"耳かき"}],"vas":[{"id":"va","name":"声优"}]}"#
        let tracks = #"[{"type":"folder","title":"root","children":[{"type":"audio","title":"01.mp3","hash":"1/1","duration":12.4,"mediaDownloadUrl":"https://example.com/01.mp3"},{"type":"text","title":"01.vtt","mediaDownloadUrl":"https://example.com/01.vtt"},{"type":"image","title":"cover.jpg","mediaDownloadUrl":"https://example.com/cover.jpg"}]}]"#

        let worksResponse = try decoder.decode(WorksResponse.self, from: Data(list.utf8))
        #expect(worksResponse.works.count == 1)
        #expect(worksResponse.pagination.totalPages == 3)

        let playlistWorksResponse = try decoder.decode(WorksResponse.self, from: Data(playlistWorks.utf8))
        #expect(playlistWorksResponse.pagination.currentPage == 1)
        #expect(playlistWorksResponse.works.first?.id == 1172778)

        let playlistsResponse = try decoder.decode(PlaylistsResponse.self, from: Data(playlists.utf8))
        #expect(playlistsResponse.playlists.first?.exist == true)
        #expect(playlistsResponse.playlists.first?.worksCount == 1)
        #expect(PlaylistSummary(id: "liked", name: "__SYS_PLAYLIST_LIKED", privacy: 0, description: "", worksCount: 0).displayName == "我喜欢的")
        #expect(PlaylistSummary(id: "marked", name: "__SYS_PLAYLIST_MARKED", privacy: 0, description: "", worksCount: 0).displayName == "我标记的")
        #expect(PlaylistSummary(id: "custom", name: "自定义", privacy: 0, description: "", worksCount: 0).isSystemPreserved == false)

        let decodedDetail = try decoder.decode(WorkDetail.self, from: Data(detail.utf8))
        #expect(decodedDetail.tags.first?.name == "耳かき")
        #expect(decodedDetail.progress == .marked)

        let decodedTracks = try decoder.decode([TrackNode].self, from: Data(tracks.utf8))
        #expect(decodedTracks.audioTracks.count == 1)
        #expect(decodedTracks.defaultDirectoryPath.first?.children?.first?.isAudio == true)
        #expect(decodedTracks.defaultDirectoryPath.first?.children?[1].isSubtitle == true)
        #expect(decodedTracks.defaultDirectoryPath.first?.children?[2].isImage == true)
        #expect(decodedTracks.defaultDirectoryPath.first?.children?[2].imagePreviewURL?.absoluteString == "https://example.com/cover.jpg")
    }

    @Test func videoTracks() throws {
        let json = #"[{"type":"audio","title":"01.mp3","hash":"a","mediaStreamUrl":"https://example.com/a.mp3"},{"type":"other","title":"02.MP4","hash":"v","mediaDownloadUrl":"https://example.com/v.mp4"},{"type":"video","title":"03.movie","hash":"v2","mediaStreamUrl":"https://example.com/stream","mediaDownloadUrl":"https://example.com/download"},{"type":"audio","title":"04.mp4","hash":"v3","mediaStreamUrl":"https://example.com/v3.mp4"},{"type":"text","title":"02.vtt","hash":"s","mediaDownloadUrl":"https://example.com/02.vtt"},{"type":"image","title":"cover.jpg","hash":"i","mediaDownloadUrl":"https://example.com/cover.jpg"},{"type":"video","title":"missing.mp4","hash":"missing"},{"type":"folder","title":"folder.mp4","hash":"folder"}]"#
        let tracks = try JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))
        #expect(tracks.playableTracks.map(\.id) == ["a", "v", "v2", "v3"])
        #expect(tracks[1].isVideo && tracks[1].playbackURL?.absoluteString == "https://example.com/v.mp4")
        #expect(tracks[2].isVideo && tracks[2].playbackURL?.absoluteString == "https://example.com/stream")
        #expect(tracks[3].isVideo && !tracks[3].isAudio)
        #expect(tracks[4].playbackURL == nil && tracks[5].imagePreviewURL != nil)
        #expect(tracks[6].isVideo && tracks[6].playbackURL == nil)
        #expect(!tracks[7].isVideo && !tracks[7].isPlayable)
    }

    @Test func authResponseDecoding() throws {
        let json = #"{"token":"abc","user":{"name":"demo","loggedIn":true,"recommenderUuid":"uuid"}}"#
        let auth = try JSONDecoder().decode(AuthResponse.self, from: Data(json.utf8))
        #expect(auth.token == "abc")
        #expect(auth.user?.recommenderUuid == "uuid")
    }

    @Test func asmrClientURLsAndRequests() throws {
        func queryItems(in url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
                ($0.name, $0.value ?? "")
            })
        }

        let client = ASMRClient()
        #expect(queryItems(in: client.reviewURL(page: 1, filter: .default)) == [
            "page": "1", "filter": "marked", "order": "updated_at", "sort": "desc"
        ])
        #expect(queryItems(in: client.playlistsURL(page: 1, pageSize: 20)) == [
            "page": "1", "pageSize": "20", "filterBy": "all"
        ])
        #expect(queryItems(in: client.playlistWorksURL(id: "playlist-id", page: 2, pageSize: 12)) == [
            "id": "playlist-id", "page": "2", "pageSize": "12"
        ])
        #expect(queryItems(in: client.playlistStatusURL(workID: 1172778, page: 1, pageSize: 12)) == [
            "workID": "1172778", "page": "1", "pageSize": "12", "version": "2"
        ])

        let listenedRating = ReviewFilter(status: .listened, order: .userRating, sort: .ascending)
        #expect(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["filter"] == "listened")
        #expect(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["order"] == "userRating")
        #expect(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["sort"] == "asc")

        let nsfw = ReviewFilter(order: .nsfw, sort: .descending)
        #expect(queryItems(in: client.reviewURL(page: 1, filter: nsfw))["order"] == "nsfw")
        #expect(queryItems(in: client.reviewURL(page: 1, filter: nsfw))["sort"] == "desc")

        let markData = try JSONEncoder().encode(MarkWorkRequest(workID: 1542155, progress: "marked"))
        let markJSON = try #require(try JSONSerialization.jsonObject(with: markData) as? [String: Any])
        #expect(markJSON["work_id"] as? Int == 1542155)
        #expect(markJSON["progress"] as? String == "marked")
        #expect(markJSON["rating"] is NSNull)
        #expect(markJSON["review_text"] is NSNull)

        let playlistData = try JSONEncoder().encode(PlaylistWorksRequest(id: "playlist-id", works: [1172778]))
        let playlistJSON = try #require(try JSONSerialization.jsonObject(with: playlistData) as? [String: Any])
        #expect(playlistJSON["id"] as? String == "playlist-id")
        #expect(playlistJSON["works"] as? [Int] == [1172778])
    }

    @Test func worksFilterContextAndNavigation() {
        #expect(WorksFilterContext.resolve(isSearchActive: true, mode: .favorites) == .works)
        #expect(WorksFilterContext.resolve(isSearchActive: true, mode: .playlists) == .works)
        #expect(WorksFilterContext.resolve(isSearchActive: false, mode: .favorites) == .favorites)
        #expect(WorksFilterContext.resolve(isSearchActive: false, mode: .playlists) == .playlists)
        #expect(WorksFilterContext.resolve(isSearchActive: false, mode: .latest) == .works)
        #expect(WorksFilterContext.resolve(isSearchActive: false, mode: .popular) == .works)
        #expect(WorksFilterContext.resolve(isSearchActive: false, mode: .recommended) == .works)

        let online = WorkReference.asmrOne(1)
        let local = WorkReference.local(UUID())
        #expect(WorksRoute.replacingPlayer(withDetail: online, in: [.player]) == [.detail(online)])
        #expect(WorksRoute.replacingPlayer(withDetail: online, in: [.detail(online), .player]) == [.detail(online)])
        #expect(WorksRoute.replacingPlayer(withDetail: local, in: [.detail(online), .player]) == [.detail(online), .detail(local)])
    }
}
