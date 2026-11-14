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
        try await localLibraryChecks()
        try await dlsiteMetadataChecks()
        try await similarWorksChecks()
        try await playlistMembershipChecks()
        try await raceChecks()
        try await settingsChecks()
        try keychainChecks()
        try tokenChecks()
        print("Refactor checks passed: TTS, list routing, playlist edits, detail refresh, local library, settings and Keychain")
    }

    @MainActor static func localLibraryChecks() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let original = root.appendingPathComponent("本地作品")
        let storage = root.appendingPathComponent("Library")
        let library = LocalWorkLibrary(directory: storage, requiresSecurityScope: false)
        let source = WorkSource(online: OnlineWorkSource(client: ASMRClient()), library: library)
        let catalog: any WorkCatalog = library
        let emptyPage = try await catalog.page(1, pageSize: 2, refresh: false)
        assert(emptyPage.works.isEmpty && emptyPage.pagination.currentPage == 1)
        for name in ["Track 2", "Track 10"] {
            let folder = original.appendingPathComponent(name)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: URL(fileURLWithPath: "Tests/Fixtures/silence.mp3"), to: folder.appendingPathComponent("01 #雨.mp3"))
            try "[00:00.00]本地字幕".write(to: folder.appendingPathComponent("01 #雨.lrc"), atomically: true, encoding: .utf8)
        }
        let nestedCover = original.appendingPathComponent("Track 2/封面.png")
        try Data([0]).write(to: nestedCover)
        try files.createSymbolicLink(at: original.appendingPathComponent("ignored.mp3"),
                                     withDestinationURL: original.appendingPathComponent("Track 2/01 #雨.mp3"))

        let plan = try await library.inspect(original)
        let plain = try await library.importWork(plan)
        let loaded = try await source.loadWork(.local(plain.id))
        assert(plan.title == "本地作品" && plan.bytes > 0)
        assert(loaded.work.reference == .local(plain.id) && loaded.work.hasSubtitle && loaded.metadataWarning == nil)
        assert(loaded.tracks.map(\.title) == ["Track 2", "Track 10"])
        let firstFolder = loaded.tracks[0].children!
        let firstTrack = firstFolder.playableTracks[0]
        assert(firstTrack.id != loaded.tracks[1].children?.playableTracks[0].id)
        assert(firstTrack.playbackURL?.isFileURL == true && files.fileExists(atPath: firstTrack.playbackURL!.path))
        let subtitle = firstFolder.matchingSubtitle(for: firstTrack)!
        let text = try await source.subtitleText(at: subtitle.downloadSourceURL!)
        assert(text == "[00:00.00]本地字幕")

        let metadataURL = original.appendingPathComponent("wisimi.json")
        try Data(#"{"title":"注册标题","circle":"本地社团","duration":120,"rating":4.5,"sales":12,"catalogCode":"TEST-7","tags":["雨声","雨声"],"voiceActors":["测试声优"],"cover":"Track 2/封面.png"}"#.utf8).write(to: metadataURL)
        let registered = try await library.importWork(library.inspect(original))
        let firstPage = try await catalog.page(1, pageSize: 1, refresh: false)
        assert(firstPage.pagination.totalCount == 2 && firstPage.pagination.totalPages == 2)
        assert(firstPage.works.map(\.id) == [.local(registered.id)])
        assert(firstPage.works.first?.tags.map(\.name) == ["雨声"])
        let secondPage = try await catalog.page(2, pageSize: 1, refresh: false)
        assert(secondPage.works.map(\.id) == [.local(plain.id)])
        let reopened = LocalWorkLibrary(directory: storage, requiresSecurityScope: false)
        let saved = try await reopened.loadWork(registered.id)
        assert(saved.work.title == "注册标题" && saved.work.circle == "本地社团")
        assert(saved.work.rating == 4.5 && saved.work.duration == 120 && saved.work.sales == 12 && saved.work.catalogCode == "TEST-7")
        assert(saved.work.tags.map(\.name) == ["雨声"] && saved.work.voiceActors.map(\.name) == ["测试声优"])
        assert(saved.work.coverURL?.lastPathComponent == "封面.png" && files.fileExists(atPath: saved.work.coverURL!.path))

        try Data(#"{"cover":"../外部.png"}"#.utf8).write(to: metadataURL)
        let unsafe = try await library.importWork(library.inspect(original))
        let unsafeWork = try await library.loadWork(unsafe.id)
        assert(unsafeWork.work.coverURL == nil && unsafeWork.metadataWarning != nil)
        try Data("{".utf8).write(to: metadataURL)
        let malformed = try await library.importWork(library.inspect(original))
        assert(malformed.title == "本地作品" && malformed.metadataWarning != nil && malformed.hasSubtitle)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await library.importWork(plan)
        }
        do { _ = try await cancelled.value; assertionFailure("Cancelled import published a work") }
        catch is CancellationError {}

        let empty = root.appendingPathComponent("empty")
        try files.createDirectory(at: empty, withIntermediateDirectories: true)
        let failed = try? await library.inspect(empty)
        assert(failed == nil)
        try await library.remove(plain.id)
        let remaining = try await catalog.page(4, pageSize: 1, refresh: false)
        assert(remaining.pagination.currentPage == 3 && remaining.pagination.totalCount == 3)
        assert(remaining.works.map(\.id) == [.local(registered.id)])
        assert(files.fileExists(atPath: nestedCover.path) && files.fileExists(atPath: metadataURL.path))
        let storedDirectories = try files.contentsOfDirectory(atPath: storage.path)
        assert(storedDirectories.allSatisfy { UUID(uuidString: $0) != nil })

        let broken = storage.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("index.json"))
        let reloaded = try await reopened.page(1, pageSize: 12, refresh: true)
        assert(reloaded.unreadableCount == 1)
        assert(Set(reloaded.works.map(\.id)) == [.local(registered.id), .local(unsafe.id), .local(malformed.id)])
    }

    @MainActor static func dlsiteMetadataChecks() async throws {
        assert(RJCodeExtractor.extract(from: "RJ01649840") == "RJ01649840")
        assert(RJCodeExtractor.extract(from: "rj123456") == "RJ123456")
        assert(RJCodeExtractor.extract(from: "【中文版】[RJ12345678] 作品标题 (CV.测试)") == "RJ12345678")
        assert(RJCodeExtractor.extract(from: "prefix_rj1_suffix") == "RJ1")
        assert(RJCodeExtractor.extract(from: "TRJ123456") == nil)
        assert(RJCodeExtractor.extract(from: "RJ123456789") == nil)
        assert(RJCodeExtractor.extract(from: "纯本地作品无编号") == nil)

        let productJSON = Data(#"[{"workno":"RJ01649840","work_name":"测试标题","maker_name":"みんなで翻訳","genres":[{"name":"魔女"},{"name":"魔女"}],"creaters":{"voice_by":[{"name":"大山チロル"}]},"translation_info":{"original_workno":"RJ01631266"},"image_main":{"url":"//img.dlsite.jp/test/cover.jpg"}}]"#.utf8)
        let parsedProduct = try DLsiteMetadataClient.parseProductJSON(productJSON)
        assert(parsedProduct.workno == "RJ01649840" && parsedProduct.translationInfo?.originalWorkno == "RJ01631266")
        assert(DLsiteMetadataClient.resolveImageURL(parsedProduct.imageMain?.url)?.absoluteString == "https://img.dlsite.jp/test/cover.jpg")
        let ajaxJSON = Data(#"{"RJ01649840":{"dl_count":27,"rate_average_2dp":4.78}}"#.utf8)
        let parsedAjax = try DLsiteMetadataClient.parseAjaxJSON(ajaxJSON, for: "RJ01649840")
        assert(parsedAjax.dlCount == 27 && parsedAjax.rateAverage2dp == 4.78)

        final class DLsiteStub: DLsiteMetadataFetching, @unchecked Sendable {
            var fetchedCodes: [String] = []
            func fetchMetadata(for rjCode: String) async throws -> DLsiteMetadataResult {
                fetchedCodes.append(rjCode)
                if rjCode == "RJ99999999" { throw DLsiteMetadataError.notFound }
                return DLsiteMetadataResult(
                    metadata: LocalWorkMetadata(
                        title: "DLsite 标题", circle: "原社团", duration: nil, rating: 4.78, sales: 27,
                        catalogCode: rjCode, tags: ["标签A"], voiceActors: ["声优A"], cover: nil
                    ),
                    coverURL: URL(string: "https://img.dlsite.jp/test/cover.jpg")
                )
            }
            func downloadCover(from url: URL) async throws -> Data { Data([0xFF, 0xD8, 0xFF, 0xD9]) }
        }

        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("【汉化】rj01649840_测试作品")
        let notFoundSource = root.appendingPathComponent("RJ99999999_不存在")
        let storage = root.appendingPathComponent("Storage")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: notFoundSource, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source.appendingPathComponent("01.mp3"))
        try Data("audio".utf8).write(to: notFoundSource.appendingPathComponent("01.mp3"))

        let stub = DLsiteStub()
        let library = LocalWorkLibrary(directory: storage, requiresSecurityScope: false, dlsiteClient: stub)
        let imported = try await library.importWork(library.inspect(source))
        let missing = try await library.importWork(library.inspect(notFoundSource))
        assert(imported.needsDLsiteSync && missing.needsDLsiteSync)
        let didSync = await library.syncPendingDLsiteMetadataIfNeeded()
        assert(didSync && Set(stub.fetchedCodes) == ["RJ01649840", "RJ99999999"] && stub.fetchedCodes.count == 2)

        let savedJSON = library.contentDirectory(for: imported.id).appendingPathComponent("wisimi.json")
        assert(files.fileExists(atPath: savedJSON.path))
        let decodedJSON = try JSONDecoder().decode(LocalWorkMetadata.self, from: Data(contentsOf: savedJSON))
        assert(decodedJSON.title == "DLsite 标题" && decodedJSON.circle == "原社团" && decodedJSON.cover == "cover.jpg")
        assert(decodedJSON.sales == 27 && decodedJSON.rating == 4.78 && decodedJSON.catalogCode == "RJ01649840")

        let loaded = try await library.loadWork(imported.id)
        assert(loaded.work.title == "DLsite 标题" && loaded.work.coverURL?.lastPathComponent == "cover.jpg")

        let restarted = LocalWorkLibrary(directory: storage, requiresSecurityScope: false, dlsiteClient: stub)
        let didSyncAfterRestart = await restarted.syncPendingDLsiteMetadataIfNeeded()
        assert(!didSyncAfterRestart && stub.fetchedCodes.count == 2)
        let missingLoaded = try await restarted.loadWork(missing.id)
        assert(missingLoaded.work.title == "RJ99999999_不存在")

        let existingSource = root.appendingPathComponent("RJ01753619_自带元数据")
        try files.createDirectory(at: existingSource, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: existingSource.appendingPathComponent("01.mp3"))
        try Data(#"{"title":"本地自定义标题","catalogCode":"RJ01753619"}"#.utf8)
            .write(to: existingSource.appendingPathComponent("wisimi.json"))
        let existingEntry = try await restarted.importWork(restarted.inspect(existingSource))
        assert(!existingEntry.needsDLsiteSync)
        let didSyncExisting = await restarted.syncPendingDLsiteMetadataIfNeeded()
        assert(!didSyncExisting && stub.fetchedCodes.count == 2)

        let httpConfig = URLSessionConfiguration.ephemeral
        httpConfig.protocolClasses = [HTTPStub.self]
        let stubClient = DLsiteMetadataClient(session: URLSession(configuration: httpConfig))
        defer {
            HTTPStub.respond = nil
            HTTPStub.payload = nil
            HTTPStub.hold = nil
        }
        HTTPStub.respond = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("workno=RJ01649840") {
                return (200, #"[{"workno":"RJ01649840","work_name":"翻译标题","maker_name":"みんなで翻訳","genres":[{"name":"魔女"}],"creaters":{"voice_by":[{"name":"大山チロル"}]},"translation_info":{"original_workno":"RJ01631266"},"image_main":{"url":"//img.dlsite.jp/test/RJ01631266_img_main.jpg"}}]"#)
            }
            if url.contains("workno=RJ01631266") {
                return (200, #"[{"workno":"RJ01631266","maker_name":"愛毒レース"}]"#)
            }
            if url.contains("product_id=RJ01649840") {
                return (200, #"{"RJ01649840":{"dl_count":27,"rate_average_2dp":4.78}}"#)
            }
            return (404, "[]")
        }
        let fetched = try await stubClient.fetchMetadata(for: "RJ01649840")
        assert(fetched.metadata.title == "翻译标题" && fetched.metadata.circle == "愛毒レース")
        assert(fetched.metadata.sales == 27 && fetched.metadata.rating == 4.78)
        assert(fetched.coverURL?.absoluteString == "https://img.dlsite.jp/test/RJ01631266_img_main.jpg")

        HTTPStub.payload = Data([0xFF, 0xD8, 0xFF, 0xD9])
        HTTPStub.respond = { _ in (200, "") }
        let coverBytes = try await stubClient.downloadCover(from: fetched.coverURL!)
        assert(coverBytes == Data([0xFF, 0xD8, 0xFF, 0xD9]))

        HTTPStub.payload = nil
        HTTPStub.respond = { _ in (200, "<html>error</html>") }
        do {
            _ = try await stubClient.downloadCover(from: fetched.coverURL!)
            assertionFailure("HTML payload must be rejected for cover download")
        } catch let error as DLsiteMetadataError {
            assert(error == .invalidResponse)
        }

        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await stubClient.fetchMetadata(for: "RJ01649840")
            assertionFailure("URLError should propagate")
        } catch let error as URLError {
            assert(error.code == .notConnectedToInternet)
        }
    }

    @MainActor static func speechChecks() async throws {
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
        assert(paid.requests.count == 1, "Current subtitle must reuse in-flight prefetch")
        paid.pending?.resume(); paid.pending = nil
        let prefetched = try await prefetch.value
        let playing = try await current.value
        assert(prefetched.url == playing.url)
        paid.shouldSuspend = false
        paid.requests = []
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
        let attempts = edge.requests.count
        for _ in 0..<5 {
            do { _ = try await synthesis.audio(for: request("invalid-audio", model: .edge), credential: nil) }
            catch let error as TTSSynthesisError { assert(error == .invalidResponse) }
        }
        assert(edge.requests.count == attempts, "Failed sentence must wait for explicit retry")
        synthesis.reset()
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
        assert(synthesis.cachedAudio(for: request("old-session"), hasCredential: true) == nil,
               "Cancelled session must not publish generated audio into the cache")
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

    static let mutationJSON = #"{"id":"p1","rowCount":1}"#

    static func membershipJSON(page: Int, exist: Bool = false, count: Int = 2) -> String {
        #"{"playlists":[{"id":"p\#(page)","name":"睡前","privacy":0,"description":"","works_count":\#(count),"exist":\#(exist)}],"pagination":{"currentPage":\#(page),"pageSize":12,"totalCount":24}}"#
    }

    @MainActor static func playlistMembershipChecks() async throws {
        let state = PlaylistMembershipState(workID: 1, client: client())
        HTTPStub.respond = { _ in (200, membershipJSON(page: 1)) }
        await state.load(page: 1, token: "test")
        assert(state.playlists.first?.id == "p1" && state.pagination?.totalPages == 2 && !state.isLoading)

        // 乐观更新成功后保留，失败时回滚并给出错误。
        HTTPStub.respond = { _ in (200, mutationJSON) }
        await state.toggle(state.playlists[0], token: "test")
        assert(state.playlists[0].exist && state.playlists[0].worksCount == 3 && state.updatingIDs.isEmpty)
        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        await state.toggle(state.playlists[0], token: "test")
        assert(state.playlists[0].exist && state.playlists[0].worksCount == 3)
        assert(state.errorMessage == URLError(.notConnectedToInternet).userFacingMessage)
        let decodingFailure = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        assert(decodingFailure.userFacingMessage == "服务器返回的数据无法识别，请稍后重试")
        HTTPStub.respond = { _ in (200, mutationJSON) }
        await state.toggle(state.playlists[0], token: "test")
        assert(!state.playlists[0].exist && state.errorMessage == nil)

        // 加载失败保留已有内容和页码。
        HTTPStub.respond = { _ in throw URLError(.timedOut) }
        await state.load(page: 2, token: "test")
        assert(state.errorMessage != nil && state.currentPage == 1 && state.playlists.first?.id == "p1" && !state.isLoading)

        // 关闭弹层取消请求时不显示错误，也不残留加载状态。
        let gate = RequestGate()
        HTTPStub.hold = { gate.hold($0) }
        let cancelled = PlaylistMembershipState(workID: 1, client: client())
        let load = Task { await cancelled.load(page: 1, token: "test") }
        try await waitUntil { gate.count > 0 }
        load.cancel()
        await load.value
        assert(cancelled.errorMessage == nil && !cancelled.isLoading && cancelled.playlists.isEmpty)
        gate.finish { _ in "" }

        // 更新的请求不被进行中的请求阻塞，过期响应不会覆盖结果。
        let racing = PlaylistMembershipState(workID: 1, client: client())
        let first = Task { await racing.load(page: 1, token: "test") }
        try await waitUntil { gate.count == 1 }
        let second = Task { await racing.load(page: 2, token: "test") }
        try await waitUntil { gate.count == 2 }
        gate.finish { request in
            membershipJSON(page: request.url!.query?.contains("page=2") == true ? 2 : 1)
        }
        await first.value
        await second.value
        assert(racing.currentPage == 2 && racing.playlists.first?.id == "p2" && !racing.isLoading)
        HTTPStub.hold = nil

        // 同一播放列表更新期间不重复提交。
        var mutations = 0
        let busy = PlaylistMembershipState(workID: 1, client: client())
        HTTPStub.respond = { _ in (200, membershipJSON(page: 1)) }
        await busy.load(page: 1, token: "test")
        HTTPStub.hold = { gate.hold($0) }
        let playlist = busy.playlists[0]
        let toggling = Task { await busy.toggle(playlist, token: "test") }
        try await waitUntil { gate.count == 1 }
        await busy.toggle(playlist, token: "test")
        mutations = gate.count
        gate.finish { _ in mutationJSON }
        await toggling.value
        assert(mutations == 1 && busy.playlists[0].exist)
        HTTPStub.hold = nil
    }

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

    static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func similarResponse(page: Int, ids: [Int], total: Int = 60) -> String {
        let works = ids.map { id in
            ["id": id, "title": "雨声", "name": "电台", "has_subtitle": true, "tags": [], "vas": []] as [String: Any]
        }
        let json: [String: Any] = ["works": works, "pagination": ["currentPage": page, "pageSize": 20, "totalCount": total]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    @MainActor static func similarWorksChecks() async throws {
        let state = SimilarWorksState(workID: 1, client: client())
        var pages: [Int] = []
        var fail = false
        HTTPStub.respond = { request in
            assert(request.url!.path.hasSuffix("recommender/item-neighbors"))
            assert(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
            assert(request.value(forHTTPHeaderField: "User-Agent") == "Wisimi/1.0")
            let body = try requestBody(request)
            assert(body["itemId"] as? String == "1" && body["keyword"] as? String == "")
            assert((body["localSubtitledWorks"] as? [Int]) == [] && (body["withPlaylistStatus"] as? [Int]) == [])
            let page = body["page"] as! Int
            pages.append(page)
            if fail { throw URLError(.notConnectedToInternet) }
            return (200, similarResponse(page: page, ids: page == 1 ? [1, 2, 2, 3, 4, 5, 6] : page == 2 ? [3, 7, 7] : []))
        }
        assert(!state.shouldShowSection)
        await state.loadPage(0)
        await state.loadPage(2) // No first-page metadata yet.
        assert(pages.isEmpty)
        await state.loadIfNeeded()
        assert(state.page.works.map(\.id) == [2, 3, 4, 5, 6])
        assert(state.displayedWorks.map(\.id) == [2, 3, 4, 5] && state.shouldShowSection)
        state.isExpanded = true
        assert(state.displayedWorks.count == 5)
        await state.loadIfNeeded()
        await state.loadPage(1)
        assert(pages == [1])
        fail = true
        await state.loadPage(2)
        assert(state.page.errorMessage != nil && state.page.works.count == 5 && state.page.currentPage == 1)
        fail = false
        await state.retry()
        assert(pages == [1, 2, 2] && state.page.works.map(\.id) == [3, 7] && state.page.currentPage == 2)
        assert(state.page.errorMessage == nil && !state.isRetrying)
        state.isExpanded = false
        assert(state.displayedWorks.map(\.id) == [2, 3, 4, 5])
        state.isExpanded = true
        assert(state.displayedWorks.map(\.id) == [3, 7])
        await state.loadPage(1)
        assert(state.page.works.map(\.id) == [2, 3, 4, 5, 6], "Going back must not remove previously seen works")
        await state.loadPage(3)
        assert(state.page.works.isEmpty && state.shouldShowSection && state.page.currentPage == 3)
        await state.loadPage(4)
        assert(pages == [1, 2, 2, 1, 3])

        let empty = SimilarWorksState(workID: 1, client: client())
        HTTPStub.respond = { _ in (200, similarResponse(page: 1, ids: [], total: 0)) }
        await empty.loadIfNeeded()
        assert(!empty.shouldShowSection && empty.page.pagination != nil)
        let failed = SimilarWorksState(workID: 1, client: client())
        HTTPStub.respond = { _ in (500, "") }
        await failed.loadIfNeeded()
        assert(failed.shouldShowSection && failed.page.errorMessage != nil)
        let gate = RequestGate()
        HTTPStub.hold = { gate.hold($0) }
        let retrying = Task { await failed.retry() }
        try await waitUntil { gate.count == 1 }
        assert(failed.shouldShowSection && failed.isRetrying && failed.page.errorMessage == nil)
        await failed.retry()
        await failed.loadIfNeeded()
        assert(gate.count == 1)
        gate.finish { _ in similarResponse(page: 1, ids: [2]) }
        await retrying.value
        assert(failed.displayedWorks.count == 1 && !failed.isRetrying)
        HTTPStub.hold = nil

        HTTPStub.respond = { _ in (200, similarResponse(page: 1, ids: [2])) }
        let abandoned = SimilarWorksState(workID: 1, client: client())
        await abandoned.loadIfNeeded()
        HTTPStub.hold = { gate.hold($0) }
        let paging = Task { await abandoned.loadPage(2) }
        try await waitUntil { gate.count == 1 }
        paging.cancel()
        await paging.value
        gate.finish { _ in similarResponse(page: 2, ids: [99]) }
        assert(abandoned.page.works.map(\.id) == [2] && abandoned.page.currentPage == 1 && abandoned.page.errorMessage == nil)
        HTTPStub.hold = nil
        HTTPStub.respond = { _ in (200, similarResponse(page: 2, ids: [3])) }
        await abandoned.retry()
        assert(abandoned.page.works.map(\.id) == [3] && abandoned.previewWorks.map(\.id) == [2])
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await abandoned.loadPage(3)
        }
        await preCancelled.value
        assert(abandoned.page.currentPage == 2)
        print("Similar works checks passed: inline preview, page replacement, previous page, empty hiding, retry and cancellation")
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

    @MainActor static func tokenChecks() throws {
        OpenRouterTokenStoreSelfCheck.run()
        let service = "wisimi.refactor-token-errors.\(UUID().uuidString)"
        let token = OpenRouterTokenStore(service: service)
        defer { try? token.delete() }
        var storedAccessibility: CFString?
        var storedValue: Data? = Data("existing-token".utf8)
        let background = OpenRouterTokenStore(service: service, operations: KeychainOperations(
            read: { _ in (errSecSuccess, storedValue) },
            update: { _, attributes in
                storedAccessibility = attributes[kSecAttrAccessible as String] as! CFString?
                storedValue = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            }, add: { _ in errSecSuccess }, delete: { _ in errSecSuccess }))
        try background.prepareForBackgroundAccess()
        assert(storedAccessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        assert(storedValue == Data("existing-token".utf8), "Updating accessibility must retain the token")
        let blockedSettings = TTSMixSettings(tokenStore: OpenRouterTokenStore(operations: KeychainOperations(
            read: { _ in (errSecInteractionNotAllowed, nil) }, update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in errSecInteractionNotAllowed }, delete: { _ in errSecInteractionNotAllowed })))
        do { _ = try blockedSettings.openRouterToken(); assertionFailure("Locked Keychain must not be treated as missing token") }
        catch let error as OpenRouterTokenStoreError { assert(error.errorDescription != nil) }
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
