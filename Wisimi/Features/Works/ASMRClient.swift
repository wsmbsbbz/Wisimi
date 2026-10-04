import Foundation

struct ASMRClient {
    private let baseURL = URL(string: "https://api.asmr-200.com/api")!
    private let decoder = JSONDecoder()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func login(name: String, password: String) async throws -> AuthResponse {
        try await postJSON(
            baseURL.appending(path: "auth/me"),
            body: LoginRequest(name: name, password: password)
        )
    }

    func fetchWorks(page: Int = 1, filter: WorksFilter = .default) async throws -> WorksResponse {
        var components = URLComponents(url: baseURL.appending(path: "works"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "order", value: filter.order.rawValue),
            URLQueryItem(name: "sort", value: filter.sort.rawValue),
            URLQueryItem(name: "subtitle", value: filter.hasSubtitle ? "1" : "0"),
            URLQueryItem(name: "page", value: String(page))
        ]
        return try await fetch(components.url!)
    }

    func searchWorks(keyword: String, page: Int = 1, filter: WorksFilter = .default) async throws -> WorksResponse {
        let base = baseURL
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/?#"))) ?? keyword
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.percentEncodedPath = base.path + "/search/" + encodedKeyword
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "order", value: filter.order.rawValue),
            URLQueryItem(name: "sort", value: filter.sort.rawValue),
            URLQueryItem(name: "subtitle", value: filter.hasSubtitle ? "1" : "0"),
            URLQueryItem(name: "includeTranslationWorks", value: "true")
        ]
        return try await fetch(components.url!)
    }

    func fetchPopular(page: Int = 1, filter: WorksFilter = .default) async throws -> WorksResponse {
        try await postJSON(
            baseURL.appending(path: "recommender/popular"),
            body: PopularRequest(page: page, subtitle: filter.hasSubtitle ? 1 : 0)
        )
    }

    func fetchFavorites(page: Int = 1, token: String, filter: ReviewFilter = .default) async throws -> WorksResponse {
        try await fetch(reviewURL(page: page, filter: filter), token: token)
    }

    func fetchPlaylists(page: Int = 1, pageSize: Int = 20, token: String) async throws -> PlaylistsResponse {
        try await fetch(playlistsURL(page: page, pageSize: pageSize), token: token)
    }

    func fetchPlaylistWorks(id: String, page: Int = 1, pageSize: Int = 12, token: String) async throws -> WorksResponse {
        try await fetch(playlistWorksURL(id: id, page: page, pageSize: pageSize), token: token)
    }

    func fetchPlaylistStatus(workID: Int, page: Int = 1, pageSize: Int = 12, token: String) async throws -> PlaylistsResponse {
        try await fetch(playlistStatusURL(workID: workID, page: page, pageSize: pageSize), token: token)
    }

    func createPlaylist(name: String, privacy: Int, description: String, locale: String = "zh-CN", token: String) async throws -> PlaylistSummary {
        try await postJSON(
            baseURL.appending(path: "playlist/create-playlist"),
            body: PlaylistCreateRequest(name: name, privacy: privacy, locale: locale, description: description, works: []),
            token: token
        )
    }

    func updatePlaylistMetadata(id: String, name: String, privacy: Int, description: String, token: String) async throws -> PlaylistSummary {
        try await postJSON(
            baseURL.appending(path: "playlist/edit-playlist-metadata"),
            body: PlaylistMetadataEditRequest(id: id, data: PlaylistMetadata(name: name, privacy: privacy, description: description)),
            token: token
        )
    }

    func deletePlaylist(id: String, token: String) async throws -> String {
        let response: PlaylistDeleteResponse = try await postJSON(
            baseURL.appending(path: "playlist/delete-playlist"),
            body: PlaylistDeleteRequest(id: id),
            token: token
        )
        return response.id
    }

    func addWorkToPlaylist(playlistID: String, workID: Int, token: String) async throws {
        let _: PlaylistMutationResponse = try await postJSON(
            baseURL.appending(path: "playlist/add-works-to-playlist"),
            body: PlaylistWorksRequest(id: playlistID, works: [workID]),
            token: token
        )
    }

    func removeWorkFromPlaylist(playlistID: String, workID: Int, token: String) async throws {
        let _: PlaylistMutationResponse = try await postJSON(
            baseURL.appending(path: "playlist/remove-works-from-playlist"),
            body: PlaylistWorksRequest(id: playlistID, works: [workID]),
            token: token
        )
    }

    func markWork(id: Int, status: ReviewStatus = .marked, token: String) async throws {
        try await sendJSON(
            baseURL.appending(path: "review"),
            method: "PUT",
            body: MarkWorkRequest(workID: id, progress: status.rawValue),
            token: token
        )
    }

    func unmarkWork(id: Int, token: String) async throws {
        var components = URLComponents(url: baseURL.appending(path: "review"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "work_id", value: String(id))]
        try await send(components.url!, method: "DELETE", token: token)
    }

    fileprivate func reviewURL(page: Int, filter: ReviewFilter) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "review"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "filter", value: filter.status.rawValue),
            URLQueryItem(name: "order", value: filter.order.rawValue),
            URLQueryItem(name: "sort", value: filter.sort.rawValue)
        ]
        return components.url!
    }

    fileprivate func playlistsURL(page: Int, pageSize: Int) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "playlist/get-playlists"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "filterBy", value: "all")
        ]
        return components.url!
    }

    fileprivate func playlistWorksURL(id: String, page: Int, pageSize: Int) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "playlist/get-playlist-works"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize))
        ]
        return components.url!
    }

    fileprivate func playlistStatusURL(workID: Int, page: Int, pageSize: Int) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "playlist/get-work-exist-status-in-my-playlists"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "workID", value: String(workID)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "version", value: "2")
        ]
        return components.url!
    }

    func fetchRecommended(page: Int = 1, uuid: String, token: String, filter: WorksFilter = .default) async throws -> WorksResponse {
        try await postJSON(
            baseURL.appending(path: "recommender/recommend-for-user"),
            body: RecommendedRequest(userId: uuid, page: page, subtitle: filter.hasSubtitle ? 1 : 0),
            token: token
        )
    }

    func fetchWork(id: Int, token: String? = nil) async throws -> WorkDetail {
        try await fetch(baseURL.appending(path: "work/\(id)"), token: token)
    }

    func fetchTracks(workID: Int) async throws -> [TrackNode] {
        var components = URLComponents(url: baseURL.appending(path: "tracks/\(workID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: "2")]
        return try await fetch(components.url!)
    }

    func fetchText(_ url: URL) async throws -> String {
        if url.isFileURL { return try String(contentsOf: url, encoding: .utf8) }
        let data = try await data(for: request(url: url))
        return String(decoding: data, as: UTF8.self)
    }

    private func fetch<T: Decodable>(_ url: URL, token: String? = nil) async throws -> T {
        let data = try await data(for: request(url: url, token: token))
        return try decoder.decode(T.self, from: data)
    }

    private func postJSON<T: Decodable, Body: Encodable>(_ url: URL, body: Body, token: String? = nil) async throws -> T {
        let data = try await data(for: request(url: url, method: "POST", body: body, token: token))
        return try decoder.decode(T.self, from: data)
    }

    private func send(_ url: URL, method: String, token: String? = nil) async throws {
        _ = try await data(for: request(url: url, method: method, token: token))
    }

    private func sendJSON<Body: Encodable>(_ url: URL, method: String, body: Body, token: String? = nil) async throws {
        _ = try await data(for: request(url: url, method: method, body: body, token: token))
    }

    private func request(url: URL, method: String = "GET", token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func request<Body: Encodable>(url: URL, method: String, body: Body, token: String? = nil) throws -> URLRequest {
        var request = request(url: url, method: method, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return data
    }
}

private struct LoginRequest: Encodable {
    let name: String
    let password: String
}

private struct MarkWorkRequest: Encodable {
    let workID: Int
    let progress: String

    private enum CodingKeys: String, CodingKey {
        case workID = "work_id"
        case rating
        case reviewText = "review_text"
        case progress
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workID, forKey: .workID)
        try container.encodeNil(forKey: .rating)
        try container.encodeNil(forKey: .reviewText)
        try container.encode(progress, forKey: .progress)
    }
}

private struct PlaylistWorksRequest: Encodable {
    let id: String
    let works: [Int]
}

private struct PlaylistCreateRequest: Encodable {
    let name: String
    let privacy: Int
    let locale: String
    let description: String
    let works: [Int]
}

private struct PlaylistMetadataEditRequest: Encodable {
    let id: String
    let data: PlaylistMetadata
}

private struct PlaylistMetadata: Encodable {
    let name: String
    let privacy: Int
    let description: String
}

private struct PlaylistDeleteRequest: Encodable {
    let id: String
}

private struct PlaylistDeleteResponse: Decodable {
    let id: String
}

private struct PlaylistMutationResponse: Decodable {
    let id: String
    let rowCount: Int
}

struct WorksFilter: Equatable, Sendable {
    var hasSubtitle = false
    var order: WorksOrder = .createDate
    var sort: WorksSort = .descending

    nonisolated static let `default` = WorksFilter()
}

enum WorksOrder: String, CaseIterable, Identifiable, Sendable {
    case createDate = "create_date"
    case release
    case dlCount = "dl_count"
    case price
    case rateAverage = "rate_average_2dp"
    case reviewCount = "review_count"
    case id
    case rating
    case nsfw
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .createDate: "收录时间"
        case .release: "发售日期"
        case .dlCount: "销量"
        case .price: "价格"
        case .rateAverage: "评价"
        case .reviewCount: "评论数"
        case .id: "RJ号"
        case .rating: "我的评价"
        case .nsfw: "全年龄"
        case .random: "随机"
        }
    }
}

