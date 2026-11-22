import Combine
import Foundation
import Security
import Testing
@testable import Wisimi

@Suite("TTS, Settings, and Keychain", .serialized)
@MainActor
struct TTSTests {
    @Test func ttsModelsAndCache() {
        #expect(TTSModelID.allCases.count == 4)
        #expect(TTSModelID.minimaxTurbo.provider == .openRouter)
        #expect(TTSModelID.geminiFlashPreview.displayName.contains("实验性"))
        #expect(!TTSModelID.minimaxTurbo.supportedExpressions.contains(.whisper))
        #expect(TTSModelID.minimaxTurbo.speechRateRange == (0.5...2))
        #expect(TTSModelID.minimaxHD.speechRateRange == (0.5...2))
        #expect(!TTSModelID.geminiFlashPreview.supportsSpeechRate)
        #expect(TTSModelID.geminiFlashPreview.capabilities.preferredAudioFormat == .pcm)
        #expect(TTSModelID.edge.capabilities.supportsVoiceSelection == false)
        #expect(TTSModelID.minimaxTurbo.capabilities.supportsVoiceSelection)
        #expect(TTSModelID.minimaxTurbo.capabilities.supportsExpressionSelection == false)
        #expect(TTSModelID.minimaxTurbo.capabilities.supportsInlineEffectSelection)
        #expect(TTSModelID.minimaxTurbo.voices.count == 6)
        #expect(TTSModelID.minimaxTurbo.voices.allSatisfy { !$0.id.lowercased().hasPrefix("male-") })
        #expect(!TTSModelID.minimaxTurbo.voices.contains { $0.id == "female-yujie" })
        #expect(TTSModelID.minimaxTurbo.supportedInlineEffects.contains(.lipSmacking))
        #expect(TTSModelID.geminiFlashPreview.capabilities.supportsExpressionSelection)

        let base = TTSSynthesisRequest(model: .minimaxTurbo, voiceID: "female-shaonv", text: "你好", speechRate: 1, expression: .automatic)
        let gemini = TTSSynthesisRequest(model: .geminiFlashPreview, voiceID: "Kore", text: "你好", speechRate: 1, expression: .automatic)
        #expect(base.effectiveFormat == .mp3)
        #expect(base.cacheURL.pathExtension == "mp3")
        #expect(gemini.effectiveFormat == .pcm)
        #expect(gemini.cacheURL.pathExtension == "wav")
        #expect(TTSCache.fingerprint(for: base) == TTSCache.fingerprint(for: base))
        #expect(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: .minimaxHD, voiceID: base.voiceID, text: base.text, speechRate: base.speechRate, expression: base.expression)))
        #expect(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: base.model, voiceID: "Chinese (Mandarin)_Soft_Girl", text: base.text, speechRate: base.speechRate, expression: base.expression)))
        #expect(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: base.model, voiceID: base.voiceID, text: base.text, speechRate: 1.2, expression: base.expression)))
        #expect(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: base.model, voiceID: base.voiceID, text: base.text, speechRate: base.speechRate, expression: base.expression, inlineEffect: .breath)))

        let invalidAudio = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-audio-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: invalidAudio) }
        try? Data("not audio".utf8).write(to: invalidAudio)
        #expect(!TTSCache.containsValidAudio(at: invalidAudio))
        TTSCache.removeIfInvalid(at: invalidAudio)
        #expect(!FileManager.default.fileExists(atPath: invalidAudio.path))

        var session = OpenRouterPlaybackSession()
        session.recordFailure(.rateLimited)
        session.recordFailure(.timeout)
        #expect(!session.isCircuitOpen)
        session.recordFailure(.upstream(statusCode: 503))
        #expect(session.isCircuitOpen)
        session.reset()
        #expect(!session.isCircuitOpen && session.consecutiveTransientFailures == 0)
        session.recordFailure(.invalidCredential)
        #expect(session.isCircuitOpen)
        #expect(OpenRouterRetryPolicy.maximumAttempts == 2)
    }

    @Test func edgeOnlineTTSAndSignature() {
        let payload = Data([1, 2, 3])
        let header = Data("Path:audio\r\nX:1".utf8)
        var binaryFrame = Data([UInt8(header.count / 256), UInt8(header.count % 256)])
        binaryFrame.append(header)
        binaryFrame.append(payload)
        #expect(EdgeOnlineTTSClient.audioPayload(from: binaryFrame) == payload)

        let crlfFrame = Data("Path:audio\r\n\r\nabc".utf8)
        #expect(EdgeOnlineTTSClient.audioPayload(from: crlfFrame) == Data("abc".utf8))

        let nonAudioFrame = Data("Path:turn.end\r\n\r\n".utf8)
        #expect(EdgeOnlineTTSClient.audioPayload(from: nonAudioFrame) == nil)
        #expect(EdgeOnlineTTSClient.ssmlRate(for: 1.0) == 0)
        #expect(EdgeOnlineTTSClient.ssmlRate(for: 1.25) == 25)
        let edgeRate1 = TTSSynthesisRequest(model: .edge, voiceID: TTSModelID.edge.defaultVoiceID, text: "hello", speechRate: 1.0, expression: .automatic)
        let edgeRate125 = TTSSynthesisRequest(model: .edge, voiceID: TTSModelID.edge.defaultVoiceID, text: "hello", speechRate: 1.25, expression: .automatic)
        #expect(edgeRate1.cacheURL != edgeRate125.cacheURL)
        #expect(EdgeOnlineTTSClient.ssmlMessage(requestID: "id", text: "hello", speechRate: 1.25).contains("rate=\"+25%\""))
        #expect(EdgeSpeechSignature.token(at: 1_700_000_000) == "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2")
        #expect(EdgeSpeechSignature.token(at: 1_791_907_200) == "15F3FF629419C5C3-25518D01D8A232E310AF58C808C2B58F6FF62947805FB0F70E013DDA9E88D169")
        #expect(EdgeSpeechSignature.token(at: 1_791_907_499) == EdgeSpeechSignature.token(at: 1_791_907_200))
        #expect(EdgeSpeechSignature.token(at: 1_791_907_500) == "C9D9CBAF94BE118A-2DDDC327EE532F5937C271B3010E916D04F12E19E00586E8E98938789716A033")
    }

    @Test func openRouterTTSClientRequestsAndValidation() throws {
        let request = TTSSynthesisRequest(model: .geminiFlashPreview, voiceID: "Kore", text: "晚安", speechRate: 1.2, expression: .whisper)
        let urlRequest = try OpenRouterTTSClient.makeRequest(for: request, credential: "redacted-self-check")
        let body = try #require(urlRequest.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(urlRequest.url?.path == "/api/v1/audio/speech")
        #expect(body["model"] as? String == TTSModelID.geminiFlashPreview.rawValue)
        #expect(body["voice"] as? String == "Kore")
        #expect(body["response_format"] as? String == "pcm")
        #expect(body["speed"] == nil)
        #expect((body["input"] as? String)?.hasPrefix("[whispers]") == true)
        #expect(Set(body.keys) == ["input", "model", "voice", "response_format"])

        let minimaxRequest = TTSSynthesisRequest(model: .minimaxTurbo, voiceID: "female-shaonv", text: "晚安，请休息", speechRate: 1.2, expression: .automatic, inlineEffect: .breath)
        let minimaxURLRequest = try OpenRouterTTSClient.makeRequest(for: minimaxRequest, credential: "redacted-self-check")
        let minimaxBody = try #require(minimaxURLRequest.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(minimaxBody.keys) == ["input", "model", "voice", "response_format", "speed"])
        #expect(minimaxBody["speed"] as? Double == 1.2)
        #expect(minimaxBody["input"] as? String == "晚安，(breath)请休息")
        #expect(minimaxBody["response_format"] as? String == "mp3")
        #expect(minimaxBody["provider"] == nil)

        let staleVoiceRequest = TTSSynthesisRequest(model: .geminiFlashPreview, voiceID: "female-shaonv", text: "晚安", speechRate: 1.2, expression: .automatic)
        let staleVoiceURLRequest = try OpenRouterTTSClient.makeRequest(for: staleVoiceRequest, credential: "redacted-self-check")
        let staleVoiceBody = try #require(staleVoiceURLRequest.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(staleVoiceBody["voice"] as? String == TTSModelID.geminiFlashPreview.defaultVoiceID)
        #expect(staleVoiceBody["input"] as? String == "晚安")
        let unsupportedExpression = TTSSynthesisRequest(model: .minimaxTurbo, voiceID: "female-shaonv", text: "晚安", speechRate: 1.0, expression: .whisper)
        #expect(unsupportedExpression.normalizedExpression == .automatic)
        #expect(OpenRouterTTSClient.error(for: 401) == .invalidCredential)
        #expect(OpenRouterTTSClient.error(for: 402) == .insufficientCredit)
        #expect(OpenRouterTTSClient.error(for: 429) == .rateLimited)
        #expect(OpenRouterTTSClient.error(for: 503).isTransient)

        let voiceError = Data(#"{"error":{"message":"Voice is not supported"}}"#.utf8)
        let formatError = Data(#"{"error":{"message":"Invalid response_format"}}"#.utf8)
        #expect(OpenRouterTTSClient.error(for: 400, responseBody: voiceError) == .invalidVoice)
        #expect(OpenRouterTTSClient.error(for: 422, responseBody: formatError) == .unsupportedAudioFormat)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-fixture-\(UUID().uuidString).pcm")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-fixture-finished-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let fixture = Data([0x01, 0x00, 0x02, 0x00])
        try fixture.write(to: source, options: .atomic)
        try OpenRouterTTSClient.finishPCMDownloadAsWAV(from: source, to: destination)
        let wav = try Data(contentsOf: destination)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(wav.count == 44 + fixture.count)
        #expect(wav.suffix(fixture.count) == fixture)
        #expect(TTSCache.containsValidAudio(at: destination))

        let invalidMP3Source = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-invalid-\(UUID().uuidString).mp3")
        let invalidMP3Destination = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-invalid-finished-\(UUID().uuidString).mp3")
        defer {
            try? FileManager.default.removeItem(at: invalidMP3Source)
            try? FileManager.default.removeItem(at: invalidMP3Destination)
        }
        try Data("not an mp3".utf8).write(to: invalidMP3Source)
        #expect(throws: (any Error).self) {
            try OpenRouterTTSClient.finishDownload(from: invalidMP3Source, to: invalidMP3Destination)
        }
        #expect(!FileManager.default.fileExists(atPath: invalidMP3Destination.path))
    }

    @Test func ttsCoordinatorFallbackAndCaching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edge = SpeechStub(), paid = SpeechStub()
        let synthesis = TTSCoordinator(edge: edge, openRouter: paid, cacheDirectory: directory)
        func request(_ text: String, model: TTSModelID = .minimaxTurbo) -> TTSSynthesisRequest {
            TTSSynthesisRequest(model: model, voiceID: model.defaultVoiceID, text: text, speechRate: 1, expression: .automatic)
        }

        paid.shouldSuspend = true
        let prefetch = Task { try await synthesis.audio(for: request("shared"), credential: "test") }
        try await waitUntil { paid.pending != nil }
        let current = Task { try await synthesis.audio(for: request("shared"), credential: "test") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(paid.requests.count == 1)
        paid.pending?.resume(); paid.pending = nil
        let prefetched = try await prefetch.value
        let playing = try await current.value
        #expect(prefetched.url == playing.url)

        paid.shouldSuspend = false
        paid.requests = []
        let first = try await synthesis.audio(for: request("cached"), credential: "test")
        #expect(TTSCache.containsValidAudio(at: first.url))
        _ = try await synthesis.audio(for: request("cached"), credential: nil)
        #expect(paid.requests.count == 1 && edge.requests.isEmpty)
        #expect(synthesis.cachedAudio(for: request("cached"), hasCredential: false) == first.url)

        let missing = try await synthesis.audio(for: request("missing"), credential: nil)
        #expect(missing.notice != nil && edge.requests.count == 1)
        let repeated = try await synthesis.audio(for: request("missing-again"), credential: "")
        #expect(repeated.notice == nil)
        #expect(synthesis.cachedAudio(for: request("missing"), hasCredential: false) == missing.url)
        #expect(synthesis.cachedAudio(for: request("missing"), hasCredential: true) == nil)
        #expect(synthesis.cachedAudio(for: request("unknown"), hasCredential: false) == nil)

        paid.failures = [TTSSynthesisError.rateLimited]
        _ = try await synthesis.audio(for: request("retry"), credential: "test")
        #expect(paid.requests.filter { $0.text == "retry" }.count == 2)

        paid.failures = [TTSSynthesisError.invalidCredential]
        _ = try await synthesis.audio(for: request("invalid"), credential: "test")
        let count = paid.requests.count
        _ = try await synthesis.audio(for: request("circuit"), credential: "test")
        #expect(paid.requests.count == count)
        synthesis.reset()
        _ = try await synthesis.audio(for: request("reset"), credential: "test")
        #expect(paid.requests.count == count + 1)

        for i in 0..<3 {
            paid.failures = [TTSSynthesisError.timeout, TTSSynthesisError.transport]
            _ = try await synthesis.audio(for: request("transient-\(i)"), credential: "test")
        }
        let failedCount = paid.requests.count
        _ = try await synthesis.audio(for: request("after-transient"), credential: "test")
        #expect(paid.requests.count == failedCount)
        synthesis.reset()
        paid.failures = [TTSSynthesisError.invalidVoice]
        _ = try await synthesis.audio(for: request("configuration"), credential: "test")
        paid.failures = [URLError(.timedOut), URLError(.timedOut)]
        _ = try await synthesis.audio(for: request("transport"), credential: "test")
        paid.failures = [CancellationError()]
        do {
            _ = try await synthesis.audio(for: request("cancelled"), credential: "test")
            Issue.record("Cancellation must not trigger fallback")
        } catch is CancellationError {}

        edge.invalidAudio = true
        do {
            _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil)
            Issue.record("Invalid audio must not be cached")
        } catch let error as TTSSynthesisError {
            #expect(error == .invalidResponse)
        }
        #expect(synthesis.cachedAudio(for: request("invalid-audio", model: .edge), hasCredential: false) == nil)

        edge.invalidAudio = false
        let attempts = edge.requests.count
        for _ in 0..<5 {
            do { _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil) }
            catch let error as TTSSynthesisError { #expect(error == .invalidResponse) }
        }
        #expect(edge.requests.count == attempts)
        synthesis.reset()
        _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil)
        let edgeCount = edge.requests.count
        _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil)
        #expect(edge.requests.count == edgeCount)

        paid.shouldSuspend = true
        let old = Task { try await synthesis.audio(for: request("old-session"), credential: "test") }
        try await waitUntil { paid.pending != nil }
        synthesis.reset()
        paid.pending?.resume(); paid.pending = nil
        do {
            _ = try await old.value
            Issue.record("Old session must be cancelled")
        } catch is CancellationError {}
        #expect(synthesis.cachedAudio(for: request("old-session"), hasCredential: true) == nil)

        paid.shouldSuspend = false
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await synthesis.audio(for: request("cancelled-before-cache"), credential: nil)
        }
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled request must fail")
        } catch is CancellationError {}
    }

    @Test func ttsMixSettingsAndConnectionTest() async throws {
        defer { HTTPStub.reset() }
        let suite = "RefactorSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = TTSMixSettings(defaults: defaults)
        #expect(settings.isEnabled == false)
        #expect(settings.volume == 0.5)
        #expect(settings.maxSpeechRate == 1.25)
        #expect(settings.model == .edge)
        #expect(settings.voiceID == TTSModelID.edge.defaultVoiceID)
        #expect(settings.expressionPreset == .automatic)
        #expect(settings.inlineEffectPreset == .automatic)

        var changes: [TTSSynthesisRequest] = []
        let subscription = settings.$configuration.dropFirst().sink { changes.append($0.request(text: "test")) }
        settings.model = .minimaxHD
        #expect(changes.count == 1 && changes[0].normalizedVoiceID == TTSModelID.minimaxHD.defaultVoiceID)
        settings.maxSpeechRate = 9
        #expect(settings.maxSpeechRate == 2)
        settings.inlineEffectPreset = .breath
        #expect(settings.synthesisRequest(text: "晚安，请休息").inlineEffect == .breath)
        settings.model = .geminiFlashPreview
        #expect(settings.maxSpeechRate == 1 && settings.inlineEffectPreset == .automatic)
        #expect(changes.last?.voiceID == TTSModelID.geminiFlashPreview.defaultVoiceID)
        let count = changes.count
        settings.maxSpeechRate = 9
        #expect(changes.count == count)
        settings.volume = -1
        #expect(settings.volume == 0)
        settings.isEnabled = true
        let restored = TTSMixSettings(defaults: defaults)
        #expect(restored.configuration == settings.configuration && restored.isEnabled && restored.volume == 0)

        let keychain = InMemoryKeychain()
        let tokenStore = OpenRouterTokenStore(
            service: "wisimi.refactor-token.\(UUID().uuidString)",
            operations: keychain.operations
        )
        defer { try? tokenStore.delete() }
        let http = URLSessionConfiguration.ephemeral
        http.protocolClasses = [HTTPStub.self]
        let connection = TTSMixSettings(
            defaults: defaults,
            tokenStore: tokenStore,
            openRouterClient: OpenRouterTTSClient(session: URLSession(configuration: http))
        )
        await connection.testOpenRouterConnection()
        if case .failure = connection.connectionTestState {} else { Issue.record("Missing credentials must fail") }
        connection.model = .edge
        HTTPStub.respond = { _ in (200, "") }
        HTTPStub.payload = try Data(contentsOf: TestFixtures.silenceMP3URL)
        await connection.testOpenRouterConnection(candidateToken: " test ")
        #expect(connection.isOpenRouterConfigured && connection.model == .minimaxTurbo)
        #expect(try tokenStore.load() == "test")
        await connection.testOpenRouterConnection()
        if case .success = connection.connectionTestState {} else { Issue.record("Valid audio must pass connection test") }
        HTTPStub.payload = nil
        HTTPStub.respond = { _ in (401, "") }
        await connection.testOpenRouterConnection(candidateToken: "invalid")
        if case .failure = connection.connectionTestState {} else { Issue.record("Invalid credentials must fail") }
        connection.deleteOpenRouterToken()
        #expect(!connection.isOpenRouterConfigured && connection.model == .edge && connection.connectionTestState == .idle)
        withExtendedLifetime(subscription) {}
    }

    @Test func keychainItemAndErrorMapping() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainItem(
            service: "wisimi.refactor.\(UUID().uuidString)",
            account: "test",
            operations: keychain.operations
        )
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        try store.save(Data("first".utf8))
        try store.save(Data("second".utf8))
        #expect(try store.load() == Data("second".utf8))
        try store.delete()
        try store.delete()
        #expect(try store.load() == nil)

        let restricted = KeychainItem(
            service: store.service,
            account: store.account,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false,
            operations: keychain.operations
        )
        try restricted.save(Data("retained".utf8))

        var failure: OSStatus = errSecAuthFailed
        let operations = KeychainOperations(
            read: { _ in (failure, nil) },
            update: { _, _ in failure },
            add: { _ in errSecAuthFailed },
            delete: { _ in failure }
        )
        let failing = KeychainItem(service: store.service, account: "errors", operations: operations)
        do { _ = try failing.load(); Issue.record("Read failure must be reported") }
        catch let error as KeychainError { #expect(error.errorDescription != nil) }
        do { try failing.save(Data()); Issue.record("Update failure must be reported") }
        catch let error as KeychainError { #expect(error.status == errSecAuthFailed) }
        failure = errSecItemNotFound
        do { try failing.save(Data()); Issue.record("Add failure must be reported") }
        catch let error as KeychainError { #expect(error.status == errSecAuthFailed) }
        failure = errSecAuthFailed
        do { try failing.delete(); Issue.record("Delete failure must be reported") }
        catch let error as KeychainError { #expect(error.status == errSecAuthFailed) }
        #expect(try restricted.load() == Data("retained".utf8))
    }

    @Test func openRouterTokenStore() throws {
        let keychain = InMemoryKeychain()
        let basic = OpenRouterTokenStore(
            service: "wisimi.openrouter.self-check.\(UUID().uuidString)",
            operations: keychain.operations
        )
        defer { try? basic.delete() }
        #expect(basic.isConfigured == false)
        try basic.save("self-check-first")
        #expect(basic.isConfigured)
        try basic.save("self-check-replaced")
        #expect(basic.isConfigured)
        try basic.delete()
        #expect(basic.isConfigured == false)

        let service = "wisimi.refactor-token-errors.\(UUID().uuidString)"
        let token = OpenRouterTokenStore(service: service, operations: keychain.operations)
        defer { try? token.delete() }
        var storedAccessibility: CFString?
        var storedValue: Data? = Data("existing-token".utf8)
        let background = OpenRouterTokenStore(
            service: service,
            operations: KeychainOperations(
                read: { _ in (errSecSuccess, storedValue) },
                update: { _, attributes in
                    storedAccessibility = attributes[kSecAttrAccessible as String] as! CFString?
                    storedValue = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            )
        )
        try background.prepareForBackgroundAccess()
        #expect(storedAccessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(storedValue == Data("existing-token".utf8))

        let blockedSettings = TTSMixSettings(tokenStore: OpenRouterTokenStore(operations: KeychainOperations(
            read: { _ in (errSecInteractionNotAllowed, nil) },
            update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in errSecInteractionNotAllowed },
            delete: { _ in errSecInteractionNotAllowed }
        )))
        do { _ = try blockedSettings.openRouterToken(); Issue.record("Locked Keychain must not be treated as missing token") }
        catch let error as OpenRouterTokenStoreError { #expect(error.errorDescription != nil) }
        do { try token.save("  "); Issue.record("Empty token must fail") }
        catch let error as OpenRouterTokenStoreError { #expect(error.errorDescription != nil) }

        let raw = KeychainItem(service: service, account: "api-token", synchronizable: false, operations: keychain.operations)
        try raw.save(Data([0xff]))
        do { _ = try token.load(); Issue.record("Malformed stored token must fail") }
        catch let error as OpenRouterTokenStoreError { #expect(error.errorDescription != nil) }

        let failure = KeychainOperations(
            read: { _ in (errSecAuthFailed, nil) },
            update: { _, _ in errSecAuthFailed },
            add: { _ in errSecAuthFailed },
            delete: { _ in errSecAuthFailed }
        )
        let failed = OpenRouterTokenStore(service: service, operations: failure)
        do { _ = try failed.load(); Issue.record("Load error must be mapped") }
        catch let error as OpenRouterTokenStoreError { #expect(error.errorDescription != nil) }
        do { try failed.save("test"); Issue.record("Save error must be mapped") }
        catch let error as OpenRouterTokenStoreError { #expect(error.errorDescription != nil) }
        do { try failed.delete(); Issue.record("Delete error must be mapped") }
        catch let error as OpenRouterTokenStoreError { #expect(error.errorDescription != nil) }
    }
}
