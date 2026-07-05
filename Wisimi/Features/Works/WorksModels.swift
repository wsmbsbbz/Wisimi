import Foundation

struct WorksResponse: Decodable {
    let works: [WorkSummary]
    let pagination: WorksPagination
}

struct WorksPagination: Decodable {
    let currentPage: Int
    let pageSize: Int
    let totalCount: Int

    private enum CodingKeys: String, CodingKey {
        case currentPage
        case page
        case pageSize
        case totalCount
    }

    init(currentPage: Int, pageSize: Int, totalCount: Int) {
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.totalCount = totalCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = try container.decodeIfPresent(Int.self, forKey: .currentPage)
            ?? container.decode(Int.self, forKey: .page)
        pageSize = try container.decode(Int.self, forKey: .pageSize)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
    }

    var totalPages: Int {
        guard pageSize > 0 else { return 1 }
        return max(Int(ceil(Double(totalCount) / Double(pageSize))), 1)
    }
}

struct PlaylistsResponse: Decodable {
    let playlists: [PlaylistSummary]
    let pagination: WorksPagination
}

struct PlaylistSummary: Decodable, Identifiable, Equatable {
    let id: String
    var name: String
    let privacy: Int
    let description: String
    var worksCount: Int
    var exist: Bool

    var countText: String { "\(worksCount) 个作品" }
    var displayName: String {
        switch name {
        case "__SYS_PLAYLIST_LIKED": "我喜欢的"
        case "__SYS_PLAYLIST_MARKED": "我标记的"
        default: name
        }
    }
    var isSystemPreserved: Bool { name.hasPrefix("__SYS_PLAYLIST_") }
    var systemImage: String? { isSystemPreserved ? "lock.fill" : nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case privacy
        case description
        case worksCount = "works_count"
        case exist
    }

    init(id: String, name: String, privacy: Int, description: String, worksCount: Int, exist: Bool = false) {
        self.id = id
        self.name = name
        self.privacy = privacy
        self.description = description
        self.worksCount = worksCount
        self.exist = exist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        privacy = try container.decode(Int.self, forKey: .privacy)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        worksCount = try container.decodeIfPresent(Int.self, forKey: .worksCount) ?? 0
        exist = try container.decodeIfPresent(Bool.self, forKey: .exist) ?? false
    }
}

struct WorkSummary: Decodable, Identifiable {
    let id: Int
    let title: String
    let name: String
    let duration: Double?
    let rateAverage: Double?
    let hasSubtitle: Bool
    let thumbnailCover: String?
    let tags: [NameItem]
    let vas: [NameItem]

    var thumbnailCoverURL: URL? { thumbnailCover.flatMap(URL.init(string:)) }
    var ratingText: String { rateAverage.map { String(format: "%.1f", $0) } ?? "-" }
    var durationText: String { duration.formattedDuration }
    var visibleVoiceActors: [String] { vas.prefix(2).map(\.name) }
    var hiddenVoiceActorCount: Int { max(vas.count - visibleVoiceActors.count, 0) }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case duration
        case rateAverage = "rate_average_2dp"
        case hasSubtitle = "has_subtitle"
        case thumbnailCover = "thumbnailCoverUrl"
        case tags
        case vas
    }
}

struct WorkDetail: Decodable {
    let id: Int
    let title: String
    let name: String
    let duration: Double?
    let dlCount: Int
    let rateAverage: Double?
    let hasSubtitle: Bool
    let mainCover: String?
    let progress: ReviewStatus?
    let tags: [NameItem]
    let vas: [NameItem]

    var mainCoverURL: URL? { mainCover.flatMap(URL.init(string:)) }
    var rjCode: String { "RJ\(id)" }
    var ratingText: String { rateAverage.map { String(format: "%.1f", $0) } ?? "-" }
    var durationText: String { duration.formattedDuration }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case duration
        case dlCount = "dl_count"
        case rateAverage = "rate_average_2dp"
        case hasSubtitle = "has_subtitle"
        case mainCover = "mainCoverUrl"
        case progress
        case tags
        case vas
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        name = try container.decode(String.self, forKey: .name)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        dlCount = try container.decode(Int.self, forKey: .dlCount)
        rateAverage = try container.decodeIfPresent(Double.self, forKey: .rateAverage)
        hasSubtitle = try container.decode(Bool.self, forKey: .hasSubtitle)
        mainCover = try container.decodeIfPresent(String.self, forKey: .mainCover)
        progress = try container.decodeIfPresent(String.self, forKey: .progress).flatMap(ReviewStatus.init(rawValue:))
        tags = try container.decode([NameItem].self, forKey: .tags)
        vas = try container.decode([NameItem].self, forKey: .vas)
    }
}

struct NameItem: Decodable, Identifiable {
    let id: FlexibleID
    let name: String
}

struct TrackNode: Decodable, Identifiable {
    let type: String
    let title: String
    let hash: String?
    let duration: Double?
    let children: [TrackNode]?
    let mediaStreamUrl: String?
    let mediaDownloadUrl: String?
    let size: Int?