enum WorksSort: String, CaseIterable, Identifiable, Sendable {
    case descending = "desc"
    case ascending = "asc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .descending: "降序"
        case .ascending: "升序"
        }
    }
}

struct ReviewFilter: Equatable, Sendable {
    var status: ReviewStatus = .marked
    var order: ReviewOrder = .updatedAt
    var sort: ReviewSort = .descending

    nonisolated static let `default` = ReviewFilter()
}

enum ReviewStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case marked
    case listening
    case listened
    case replay
    case postponed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .marked: "想听"
        case .listening: "在听"
        case .listened: "听过"
        case .replay: "重听"
        case .postponed: "搁置"
        }
    }
}

enum ReviewOrder: String, CaseIterable, Identifiable, Sendable {
    case updatedAt = "updated_at"
    case userRating
    case release
    case reviewCount = "review_count"
    case dlCount = "dl_count"
    case nsfw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedAt: "标记时间"
        case .userRating: "评价"
        case .release: "发布时间"
        case .reviewCount: "评论数量"
        case .dlCount: "售出数量"
        case .nsfw: "新作分级"
        }
    }
}

enum ReviewSort: String, CaseIterable, Identifiable, Sendable {
    case descending = "desc"
    case ascending = "asc"

    var id: String { rawValue }

