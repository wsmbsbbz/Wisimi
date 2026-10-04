import Foundation
import Combine
import Security

// 用户流程：缓存旁白不重复请求；失败按既有策略回退；搜索与目录刷新保持最新结果；
// 播放列表编辑立即同步；模型切换只发布有效配置；凭据替换不丢失旧值。
@MainActor
final class SpeechStub: TTSProviderSynthesizing {
    var requests: [TTSSynthesisRequest] = []
    var failures: [Error] = []
    var invalidAudio = false
    var shouldSuspend = false
    var pending: CheckedContinuation<Void, Never>?

    func synthesize(_ request: TTSSynthesisRequest, credential: String?, to outputURL: URL) async throws {
        requests.append(request)
        if shouldSuspend { await withCheckedContinuation { pending = $0 } }
        if !failures.isEmpty { throw failures.removeFirst() }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // PCM WAV fixture exercises real audio validation, without remote TTS or paid calls.
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        integer(UInt32(4836)); data.append(Data("WAVEfmt ".utf8)); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(24000)); integer(UInt32(48000))
        integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(UInt32(4800))
        data.append(Data(repeating: 0, count: 4800))
        if request.cacheFileExtension == "mp3" {
            data = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/silence.mp3"))
        }
        try (invalidAudio ? Data("invalid".utf8) : data).write(to: outputURL, options: .atomic)
        assert(invalidAudio || TTSCache.containsValidAudio(at: outputURL), "Fixture must be valid audio")
    }
}