    var id: String { hash ?? "\(type)-\(title)" }
    var isAudio: Bool { type == "audio" }
    var isFolder: Bool { type == "folder" }
    var isSubtitle: Bool { title.lowercased().hasSuffix(".vtt") || title.lowercased().hasSuffix(".lrc") }
    var isImage: Bool {
        [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { title.lowercased().hasSuffix($0) }
    }
    var audioURL: URL? {
        (mediaStreamUrl ?? mediaDownloadUrl).flatMap(URL.init(string:))
    }
    var imagePreviewURL: URL? {
        guard isImage else { return nil }
        return (mediaStreamUrl ?? mediaDownloadUrl).flatMap(URL.init(string:))
    }
    var downloadURL: URL? { mediaDownloadUrl.flatMap(URL.init(string:)) }
    var durationText: String { duration.formattedDuration }
}

extension Array where Element == TrackNode {
    var audioTracks: [TrackNode] {
        flatMap { node in
            var result = node.isAudio ? [node] : []
            result += node.children?.audioTracks ?? []
            return result
        }
    }

    var defaultDirectoryPath: [TrackNode] {
        count == 1 && self[0].isFolder ? [self[0]] : []
    }
}

struct FlexibleID: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}

#if DEBUG
enum DecodeSelfCheck {
    static func run() {
        let decoder = JSONDecoder()
        let list = #"{"works":[{"id":1,"title":"Work","name":"Circle","duration":90,"rate_average_2dp":4.8,"has_subtitle":true,"thumbnailCoverUrl":"https://example.com/a.jpg","tags":[{"id":1,"name":"耳かき"}],"vas":[{"id":"va","name":"声优"}]}],"pagination":{"currentPage":1,"pageSize":20,"totalCount":42}}"#
        let playlistWorks = #"{"works":[{"id":1172778,"title":"Work","name":"Circle","duration":11539,"rate_average_2dp":4.85,"has_subtitle":false,"thumbnailCoverUrl":"https://example.com/cover.jpg","tags":[{"id":68,"name":"淫语"}],"vas":[{"id":"va","name":"天知遥"}]}],"pagination":{"page":1,"pageSize":12,"totalCount":1}}"#
        let playlists = #"{"playlists":[{"id":"playlist-id","name":"Playlist","privacy":0,"description":"probe","works_count":1,"exist":true}],"pagination":{"page":1,"pageSize":12,"totalCount":1}}"#
        let detail = #"{"id":1,"title":"Work","name":"Circle","duration":90,"dl_count":2,"rate_average_2dp":4.8,"has_subtitle":true,"mainCoverUrl":"https://example.com/a.jpg","progress":"marked","tags":[{"id":1,"name":"耳かき"}],"vas":[{"id":"va","name":"声优"}]}"#
        let tracks = #"[{"type":"folder","title":"root","children":[{"type":"audio","title":"01.mp3","hash":"1/1","duration":12.4,"mediaDownloadUrl":"https://example.com/01.mp3"},{"type":"text","title":"01.vtt","mediaDownloadUrl":"https://example.com/01.vtt"},{"type":"image","title":"cover.jpg","mediaDownloadUrl":"https://example.com/cover.jpg"}]}]"#

        let worksResponse = try? decoder.decode(WorksResponse.self, from: Data(list.utf8))
        assert(worksResponse?.works.count == 1)
        assert(worksResponse?.pagination.totalPages == 3)
        let playlistWorksResponse = try? decoder.decode(WorksResponse.self, from: Data(playlistWorks.utf8))
        assert(playlistWorksResponse?.pagination.currentPage == 1)
        assert(playlistWorksResponse?.works.first?.id == 1172778)
        let playlistsResponse = try? decoder.decode(PlaylistsResponse.self, from: Data(playlists.utf8))
        assert(playlistsResponse?.playlists.first?.exist == true)
        assert(playlistsResponse?.playlists.first?.worksCount == 1)
        assert(PlaylistSummary(id: "liked", name: "__SYS_PLAYLIST_LIKED", privacy: 0, description: "", worksCount: 0).displayName == "我喜欢的")
        assert(PlaylistSummary(id: "marked", name: "__SYS_PLAYLIST_MARKED", privacy: 0, description: "", worksCount: 0).displayName == "我标记的")
        assert(PlaylistSummary(id: "custom", name: "自定义", privacy: 0, description: "", worksCount: 0).isSystemPreserved == false)
        let decodedDetail = try? decoder.decode(WorkDetail.self, from: Data(detail.utf8))
        assert(decodedDetail?.tags.first?.name == "耳かき")
        assert(decodedDetail?.progress == .marked)
        let decodedTracks = try? decoder.decode([TrackNode].self, from: Data(tracks.utf8))
        assert(decodedTracks?.audioTracks.count == 1)
        assert(decodedTracks?.defaultDirectoryPath.first?.children?.first?.isAudio == true)
        assert(decodedTracks?.defaultDirectoryPath.first?.children?[1].isSubtitle == true)
        assert(decodedTracks?.defaultDirectoryPath.first?.children?[2].isImage == true)
        assert(decodedTracks?.defaultDirectoryPath.first?.children?[2].imagePreviewURL?.absoluteString == "https://example.com/cover.jpg")
    }
}
#endif
