#if DEBUG
import Foundation

enum DebugSimilarWorksFixture {
    static let workID = 900001

    static func client() -> ASMRClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimilarWorksFixtureProtocol.self]
        return ASMRClient(session: URLSession(configuration: configuration))
    }
}

private final class SimilarWorksFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let screen = ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] ?? "similar"
        let path = request.url!.path
        var body: [String: Any] = [:]
        if let data = request.httpBody { body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let page = body["page"] as? Int ?? 1
        let pageSize = screen == "similar-pagination" || screen == "similar-page-error" ? 2 : 20
        if path.hasSuffix("item-neighbors"), screen == "similar-error" || screen == "similar-page-error" && page == 2 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let json: Any
        if path.contains("/tracks/") {
            json = [["type": "folder", "title": "试听目录", "hash": "preview", "children": []]]
        } else if path.contains("/work/") {
            let id = Int(path.split(separator: "/").last ?? "") ?? DebugSimilarWorksFixture.workID
            var work = summary(id: id)
            work["dl_count"] = 1200
            json = work
        } else {
            let empty = screen == "similar-empty"
            let source = Int(body["itemId"] as? String ?? "") ?? DebugSimilarWorksFixture.workID
            let works = empty ? [] : (0..<pageSize).map { summary(id: source + page * pageSize + $0) }
            json = ["works": works, "pagination": ["currentPage": page, "pageSize": pageSize, "totalCount": empty ? 0 : pageSize * 5]]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func summary(id: Int) -> [String: Any] {
        ["id": id, "title": "雨夜书房 · 安静的朗读与窗外雨声 \(id)", "name": "夜间电台",
         "duration": 5400, "rate_average_2dp": 4.8, "has_subtitle": id.isMultiple(of: 2),
         "tags": id.isMultiple(of: 2)
            ? [["id": 1, "name": "雨声"], ["id": 2, "name": "朗读"], ["id": 3, "name": "环境音"], ["id": 4, "name": "安静的夜晚"]]
            : [["id": 1, "name": "雨声"]],
         "vas": [["id": 1, "name": "轻声朗读"]]]
    }
}
#endif