final class HTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, String))!
    nonisolated(unsafe) static var hold: ((HTTPStub) -> Bool)?
    nonisolated(unsafe) static var payload: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.hold?(self) == true { return }
        do {
            let (status, body) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload ?? Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    func finish(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [HTTPStub] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    func hold(_ request: HTTPStub) -> Bool {
        lock.lock(); defer { lock.unlock() }
        held.append(request)
        return true
    }
    func finish(_ body: (URLRequest) -> String) {
        lock.lock(); let requests = held; held = []; lock.unlock()
        for request in requests { request.finish(body(request.request)) }
    }
}

@main
struct RefactorChecks {
    @MainActor static func main() async throws {
        try await speechChecks()
        try await browserChecks()
        try await detailChecks()
        try await raceChecks()
        try await settingsChecks()
        try keychainChecks()
        try tokenChecks()
        print("Refactor checks passed: TTS fallback/cache/cancellation, list routing, playlist edits, detail refresh, settings and Keychain")
    }

    @MainActor static func speechChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edge = SpeechStub(), paid = SpeechStub()
        let synthesis = TTSCoordinator(edge: edge, openRouter: paid, cacheDirectory: directory)
        func request(_ text: String, model: TTSModelID = .minimaxTurbo) -> TTSSynthesisRequest {
            TTSSynthesisRequest(model: model, voiceID: model.defaultVoiceID, text: text, speechRate: 1, expression: .automatic)
        }
        let first = try await synthesis.audio(for: request("cached"), credential: "test")
        assert(TTSCache.containsValidAudio(at: first.url))
        _ = try await synthesis.audio(for: request("cached"), credential: nil)
        assert(paid.requests.count == 1 && edge.requests.isEmpty)
        assert(synthesis.cachedAudio(for: request("cached"), hasCredential: false) == first.url)

        let missing = try await synthesis.audio(for: request("missing"), credential: nil)
        assert(missing.notice != nil && edge.requests.count == 1)
        let repeated = try await synthesis.audio(for: request("missing-again"), credential: "")
        assert(repeated.notice == nil)
        assert(synthesis.cachedAudio(for: request("missing"), hasCredential: false) == missing.url)
        assert(synthesis.cachedAudio(for: request("missing"), hasCredential: true) == nil,
               "A usable paid provider must still prefetch when only Edge audio is cached")
        assert(synthesis.cachedAudio(for: request("unknown"), hasCredential: false) == nil)

        paid.failures = [TTSSynthesisError.rateLimited]
        _ = try await synthesis.audio(for: request("retry"), credential: "test")
        assert(paid.requests.filter { $0.text == "retry" }.count == 2)

        paid.failures = [TTSSynthesisError.invalidCredential]
        _ = try await synthesis.audio(for: request("invalid"), credential: "test")
        let count = paid.requests.count
        _ = try await synthesis.audio(for: request("circuit"), credential: "test")
        assert(paid.requests.count == count)
        synthesis.reset()
        _ = try await synthesis.audio(for: request("reset"), credential: "test")
        assert(paid.requests.count == count + 1)

        for i in 0..<3 {
            paid.failures = [TTSSynthesisError.timeout, TTSSynthesisError.transport]
            _ = try await synthesis.audio(for: request("transient-\(i)"), credential: "test")
        }
        let failedCount = paid.requests.count
        _ = try await synthesis.audio(for: request("after-transient"), credential: "test")
        assert(paid.requests.count == failedCount)
        synthesis.reset()
        paid.failures = [TTSSynthesisError.invalidVoice]
        _ = try await synthesis.audio(for: request("configuration"), credential: "test")
        paid.failures = [URLError(.timedOut), URLError(.timedOut)]
        _ = try await synthesis.audio(for: request("transport"), credential: "test")
        paid.failures = [CancellationError()]
        do {
            _ = try await synthesis.audio(for: request("cancelled"), credential: "test")
            assertionFailure("Cancellation must not trigger fallback")
        } catch is CancellationError {}

        edge.invalidAudio = true
        do {
            _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil)
            assertionFailure("Invalid audio must not be cached")
        } catch let error as TTSSynthesisError { assert(error == .invalidResponse) }
        assert(synthesis.cachedAudio(for: request("invalid-audio", model: .edge), hasCredential: false) == nil)
        edge.invalidAudio = false
        _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil)
        let edgeCount = edge.requests.count
        _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil)
        assert(edge.requests.count == edgeCount)
        paid.shouldSuspend = true
        let old = Task { try await synthesis.audio(for: request("old-session"), credential: "test") }
        try await waitUntil { paid.pending != nil }
        synthesis.reset()
        paid.pending?.resume(); paid.pending = nil
        do { _ = try await old.value; assertionFailure("Old session must be cancelled") }
        catch is CancellationError {}
        paid.shouldSuspend = false
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await synthesis.audio(for: request("cancelled-before-cache"), credential: nil)
        }
        do { _ = try await cancelled.value; assertionFailure("Cancelled request must fail") }
        catch is CancellationError {}
    }

    enum CheckError: Error { case timedOut }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckError.timedOut
    }

    static func client() -> ASMRClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return ASMRClient(session: URLSession(configuration: configuration))
    }

    static let workJSON = #"{"id":1,"title":"晚安","name":"Wisimi","dl_count":1,"has_subtitle":true,"tags":[],"vas":[]}"#
    static let worksJSON = #"{"works":[{"id":1,"title":"晚安","name":"Wisimi","has_subtitle":true,"tags":[],"vas":[]}],"pagination":{"currentPage":1,"pageSize":12,"totalCount":24}}"#
    static let playlistJSON = #"{"id":"p1","name":"睡前","privacy":0,"description":"","worksCount":0}"#
    static let playlistsJSON = #"{"playlists":[{"id":"p1","name":"睡前","privacy":0,"description":"","worksCount":0}],"pagination":{"currentPage":1,"pageSize":20,"totalCount":1}}"#

    @MainActor static func browserChecks() async throws {
        WorksFilterContextSelfCheck.run()
        WorksNavigationSelfCheck.run()
        for mode in WorksMode.allCases {
            assert(mode.id == mode.rawValue && !mode.title.isEmpty && !mode.systemImage.isEmpty)
            assert(mode.requiresLogin == [.favorites, .playlists, .recommended].contains(mode))
        }
        let catalog = PlaylistCatalog(client: client())
        let browser = WorksBrowserState(client: client(), catalog: catalog)
        var lastPath = ""
        HTTPStub.respond = { request in
            lastPath = request.url!.path
            if lastPath.hasSuffix("get-playlists") { return (200, playlistsJSON) }
            return (200, worksJSON)
        }
        await browser.load(page: 1, token: nil, recommenderUUID: nil)
        assert(lastPath.hasSuffix("/works") && browser.page.works.count == 1)
        browser.mode = .popular
        await browser.reload(token: nil, recommenderUUID: nil)
        assert(lastPath.hasSuffix("/popular"))
        browser.mode = .favorites
        await browser.reload(token: nil, recommenderUUID: nil)
        assert(browser.page.errorMessage != nil)
        await browser.load(page: 1, token: "test", recommenderUUID: nil)
        assert(lastPath.hasSuffix("/review"))
        browser.keyword = "hello"
        assert(browser.filterContext == .works)
        await browser.reload(token: nil, recommenderUUID: nil)
        assert(lastPath.hasSuffix("/search/hello"))
        browser.keyword = ""
        browser.mode = .recommended
        await browser.reload(token: "test", recommenderUUID: nil)
        assert(browser.page.errorMessage != nil)
        await browser.load(page: 1, token: "test", recommenderUUID: "uuid")
        assert(lastPath.hasSuffix("/recommend-for-user"))
        browser.mode = .playlists
        assert(browser.filterContext == .playlists)
        await browser.reload(token: "test", recommenderUUID: nil)
        assert(catalog.selectedID == "p1" && lastPath.hasSuffix("/get-playlist-works"))
        _ = try await catalog.ensureSelection(token: "test")
        HTTPStub.respond = { request in
            if request.url!.path.hasSuffix("delete-playlist") { return (200, #"{"id":"p1"}"#) }
            return (200, playlistJSON)
        }
        _ = try await catalog.save(id: nil, name: "睡前", privacy: 0, description: "", token: "test")
        _ = try await catalog.save(id: "p1", name: "睡前", privacy: 0, description: "", token: "test")
        assert(catalog.playlists.count == 1 && catalog.selectedPlaylist?.id == "p1")
        try await catalog.delete(id: "p1", token: "test")
        assert(catalog.playlists.isEmpty && catalog.selectedID == nil)
        HTTPStub.respond = { _ in (200, #"{"playlists":[],"pagination":{"currentPage":1,"pageSize":20,"totalCount":0}}"#) }
        do { _ = try await catalog.ensureSelection(token: "test"); assertionFailure("Empty catalog must report no playlists") }
        catch { assert(error is ASMRClientError) }
        catalog.reset()
        assert(catalog.selectedPlaylist == nil)
        await browser.load(page: 0, token: nil, recommenderUUID: nil)
        HTTPStub.respond = { _ in (500, "") }
        browser.mode = .latest
        await browser.reload(token: nil, recommenderUUID: nil)
        assert(browser.page.errorMessage != nil && !browser.page.isLoading)
    }

    @MainActor static func detailChecks() async throws {
        let detail = WorkDetailPageState(client: client(), cachedWork: { _ in nil })
        HTTPStub.respond = { request in
            (200, request.url!.path.contains("/tracks/") ? #"[{"type":"folder","title":"root","hash":"root","children":[]}]"# : workJSON)
        }
        await detail.load(workID: 1, token: nil)
        assert(detail.work?.id == 1 && detail.currentPath.first?.id == "root" && !detail.isLoading)
        detail.isPathMenuExpanded = true
        await detail.load(workID: 1, token: nil, force: true)
        assert(detail.currentPath.first?.id == "root" && detail.isPathMenuExpanded)
        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        await detail.load(workID: 1, token: nil) // Already loaded: no request.
        assert(detail.errorMessage == nil)
        await detail.load(workID: 1, token: nil, force: true)
        assert(detail.errorMessage != nil && detail.work?.id == 1)
        await detail.mark(.listening, token: "test")
        assert(detail.markMessage != nil && !detail.isUpdatingMark)
        HTTPStub.respond = { request in
            (200, request.url!.path.hasSuffix("review") ? "{}" : request.url!.path.contains("/tracks/") ? "[]" : workJSON)
        }
        await detail.mark(.listening, token: "test")
        assert(detail.markMessage == nil)
        await detail.mark(nil, token: "test")
        assert(detail.markMessage == nil)
        await detail.load(workID: 2, token: nil, force: true)
        assert(detail.currentPath.isEmpty && !detail.isPathMenuExpanded)
    }

    @MainActor static func raceChecks() async throws {
        let gate = RequestGate()
        HTTPStub.hold = { request in request.request.url!.path.contains("/1") ? gate.hold(request) : false }
        HTTPStub.respond = { request in (200, request.url!.path.contains("/tracks/") ? "[]" : workJSON.replacingOccurrences(of: "\"id\":1", with: "\"id\":2")) }
        let detail = WorkDetailPageState(client: client(), cachedWork: { _ in nil })
        let old = Task { await detail.load(workID: 1, token: nil) }
        try await waitUntil { gate.count >= 2 }
        await detail.load(workID: 2, token: nil)
        gate.finish { request in request.url!.path.contains("/tracks/") ? "[]" : workJSON }
        await old.value
        assert(detail.work?.id == 2 && detail.errorMessage == nil && !detail.isLoading)
        HTTPStub.hold = nil

        HTTPStub.respond = { request in (200, request.url!.path.contains("/tracks/") ? "[]" : workJSON) }
        let marked = WorkDetailPageState(client: client(), cachedWork: { _ in nil })
        await marked.load(workID: 1, token: "test")
        HTTPStub.hold = { request in request.request.url!.path.hasSuffix("/review") ? gate.hold(request) : false }
        let marking = Task { await marked.mark(.listening, token: "test") }
        try await waitUntil { gate.count > 0 }
        await marked.load(workID: 1, token: "test", force: true)
        HTTPStub.respond = { _ in (200, workJSON.replacingOccurrences(of: "\"tags\":[]", with: "\"progress\":\"listening\",\"tags\":[]")) }
        gate.finish { _ in "{}" }
        await marking.value
        assert(marked.work?.progress == .listening, "Refresh must not discard the completed mark")
        HTTPStub.hold = nil

        HTTPStub.hold = { gate.hold($0) }
        let staleRefresh = Task { await marked.load(workID: 1, token: "test", force: true) }
        try await waitUntil { gate.count >= 2 }
        HTTPStub.hold = nil
        await marked.mark(.listening, token: "test")
        gate.finish { request in request.url!.path.contains("/tracks/") ? "[]" : workJSON }
        await staleRefresh.value
        assert(marked.work?.progress == .listening, "Old refresh must not overwrite a completed mark")

        HTTPStub.hold = { request in request.request.url!.path.hasSuffix("/review") ? gate.hold(request) : false }
        let oldAccountMark = Task { await marked.mark(.listening, token: "test") }
        try await waitUntil { gate.count > 0 }
        HTTPStub.respond = { request in (200, request.url!.path.contains("/tracks/") ? "[]" : workJSON) }
        await marked.load(workID: 1, token: nil, force: true)
        HTTPStub.respond = { _ in (200, workJSON.replacingOccurrences(of: "\"tags\":[]", with: "\"progress\":\"listening\",\"tags\":[]")) }
        gate.finish { _ in "{}" }
        await oldAccountMark.value
        assert(marked.work?.progress == nil, "Old account must not write back after logout")
        HTTPStub.hold = nil

        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        let work = try JSONDecoder().decode(WorkDetail.self, from: Data(workJSON.utf8))
        let cached = WorkDetailPageState(client: client(), cachedWork: { _ in DownloadedWork(work: work, tracks: []) })
        await cached.load(workID: 1, token: nil)
        assert(cached.work?.id == 1 && cached.errorMessage != nil)

        HTTPStub.hold = { gate.hold($0) }
        let catalog = PlaylistCatalog(client: client())
        let save = Task { try await catalog.save(id: nil, name: "old-user", privacy: 0, description: "", token: "test") }
        try await waitUntil { gate.count > 0 }
        catalog.reset()
        gate.finish { _ in playlistJSON }
        do { _ = try await save.value; assertionFailure("Logout must invalidate pending catalog edits") }
        catch is CancellationError {}
        assert(catalog.playlists.isEmpty)
        HTTPStub.hold = nil
    }

    @MainActor static func settingsChecks() async throws {
        let suite = "RefactorSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TTSMixSettings(defaults: defaults)
        var changes: [TTSSynthesisRequest] = []
        let subscription = settings.$configuration.dropFirst().sink { changes.append($0.request(text: "test")) }
        settings.model = .minimaxHD
        assert(changes.count == 1 && changes[0].normalizedVoiceID == TTSModelID.minimaxHD.defaultVoiceID)
        settings.maxSpeechRate = 9
        assert(settings.maxSpeechRate == 2)
        settings.inlineEffectPreset = .breath
        settings.model = .geminiFlashPreview
        assert(settings.maxSpeechRate == 1 && settings.inlineEffectPreset == .automatic)
        assert(changes.last?.voiceID == TTSModelID.geminiFlashPreview.defaultVoiceID)
        let count = changes.count
        settings.maxSpeechRate = 9 // Normalizes to same effective configuration.
        assert(changes.count == count)
        settings.volume = -1
        assert(settings.volume == 0)
        settings.isEnabled = true
        let restored = TTSMixSettings(defaults: defaults)
        assert(restored.configuration == settings.configuration && restored.isEnabled && restored.volume == 0)
        TTSMixSettingsSelfCheck.run()
        TTSModelsSelfCheck.run()
        OpenRouterTTSSelfCheck.run()
        EdgeOnlineTTSSelfCheck.run()

        let tokenStore = OpenRouterTokenStore(service: "wisimi.refactor-token.\(UUID().uuidString)")
        defer { try? tokenStore.delete() }
        let http = URLSessionConfiguration.ephemeral
        http.protocolClasses = [HTTPStub.self]
        let connection = TTSMixSettings(defaults: defaults, tokenStore: tokenStore,
            openRouterClient: OpenRouterTTSClient(session: URLSession(configuration: http)))
        await connection.testOpenRouterConnection()
        if case .failure = connection.connectionTestState {} else { assertionFailure("Missing credentials must fail") }
        connection.model = .edge
        HTTPStub.respond = { _ in (200, "") }
        HTTPStub.payload = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/silence.mp3"))
        await connection.testOpenRouterConnection(candidateToken: " test ")
        assert(connection.isOpenRouterConfigured && connection.model == .minimaxTurbo)
        let savedToken = try tokenStore.load()
        assert(savedToken == "test")
        await connection.testOpenRouterConnection()
        if case .success = connection.connectionTestState {} else { assertionFailure("Valid audio must pass connection test") }
        HTTPStub.payload = nil
        HTTPStub.respond = { _ in (401, "") }
        await connection.testOpenRouterConnection(candidateToken: "invalid")
        if case .failure = connection.connectionTestState {} else { assertionFailure("Invalid credentials must fail") }
        connection.deleteOpenRouterToken()
        assert(!connection.isOpenRouterConfigured && connection.model == .edge && connection.connectionTestState == .idle)
        withExtendedLifetime(subscription) {}
    }

    static func keychainChecks() throws {
        let store = KeychainItem(service: "wisimi.refactor.\(UUID().uuidString)", account: "test")
        defer { try? store.delete() }
        let empty = try store.load()
        assert(empty == nil)
        try store.save(Data("first".utf8))
        try store.save(Data("second".utf8))
        let loaded = try store.load()
        assert(loaded == Data("second".utf8))
        try store.delete()
        try store.delete()
        let deleted = try store.load()
        assert(deleted == nil)
        let restricted = KeychainItem(service: store.service, account: store.account,
                                      accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, synchronizable: false)
        try restricted.save(Data("retained".utf8))
        var failure: OSStatus = errSecAuthFailed
        let operations = KeychainOperations(
            read: { _ in (failure, nil) }, update: { _, _ in failure },
            add: { _ in errSecAuthFailed }, delete: { _ in failure }
        )
        let failing = KeychainItem(service: store.service, account: "errors", operations: operations)
        do { _ = try failing.load(); assertionFailure("Read failure must be reported") }
        catch let error as KeychainError { assert(error.errorDescription != nil) }
        do { try failing.save(Data()); assertionFailure("Update failure must be reported") }
        catch let error as KeychainError { assert(error.status == errSecAuthFailed) }
        failure = errSecItemNotFound
        do { try failing.save(Data()); assertionFailure("Add failure must be reported") }
        catch let error as KeychainError { assert(error.status == errSecAuthFailed) }
        failure = errSecAuthFailed
        do { try failing.delete(); assertionFailure("Delete failure must be reported") }
        catch let error as KeychainError { assert(error.status == errSecAuthFailed) }
        let retained = try restricted.load()
        assert(retained == Data("retained".utf8))
    }

    static func tokenChecks() throws {
        OpenRouterTokenStoreSelfCheck.run()
        let service = "wisimi.refactor-token-errors.\(UUID().uuidString)"
        let token = OpenRouterTokenStore(service: service)
        defer { try? token.delete() }
        do { try token.save("  "); assertionFailure("Empty token must fail") }
        catch let error as OpenRouterTokenStoreError { assert(error.errorDescription != nil) }
        let raw = KeychainItem(service: service, account: "api-token", synchronizable: false)
        try raw.save(Data([0xff]))
        do { _ = try token.load(); assertionFailure("Malformed stored token must fail") }
        catch let error as OpenRouterTokenStoreError { assert(error.errorDescription != nil) }
        let failure = KeychainOperations(read: { _ in (errSecAuthFailed, nil) },
            update: { _, _ in errSecAuthFailed }, add: { _ in errSecAuthFailed }, delete: { _ in errSecAuthFailed })
        let failed = OpenRouterTokenStore(service: service, operations: failure)
        do { _ = try failed.load(); assertionFailure("Load error must be mapped") }
        catch let error as OpenRouterTokenStoreError { assert(error.errorDescription != nil) }
        do { try failed.save("test"); assertionFailure("Save error must be mapped") }
        catch let error as OpenRouterTokenStoreError { assert(error.errorDescription != nil) }
        do { try failed.delete(); assertionFailure("Delete error must be mapped") }
        catch let error as OpenRouterTokenStoreError { assert(error.errorDescription != nil) }
    }
}
