import Foundation

struct ASMRClient {
    private let baseURL = URL(string: "https://api.asmr-200.com/api")!
    private let decoder = JSONDecoder()

    func fetchWorks(page: Int = 1) async throws -> WorksResponse {
        var components = URLComponents(url: baseURL.appending(path: "works"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "order", value: "create_date"),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "page", value: String(page))
        ]
        return try await fetch(components.url!)
    }

    func fetchWork(id: Int) async throws -> WorkDetail {
        try await fetch(baseURL.appending(path: "work/\(id)"))
    }

    func fetchTracks(workID: Int) async throws -> [TrackNode] {
        try await fetch(baseURL.appending(path: "tracks/\(workID)"))
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ASMRClientError.badResponse
        }
        return try decoder.decode(T.self, from: data)
    }
}

enum ASMRClientError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        "接口返回异常"
    }
}
