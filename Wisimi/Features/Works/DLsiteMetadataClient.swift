import Foundation

nonisolated enum RJCodeExtractor {
    private static let pattern = try! NSRegularExpression(pattern: #"(?i)(?<![A-Z0-9])RJ(\d{1,8})(?!\d)"#)

    /// Extracts the first DLsite RJ code (1 to 8 digits) from a folder or title string, normalized to uppercase.
    static func extract(from text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let digitsRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return "RJ" + text[digitsRange]
    }
}

nonisolated struct DLsiteMetadataResult: Sendable {
    let metadata: LocalWorkMetadata
    let coverURL: URL?
}

nonisolated enum DLsiteMetadataError: LocalizedError, Equatable {
    case invalidRJCode
    case notFound
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidRJCode: "无法识别有效的 RJ 号。"
        case .notFound: "DLsite 未找到该作品。"
        case .invalidResponse: "DLsite 返回的数据格式无效。"
        case .network(let message): "请求 DLsite 失败：\(message)"
        }
    }
}

nonisolated protocol DLsiteMetadataFetching: Sendable {
    func fetchMetadata(for rjCode: String) async throws -> DLsiteMetadataResult
    func downloadCover(from url: URL) async throws -> Data
}

nonisolated struct DLsiteMetadataClient: DLsiteMetadataFetching, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchMetadata(for rjCode: String) async throws -> DLsiteMetadataResult {
        guard let normalized = RJCodeExtractor.extract(from: rjCode),
              normalized.caseInsensitiveCompare(rjCode) == .orderedSame else {
            throw DLsiteMetadataError.invalidRJCode
        }
        async let productResponse = fetchData(from: Self.productURL(for: normalized))
        async let ajaxResponse = try? fetchData(from: Self.ajaxURL(for: normalized))

        let product = try Self.parseProductJSON(try await productResponse.data)
        try Task.checkCancellation()

        var circle = product.makerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let originalWorkno = product.translationInfo?.originalWorkno.flatMap(RJCodeExtractor.extract(from:)),
           originalWorkno.caseInsensitiveCompare(normalized) != .orderedSame {
            let originalResponse = try? await fetchData(from: Self.productURL(for: originalWorkno))
            try Task.checkCancellation()
            if let originalData = originalResponse?.data,
               let originalProduct = try? Self.parseProductJSON(originalData),
               let originalCircle = originalProduct.makerName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !originalCircle.isEmpty {
                circle = originalCircle
            }
        }

        let ajaxPayload = await ajaxResponse
        try Task.checkCancellation()
        let ajax = ajaxPayload.flatMap { try? Self.parseAjaxJSON($0.data, for: normalized) }
        let tags = Self.cleanNames(product.genres?.compactMap(\.name) ?? [])
        let voiceActors = Self.cleanNames(product.creaters?.voiceBy?.compactMap(\.name) ?? [])

        let metadata = LocalWorkMetadata(
            title: product.workName?.trimmingCharacters(in: .whitespacesAndNewlines),
            circle: circle?.isEmpty == true ? nil : circle,
            duration: nil,
            rating: ajax?.rateAverage2dp,
            sales: ajax?.dlCount,
            catalogCode: product.workno?.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalized,
            tags: tags.isEmpty ? nil : tags,
            voiceActors: voiceActors.isEmpty ? nil : voiceActors,
            cover: nil
        )
        return DLsiteMetadataResult(metadata: metadata, coverURL: Self.resolveImageURL(product.imageMain?.url))
    }

    func downloadCover(from url: URL) async throws -> Data {
        let (data, http) = try await fetchData(from: url, accept: "image/*,*/*;q=0.8")
        if data.isEmpty || data.first == 0x3C {
            throw DLsiteMetadataError.invalidResponse
        }
        if let mime = http.mimeType?.lowercased(), mime.hasPrefix("text/") || mime == "application/json" {
            throw DLsiteMetadataError.invalidResponse
        }
        return data
    }

    private func fetchData(from url: URL, accept: String = "application/json") async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            throw urlError
        } catch {
            throw DLsiteMetadataError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DLsiteMetadataError.invalidResponse
        }
        if http.statusCode == 404 {
            throw DLsiteMetadataError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DLsiteMetadataError.network("HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    static func productURL(for rjCode: String) -> URL {
        URL(string: "https://www.dlsite.com/maniax/api/=/product.json?workno=\(rjCode)")!
    }

    static func ajaxURL(for rjCode: String) -> URL {
        URL(string: "https://www.dlsite.com/maniax/product/info/ajax?product_id=\(rjCode)")!
    }

    static func parseProductJSON(_ data: Data) throws -> ProductDTO {
        let list: [ProductDTO]
        do {
            list = try JSONDecoder().decode([ProductDTO].self, from: data)
        } catch {
            throw DLsiteMetadataError.invalidResponse
        }
        guard let first = list.first else {
            throw DLsiteMetadataError.notFound
        }
        return first
    }

    static func parseAjaxJSON(_ data: Data, for rjCode: String) throws -> AjaxDTO {
        let map = try JSONDecoder().decode([String: AjaxDTO].self, from: data)
        if let exact = map[rjCode] { return exact }
        if let first = map.values.first { return first }
        throw DLsiteMetadataError.notFound
    }

    static func resolveImageURL(_ raw: String?) -> URL? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return URL(string: text.hasPrefix("//") ? "https:" + text : text)
    }

    private static func cleanNames(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}

extension DLsiteMetadataClient {
    nonisolated struct ProductDTO: Decodable {
        struct Genre: Decodable {
            let name: String?
        }
        struct Creator: Decodable {
            let name: String?
        }
        struct Creaters: Decodable {
            let voiceBy: [Creator]?
            enum CodingKeys: String, CodingKey { case voiceBy = "voice_by" }
        }
        struct TranslationInfo: Decodable {
            let originalWorkno: String?
            enum CodingKeys: String, CodingKey { case originalWorkno = "original_workno" }
        }
        struct ImageMain: Decodable {
            let url: String?
        }

        let workno: String?
        let workName: String?
        let makerName: String?
        let genres: [Genre]?
        let creaters: Creaters?
        let translationInfo: TranslationInfo?
        let imageMain: ImageMain?

        enum CodingKeys: String, CodingKey {
            case workno
            case workName = "work_name"
            case makerName = "maker_name"
            case genres
            case creaters
            case translationInfo = "translation_info"
            case imageMain = "image_main"
        }
    }

    nonisolated struct AjaxDTO: Decodable {
        let dlCount: Int?
        let rateAverage2dp: Double?

        enum CodingKeys: String, CodingKey {
            case dlCount = "dl_count"
            case rateAverage2dp = "rate_average_2dp"
        }
    }
}
