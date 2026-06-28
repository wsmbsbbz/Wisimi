import Foundation

struct ASMRClient {
    private let baseURL = URL(string: "https://api.asmr-200.com/api")!
    private let decoder = JSONDecoder()

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

    func fetchRecommended(page: Int = 1, uuid: String, token: String, filter: WorksFilter = .default) async throws -> WorksResponse {
        try await postJSON(
            baseURL.appending(path: "recommender/recommend-for-user"),
            body: RecommendedRequest(userId: uuid, page: page, subtitle: filter.hasSubtitle ? 1 : 0),
            token: token
        )
    }

    func fetchWork(id: Int) async throws -> WorkDetail {
        try await fetch(baseURL.appending(path: "work/\(id)"))
    }

    func fetchTracks(workID: Int) async throws -> [TrackNode] {
        var components = URLComponents(url: baseURL.appending(path: "tracks/\(workID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: "2")]
        return try await fetch(components.url!)
    }

    func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func fetch<T: Decodable>(_ url: URL, token: String? = nil) async throws -> T {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    private func postJSON<T: Decodable, Body: Encodable>(_ url: URL, body: Body, token: String? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct LoginRequest: Encodable {
    let name: String
    let password: String
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

enum ReviewStatus: String, CaseIterable, Identifiable, Sendable {
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

    var errorDescription: String? {
        switch self {
        case .badResponse: "接口返回异常"
        case .loginRequired: "请先登录"
        case .missingRecommenderUuid: "当前账号缺少推荐标识"
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

        let listenedRating = ReviewFilter(status: .listened, order: .userRating, sort: .ascending)
        assert(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["filter"] == "listened")
        assert(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["order"] == "userRating")
        assert(queryItems(in: client.reviewURL(page: 3, filter: listenedRating))["sort"] == "asc")

        let nsfw = ReviewFilter(order: .nsfw, sort: .descending)
        assert(queryItems(in: client.reviewURL(page: 1, filter: nsfw))["order"] == "nsfw")
        assert(queryItems(in: client.reviewURL(page: 1, filter: nsfw))["sort"] == "desc")
    }

    private static func queryItems(in url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
        })
    }
}
#endif
