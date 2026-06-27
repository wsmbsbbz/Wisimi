import Foundation

struct WorksResponse: Decodable {
    let works: [WorkSummary]
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
    var voiceActorsText: String { vas.map(\.name).joined(separator: " / ") }
    var visibleVoiceActors: [String] { vas.prefix(2).map(\.name) }
    var hiddenVoiceActorCount: Int { max(vas.count - visibleVoiceActors.count, 0) }
    var visibleTags: [String] { tags.prefix(5).map(\.name) }
    var hiddenTagCount: Int { max(tags.count - visibleTags.count, 0) }

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
    let tags: [NameItem]
    let vas: [NameItem]

    var mainCoverURL: URL? { mainCover.flatMap(URL.init(string:)) }
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
        case tags
        case vas
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

    var id: String { hash ?? "\(type)-\(title)" }
    var durationText: String { duration.formattedDuration }
}

extension Array where Element == TrackNode {
    var audioTracks: [TrackNode] {
        flatMap { node in
            var result = node.type == "audio" ? [node] : []
            result += node.children?.audioTracks ?? []
            return result
        }
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
        let list = #"{"works":[{"id":1,"title":"Work","name":"Circle","duration":90,"rate_average_2dp":4.8,"has_subtitle":true,"thumbnailCoverUrl":"https://example.com/a.jpg","tags":[{"id":1,"name":"耳かき"}],"vas":[{"id":"va","name":"声优"}]}]}"#
        let detail = #"{"id":1,"title":"Work","name":"Circle","duration":90,"dl_count":2,"rate_average_2dp":4.8,"has_subtitle":true,"mainCoverUrl":"https://example.com/a.jpg","tags":[{"id":1,"name":"耳かき"}],"vas":[{"id":"va","name":"声优"}]}"#
        let tracks = #"[{"type":"folder","title":"root","children":[{"type":"audio","title":"01.mp3","hash":"1/1","duration":12.4}]}]"#

        assert((try? decoder.decode(WorksResponse.self, from: Data(list.utf8)))?.works.count == 1)
        assert((try? decoder.decode(WorkDetail.self, from: Data(detail.utf8)))?.tags.first?.name == "耳かき")
        assert((try? decoder.decode([TrackNode].self, from: Data(tracks.utf8)))?.audioTracks.count == 1)
    }
}
#endif
