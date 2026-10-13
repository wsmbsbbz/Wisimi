import Foundation

/// Owns synthesis jobs and session results; playback owns the audio clock.
@MainActor
final class TTSCoordinator {
    struct Audio {
        let url: URL
        let notice: String?
        var isFallback = false
    }

    private let edge: any TTSProviderSynthesizing
    private let openRouter: any TTSProviderSynthesizing
    private let cacheDirectory: URL?
    private var session = OpenRouterPlaybackSession()
    private var generation = UUID()
    private var notices: Set<String> = []
    private var jobs: [String: Task<Audio, Error>] = [:]
    private var results: [String: Result<Audio, Error>] = [:]

    init(edge: (any TTSProviderSynthesizing)? = nil,
         openRouter: (any TTSProviderSynthesizing)? = nil, cacheDirectory: URL? = nil) {
        self.edge = edge ?? EdgeTTSProvider()
        self.openRouter = openRouter ?? OpenRouterTTSClient()
        self.cacheDirectory = cacheDirectory
    }

    func reset() {
        cancelPending()
        session.reset()
        notices = []
        results = [:]
    }

    func cancelPending() {
        generation = UUID()
        for job in jobs.values { job.cancel() }
        jobs = [:]
    }

    func cachedAudio(for request: TTSSynthesisRequest, hasCredential: Bool) -> URL? {
        if let cached = cached(request) { return cached }
        if case .success(let audio) = results[key(for: request, hasCredential: hasCredential)],
           TTSCache.containsValidAudio(at: audio.url) { return audio.url }
        guard request.model != .edge, !hasCredential || session.isCircuitOpen else { return nil }
        return cached(edgeRequest(for: request))
    }

    func audio(for request: TTSSynthesisRequest, credential: String?) async throws -> Audio {
        try Task.checkCancellation()
        let id = generation
        let key = key(for: request, hasCredential: credential?.isEmpty == false)
        if let result = results[key] {
            if case .success(let audio) = result, !TTSCache.containsValidAudio(at: audio.url) { results[key] = nil }
            else { return try result.get() }
        }
        let job: Task<Audio, Error>
        if let existing = jobs[key] { job = existing }
        else {
            job = Task { [self] in
                do {
                    let audio = try await resolveAudio(for: request, credential: credential, generation: id)
                    try checkActive(id)
                    results[key] = .success(audio)
                    jobs[key] = nil
                    return audio
                } catch {
                    if id == generation {
                        jobs[key] = nil
                        if !(error is CancellationError), !Task.isCancelled { results[key] = .failure(error) }
                    }
                    throw error
                }
            }
            jobs[key] = job
        }
        let audio = try await job.value
        try checkActive(id)
        return audio
    }

    private func key(for request: TTSSynthesisRequest, hasCredential: Bool) -> String {
        TTSCache.fingerprint(for: request) + (hasCredential ? "|credential" : "|free")
    }

    private func resolveAudio(for request: TTSSynthesisRequest, credential: String?, generation id: UUID) async throws -> Audio {
        try checkActive(id)
        if let url = cached(request) { return Audio(url: url, notice: nil) }
        if request.model == .edge {
            return Audio(url: try await generate(request, using: edge, credential: nil, generation: id), notice: nil)
        }

        let message: String
        if credential?.isEmpty != false {
            message = TTSSynthesisError.missingCredential.localizedDescription
        } else if session.isCircuitOpen {
            message = "OpenRouter 已在本次播放中暂停，旁白将使用 Edge TTS"
        } else {
            var failure = TTSSynthesisError.transport
            for attempt in 0..<OpenRouterRetryPolicy.maximumAttempts {
                do {
                    let url = try await generate(request, using: openRouter, credential: credential, generation: id)
                    session.recordSuccess()
                    return Audio(url: url, notice: nil)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try checkActive(id)
                    failure = (error as? TTSSynthesisError) ?? .transport
                    guard failure.isTransient, attempt + 1 < OpenRouterRetryPolicy.maximumAttempts else { break }
                }
            }
            session.recordFailure(failure)
            message = failure.isTransient && session.isCircuitOpen
                ? "OpenRouter 连续失败，已在本次播放中暂停并使用 Edge TTS"
                : failure.localizedDescription
        }
        let fallback = edgeRequest(for: request)
        let url: URL
        if let existing = cached(fallback) { url = existing }
        else { url = try await generate(fallback, using: edge, credential: nil, generation: id) }
        try checkActive(id)
        return Audio(url: url, notice: notices.insert(message).inserted ? message : nil, isFallback: true)
    }

    private func cached(_ request: TTSSynthesisRequest) -> URL? {
        let url = TTSCache.url(for: request, directory: cacheDirectory)
        guard TTSCache.containsValidAudio(at: url) else {
            TTSCache.removeIfInvalid(at: url)
            return nil
        }
        return url
    }

    private func generate(_ request: TTSSynthesisRequest, using provider: any TTSProviderSynthesizing,
                          credential: String?, generation id: UUID) async throws -> URL {
        let url = TTSCache.url(for: request, directory: cacheDirectory)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).\(request.cacheFileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await provider.synthesize(request, credential: credential, to: temporary)
        try checkActive(id)
        guard TTSCache.containsValidAudio(at: temporary) else {
            throw TTSSynthesisError.invalidResponse
        }
        if let existing = cached(request) { return existing }
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == generation else { throw CancellationError() }
    }

    private func edgeRequest(for request: TTSSynthesisRequest) -> TTSSynthesisRequest {
        TTSSynthesisRequest(model: .edge, voiceID: TTSModelID.edge.defaultVoiceID, text: request.text,
                            speechRate: request.speechRate, expression: .automatic)
    }
}
