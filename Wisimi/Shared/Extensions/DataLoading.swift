import Foundation

extension Data {
    /// Loads bytes from a local file URL off the main actor or from an HTTP(S) URL with status validation.
    nonisolated static func load(from url: URL, session: URLSession = .shared) async throws -> Data {
        if url.isFileURL {
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
