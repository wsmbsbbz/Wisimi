import Foundation

final class OpenRouterTTSClient: TTSProviderSynthesizing {
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/speech")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func synthesize(_ request: TTSSynthesisRequest, credential: String?, to outputURL: URL) async throws {
        guard let credential, !credential.isEmpty else { throw TTSSynthesisError.missingCredential }
        guard request.model.provider == .openRouter,
              request.model.capabilities.audioFormats.contains(request.effectiveFormat),
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSSynthesisError.unsupportedConfiguration
        }

        let urlRequest = try Self.makeRequest(for: request, credential: credential)
        do {
            let (downloadURL, response) = try await session.download(for: urlRequest)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw TTSSynthesisError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.error(for: http.statusCode, responseBody: Self.errorBody(at: downloadURL))
            }
            if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") == true {
                throw TTSSynthesisError.invalidResponse
            }
            if request.effectiveFormat == .pcm {
                try Self.finishPCMDownloadAsWAV(from: downloadURL, to: outputURL)
            } else {
                try Self.finishDownload(from: downloadURL, to: outputURL)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TTSSynthesisError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw TTSSynthesisError.timeout
        } catch {
            throw TTSSynthesisError.transport
        }
    }

    static func makeRequest(for synthesis: TTSSynthesisRequest, credential: String) throws -> URLRequest {
        let body = OpenRouterSpeechRequest(
            input: mappedText(for: synthesis),
            model: synthesis.model.rawValue,
            voice: synthesis.normalizedVoiceID,
            responseFormat: synthesis.effectiveFormat.rawValue,
            speed: synthesis.model.supportsSpeechRate ? synthesis.effectiveSpeechRate : nil
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    fileprivate static func mappedText(for request: TTSSynthesisRequest) -> String {
        switch request.model {
        case .minimaxTurbo, .minimaxHD:
            return request.normalizedInlineEffect.applyingToMiniMaxText(request.text)
        case .geminiFlashPreview:
            switch request.normalizedExpression {
            case .whisper: return "[whispers] \(request.text)"
            case .lively: return "[excited] \(request.text)"
            default: return request.text
            }
        case .edge:
            return request.text
        }
    }

    static func error(for statusCode: Int, responseBody: Data? = nil) -> TTSSynthesisError {
        switch statusCode {
        case 401: .invalidCredential
        case 402: .insufficientCredit
        case 429: .rateLimited
        case 404: .modelUnavailable
        case 400, 422:
            configurationError(for: responseBody)
        case 500...599: .upstream(statusCode: statusCode)
        default: .invalidResponse
        }
    }

    private static func configurationError(for responseBody: Data?) -> TTSSynthesisError {
        guard let responseBody,
              let envelope = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: responseBody) else {
            return .unsupportedConfiguration
        }
        let message = envelope.error.message.lowercased()
        if message.contains("voice") { return .invalidVoice }
        if message.contains("response_format") || message.contains("audio format") || message.contains("format") {
            return .unsupportedAudioFormat
        }
        if message.contains("model") { return .modelUnavailable }
        if message.contains("input") || message.contains("text") { return .invalidInput }
        return .unsupportedConfiguration
    }

    private static func errorBody(at url: URL) -> Data? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue <= 64 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }

    static func finishDownload(from downloadURL: URL, to outputURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: outputURL.path) { return }
        let attributes = try manager.attributesOfItem(atPath: downloadURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { throw TTSSynthesisError.emptyAudio }

        let partialURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: partialURL) }
        try manager.copyItem(at: downloadURL, to: partialURL)
        guard TTSCache.containsValidAudio(at: partialURL) else {
            throw TTSSynthesisError.invalidResponse
        }
        do {
            try manager.moveItem(at: partialURL, to: outputURL)
        } catch where manager.fileExists(atPath: outputURL.path) {
            return
        }
    }

    static func finishPCMDownloadAsWAV(from downloadURL: URL, to outputURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: outputURL.path) { return }

        let attributes = try manager.attributesOfItem(atPath: downloadURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount > 0,
              byteCount.isMultiple(of: 2),
              byteCount <= UInt64(UInt32.max - 36) else {
            throw TTSSynthesisError.invalidResponse
        }

        let partialURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: partialURL) }
        guard manager.createFile(
            atPath: partialURL.path,
            contents: wavHeader(pcmByteCount: UInt32(byteCount))
        ) else {
            throw TTSSynthesisError.invalidResponse
        }

        do {
            let source = try FileHandle(forReadingFrom: downloadURL)
            let destination = try FileHandle(forWritingTo: partialURL)
            defer {
                try? source.close()
                try? destination.close()
            }
            try destination.seekToEnd()
            while let chunk = try source.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try destination.write(contentsOf: chunk)
            }
            try destination.synchronize()
        }

        guard TTSCache.containsValidAudio(at: partialURL) else {
            throw TTSSynthesisError.invalidResponse
        }

        do {
            try manager.moveItem(at: partialURL, to: outputURL)
        } catch where manager.fileExists(atPath: outputURL.path) {
            return
        }
    }

    private static func wavHeader(pcmByteCount: UInt32) -> Data {
        let channels: UInt16 = 1
        let sampleRate: UInt32 = 24_000
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)

        var header = Data("RIFF".utf8)
        header.appendLittleEndian(36 + pcmByteCount)
        header.append(Data("WAVEfmt ".utf8))
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1))
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append(Data("data".utf8))
        header.appendLittleEndian(pcmByteCount)
        return header
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private struct OpenRouterSpeechRequest: Encodable {
    let input: String
    let model: String
    let voice: String
    let responseFormat: String
    let speed: Double?

    enum CodingKeys: String, CodingKey {
        case input, model, voice, speed
        case responseFormat = "response_format"
    }
}

private struct OpenRouterErrorEnvelope: Decodable {
    struct ErrorPayload: Decodable {
        let message: String
    }

    let error: ErrorPayload
}


