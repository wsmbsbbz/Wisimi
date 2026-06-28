import Foundation

struct ASMRClient {
    private let baseURL = URL(string: "https://api.asmr-200.com/api")!
    private let decoder = JSONDecoder()

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

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    private func postJSON<T: Decodable, Body: Encodable>(_ url: URL, body: Body) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return try decoder.decode(T.self, from: data)
    }
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

private struct PopularRequest: Encodable {
    let keyword = " "
    let page: Int
    let subtitle: Int
    let localSubtitledWorks: [Int] = []
    let withPlaylistStatus: [Int] = []
}

enum ASMRClientError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        "接口返回异常"
    }
}
