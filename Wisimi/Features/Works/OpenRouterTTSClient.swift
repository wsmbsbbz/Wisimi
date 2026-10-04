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

    fileprivate static func makeRequest(for synthesis: TTSSynthesisRequest, credential: String) throws -> URLRequest {
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

    fileprivate static func error(for statusCode: Int, responseBody: Data? = nil) -> TTSSynthesisError {
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

    fileprivate static func finishDownload(from downloadURL: URL, to outputURL: URL) throws {
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

    fileprivate static func finishPCMDownloadAsWAV(from downloadURL: URL, to outputURL: URL) throws {
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

#if DEBUG
@MainActor
enum OpenRouterTTSSelfCheck {
    static func run() {
        let request = TTSSynthesisRequest(model: .geminiFlashPreview, voiceID: "Kore", text: "晚安", speechRate: 1.2, expression: .whisper)
        let urlRequest = try? OpenRouterTTSClient.makeRequest(for: request, credential: "redacted-self-check")
        let body = urlRequest?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        assert(urlRequest?.url?.path == "/api/v1/audio/speech")
        assert(body?["model"] as? String == TTSModelID.geminiFlashPreview.rawValue)
        assert(body?["voice"] as? String == "Kore")
        assert(body?["response_format"] as? String == "pcm")
        assert(body?["speed"] == nil)
        assert((body?["input"] as? String)?.hasPrefix("[whispers]") == true)
        assert(Set(body?.keys.map { $0 } ?? []) == ["input", "model", "voice", "response_format"])

        let minimaxRequest = TTSSynthesisRequest(model: .minimaxTurbo, voiceID: "female-shaonv", text: "晚安，请休息", speechRate: 1.2, expression: .automatic, inlineEffect: .breath)
        let minimaxURLRequest = try? OpenRouterTTSClient.makeRequest(for: minimaxRequest, credential: "redacted-self-check")
        let minimaxBody = minimaxURLRequest?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        assert(Set(minimaxBody?.keys.map { $0 } ?? []) == ["input", "model", "voice", "response_format", "speed"])
        assert(minimaxBody?["speed"] as? Double == 1.2)
        assert(minimaxBody?["input"] as? String == "晚安，(breath)请休息")
        assert(minimaxBody?["response_format"] as? String == "mp3")
        assert(minimaxBody?["provider"] == nil)

        let staleVoiceRequest = TTSSynthesisRequest(model: .geminiFlashPreview, voiceID: "female-shaonv", text: "晚安", speechRate: 1.2, expression: .gentle)
        let staleVoiceURLRequest = try? OpenRouterTTSClient.makeRequest(for: staleVoiceRequest, credential: "redacted-self-check")
        let staleVoiceBody = staleVoiceURLRequest?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        assert(staleVoiceBody?["voice"] as? String == TTSModelID.geminiFlashPreview.defaultVoiceID)
        assert(staleVoiceBody?["input"] as? String == "晚安")
        assert(OpenRouterTTSClient.error(for: 401) == .invalidCredential)
        assert(OpenRouterTTSClient.error(for: 402) == .insufficientCredit)
        assert(OpenRouterTTSClient.error(for: 429) == .rateLimited)
        assert(OpenRouterTTSClient.error(for: 503).isTransient)
        let voiceError = Data(#"{"error":{"message":"Voice is not supported"}}"#.utf8)
        let formatError = Data(#"{"error":{"message":"Invalid response_format"}}"#.utf8)
        assert(OpenRouterTTSClient.error(for: 400, responseBody: voiceError) == .invalidVoice)
        assert(OpenRouterTTSClient.error(for: 422, responseBody: formatError) == .unsupportedAudioFormat)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-fixture-\(UUID().uuidString).pcm")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-fixture-finished-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            let fixture = Data([0x01, 0x00, 0x02, 0x00])
            try fixture.write(to: source, options: .atomic)
            try OpenRouterTTSClient.finishPCMDownloadAsWAV(from: source, to: destination)
            let wav = try Data(contentsOf: destination)
            assert(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
            assert(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
            assert(wav.count == 44 + fixture.count)
            assert(wav.suffix(fixture.count) == fixture)
            assert(TTSCache.containsValidAudio(at: destination))
        } catch {
            assertionFailure("OpenRouter PCM fixture self-check failed")
        }

        let invalidMP3Source = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-invalid-\(UUID().uuidString).mp3")
        let invalidMP3Destination = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-invalid-finished-\(UUID().uuidString).mp3")
        defer {
            try? FileManager.default.removeItem(at: invalidMP3Source)
            try? FileManager.default.removeItem(at: invalidMP3Destination)
        }
        do {
            try Data("not an mp3".utf8).write(to: invalidMP3Source)
            try OpenRouterTTSClient.finishDownload(from: invalidMP3Source, to: invalidMP3Destination)
            assertionFailure("Invalid MP3 fixture must be rejected")
        } catch {
            assert(!FileManager.default.fileExists(atPath: invalidMP3Destination.path))
        }
    }
}
#endif