    func title(for order: ReviewOrder) -> String {
        guard order == .nsfw else {
            return switch self {
            case .descending: "降序"
            case .ascending: "升序"
            }
        }

        return switch self {
        case .descending: "18禁新作"
        case .ascending: "全年龄新作"
        }
    }
}

private struct PopularRequest: Encodable {
    let keyword = " "
    let page: Int
    let subtitle: Int
    let localSubtitledWorks: [Int] = []
    let withPlaylistStatus: [Int] = []
}

private struct RecommendedRequest: Encodable {
    let keyword = " "
    let userId: String
    let page: Int
    let subtitle: Int
    let localSubtitledWorks: [Int] = []
    let withPlaylistStatus: [Int] = []
}

enum ASMRClientError: LocalizedError {
    case badResponse
    case loginRequired
    case missingRecommenderUuid
    case noPlaylists

    var errorDescription: String? {
        switch self {
        case .badResponse: "接口返回异常"
        case .loginRequired: "请先登录"
        case .missingRecommenderUuid: "当前账号缺少推荐标识"
        case .noPlaylists: "暂无播放列表"
        }
    }
}

#if DEBUG
enum ASMRClientURLSelfCheck {
    static func run() {
        let client = ASMRClient()
        assert(queryItems(in: client.reviewURL(page: 1, filter: .default)) == [
            "page": "1",
            "filter": "marked",
            "order": "updated_at",
            "sort": "desc"
        ])
        assert(queryItems(in: client.playlistsURL(page: 1, pageSize: 20)) == [
            "page": "1",
            "pageSize": "20",
            "filterBy": "all"
        ])
        assert(queryItems(in: client.playlistWorksURL(id: "playlist-id", page: 2, pageSize: 12)) == [
            "id": "playlist-id",
            "page": "2",
            "pageSize": "12"
        ])
        assert(queryItems(in: client.playlistStatusURL(workID: 1172778, page: 1, pageSize: 12)) == [
            "workID": "1172778",
            "page": "1",
            "pageSize": "12",
            "version": "2"
        ])

        let listenedRating = ReviewFilter(status: .listened, order: .userRating, sort: .ascending)
        assert(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["filter"] == "listened")
        assert(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["order"] == "userRating")
        assert(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["sort"] == "asc")

        let nsfw = ReviewFilter(order: .nsfw, sort: .descending)
        assert(queryItems(in: client.reviewURL(page: 1, filter: nsfw))["order"] == "nsfw")
        assert(queryItems(in: client.reviewURL(page: 1, filter: nsfw))["sort"] == "desc")

        let markData = try! JSONEncoder().encode(MarkWorkRequest(workID: 1542155, progress: "marked"))
        let markJSON = try! JSONSerialization.jsonObject(with: markData) as! [String: Any]
        assert(markJSON["work_id"] as? Int == 1542155)
        assert(markJSON["progress"] as? String == "marked")
        assert(markJSON["rating"] is NSNull)
        assert(markJSON["review_text"] is NSNull)

        let playlistData = try! JSONEncoder().encode(PlaylistWorksRequest(id: "playlist-id", works: [1172778]))
        let playlistJSON = try! JSONSerialization.jsonObject(with: playlistData) as! [String: Any]
        assert(playlistJSON["id"] as? String == "playlist-id")
        assert(playlistJSON["works"] as? [Int] == [1172778])
    }

    private static func queryItems(in url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
        })
    }
}
#endif
