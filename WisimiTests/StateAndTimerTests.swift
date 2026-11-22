import Foundation
import Testing
@testable import Wisimi

@Suite("State, Navigation, and Timers", .serialized)
@MainActor
struct StateAndTimerTests {
    private static let workJSON = #"{"id":1,"title":"晚安","name":"Wisimi","dl_count":1,"has_subtitle":true,"tags":[],"vas":[]}"#
    private static let worksJSON = #"{"works":[{"id":1,"title":"晚安","name":"Wisimi","has_subtitle":true,"tags":[],"vas":[]}],"pagination":{"currentPage":1,"pageSize":12,"totalCount":24}}"#
    private static let playlistJSON = #"{"id":"p1","name":"睡前","privacy":0,"description":"","worksCount":0}"#
    private static let playlistsJSON = #"{"playlists":[{"id":"p1","name":"睡前","privacy":0,"description":"","worksCount":0}],"pagination":{"currentPage":1,"pageSize":20,"totalCount":1}}"#
    private static let mutationJSON = #"{"id":"p1","rowCount":1}"#

    private static func membershipJSON(page: Int, exist: Bool = false, count: Int = 2) -> String {
        #"{"playlists":[{"id":"p\#(page)","name":"睡前","privacy":0,"description":"","works_count":\#(count),"exist":\#(exist)}],"pagination":{"currentPage":\#(page),"pageSize":12,"totalCount":24}}"#
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
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
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func similarResponse(page: Int, ids: [Int], total: Int = 60) -> String {
        let works = ids.map { id in
            ["id": id, "title": "雨声", "name": "电台", "has_subtitle": true, "tags": [], "vas": []] as [String: Any]
        }
        let json: [String: Any] = ["works": works, "pagination": ["currentPage": page, "pageSize": 20, "totalCount": total]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    @Test func playbackStateTransitions() {
        var state = PlaybackState.paused.receiving(.play)
        #expect(state == .preparing && state.wantsPlayback)
        state = state.receiving(.pause).receiving(.outputStarted)
        #expect(state == .paused)
        state = state.receiving(.play).receiving(.pause).receiving(.play)
        #expect(state.wantsPlayback)
        state = state.receiving(.outputStarted)
        #expect(state == .playing)
        #expect(state.receiving(.waiting) == .preparing)
        #expect(PlaybackState.paused.receiving(.waiting) == .paused)
        for event in [PlaybackState.Event.pause, .activationFailed, .ended, .failed] {
            #expect(state.receiving(event) == .paused)
        }
    }

    @Test func sleepTimerExpiration() {
        let deadline = Date(timeIntervalSince1970: 100)
        let timer = SleepTimer.deadline(deadline)
        #expect(!timer.hasExpired(at: deadline.addingTimeInterval(-1)))
        #expect(timer.hasExpired(at: deadline))
        #expect(timer.hasExpired(at: deadline.addingTimeInterval(1)))
        #expect(!SleepTimer.off.hasExpired(at: deadline))
        #expect(!SleepTimer.endOfTrack.hasExpired(at: deadline))
    }

    @Test func worksPageStateRequestRaces() async throws {
        let state = WorksPageState()
        let json = #"{"id":2,"title":"new search","name":"circle","has_subtitle":true,"tags":[],"vas":[]}"#
        let work = try JSONDecoder().decode(WorkSummary.self, from: Data(json.utf8))
        let response = WorksResponse(works: [work], pagination: WorksPagination(currentPage: 2, pageSize: 12, totalCount: 36))
        var oldRequest: CheckedContinuation<WorksResponse, Error>?
        let old = Task {
            await state.loadWorks(page: 1) {
                try await withCheckedThrowingContinuation { oldRequest = $0 }
            }
        }
        while oldRequest == nil { await Task.yield() }
        await state.loadWorks(page: 2) { response }
        oldRequest?.resume(returning: WorksResponse(works: [], pagination: WorksPagination(currentPage: 1, pageSize: 12, totalCount: 12)))
        await old.value
        #expect(state.works.first?.id == 2 && state.currentPage == 2 && state.pagination?.totalCount == 36 && !state.isLoading)

        oldRequest = nil
        let failedOld = Task {
            await state.loadWorks(page: 1) {
                try await withCheckedThrowingContinuation { oldRequest = $0 }
            }
        }
        while oldRequest == nil { await Task.yield() }
        await state.loadWorks(page: 2) { response }
        oldRequest?.resume(throwing: URLError(.timedOut))
        await failedOld.value
        #expect(state.errorMessage == nil && state.currentPage == 2)

        await state.loadWorks(page: 3) { throw URLError(.notConnectedToInternet) }
        #expect(state.errorMessage == "网络未连接，请检查网络后重试" && state.works.first?.id == 2 && state.currentPage == 2 && state.requestedPage == 3)
        await state.loadWorks(page: state.requestedPage) { response }
        #expect(state.errorMessage == nil && !state.isLoading)

        oldRequest = nil
        let resetOld = Task {
            await state.loadWorks(page: 1) {
                try await withCheckedThrowingContinuation { oldRequest = $0 }
            }
        }
        while oldRequest == nil { await Task.yield() }
        state.reset()
        oldRequest?.resume(returning: response)
        await resetOld.value
        #expect(state.pagination == nil && state.works.isEmpty && state.currentPage == 1)
    }

    @Test func worksBrowserAndPlaylistCatalog() async throws {
        defer { HTTPStub.reset() }
        for mode in WorksMode.allCases {
            #expect(mode.id == mode.rawValue && !mode.title.isEmpty && !mode.systemImage.isEmpty)
            #expect(mode.requiresLogin == [.favorites, .playlists, .recommended].contains(mode))
        }
        let catalog = PlaylistCatalog(client: makeStubClient())
        let browser = WorksBrowserState(client: makeStubClient(), catalog: catalog)
        var lastPath = ""
        HTTPStub.respond = { request in
            lastPath = request.url!.path
            if lastPath.hasSuffix("get-playlists") { return (200, Self.playlistsJSON) }
            return (200, Self.worksJSON)
        }
        await browser.load(page: 1, token: nil, recommenderUUID: nil)
        #expect(lastPath.hasSuffix("/works") && browser.page.works.count == 1)
        #expect(browser.summaryText == "共 24 部")
        browser.filter.hasSubtitle = true
        browser.filter.order = .dlCount
        #expect(browser.summaryText == "有字幕 · 销量 降序 · 共 24 部")
        browser.filter = .default
        browser.mode = .popular
        await browser.reload(token: nil, recommenderUUID: nil)
        #expect(lastPath.hasSuffix("/popular"))
        #expect(browser.filterContext == .curated && browser.summaryText == "共 24 部")
        browser.filter.hasSubtitle = true
        #expect(browser.summaryText == "有字幕 · 共 24 部")
        browser.filter = .default
        browser.mode = .favorites
        await browser.reload(token: nil, recommenderUUID: nil)
        #expect(browser.page.errorMessage != nil)
        await browser.load(page: 1, token: "test", recommenderUUID: nil)
        #expect(lastPath.hasSuffix("/review"))
        #expect(browser.summaryText == "想听 · 标记时间 · 降序 · 共 24 部")
        browser.keyword = "hello"
        #expect(browser.filterContext == .works)
        await browser.reload(token: nil, recommenderUUID: nil)
        #expect(lastPath.hasSuffix("/search/hello"))
        #expect(browser.summaryText == "搜索：hello · 共 24 部")
        browser.keyword = ""
        browser.mode = .recommended
        await browser.reload(token: "test", recommenderUUID: nil)
        #expect(browser.page.errorMessage != nil && browser.filterContext == .curated)
        await browser.load(page: 1, token: "test", recommenderUUID: "uuid")
        #expect(lastPath.hasSuffix("/recommend-for-user"))
        #expect(browser.summaryText == "共 24 部")
        browser.mode = .playlists
        #expect(browser.filterContext == .playlists)
        await browser.reload(token: "test", recommenderUUID: nil)
        #expect(catalog.selectedID == "p1" && lastPath.hasSuffix("/get-playlist-works"))
        #expect(browser.summaryText == "睡前 · 24 个作品")
        _ = try await catalog.ensureSelection(token: "test")
        HTTPStub.respond = { request in
            if request.url!.path.hasSuffix("delete-playlist") { return (200, #"{"id":"p1"}"#) }
            return (200, Self.playlistJSON)
        }
        _ = try await catalog.save(id: nil, name: "睡前", privacy: 0, description: "", token: "test")
        _ = try await catalog.save(id: "p1", name: "睡前", privacy: 0, description: "", token: "test")
        #expect(catalog.playlists.count == 1 && catalog.selectedPlaylist?.id == "p1")
        try await catalog.delete(id: "p1", token: "test")
        #expect(catalog.playlists.isEmpty && catalog.selectedID == nil)
        HTTPStub.respond = { _ in (200, #"{"playlists":[],"pagination":{"currentPage":1,"pageSize":20,"totalCount":0}}"#) }
        do {
            _ = try await catalog.ensureSelection(token: "test")
            Issue.record("Empty catalog must report no playlists")
        } catch {
            #expect(error is ASMRClientError)
        }
        catalog.reset()
        #expect(catalog.selectedPlaylist == nil)
        await browser.load(page: 0, token: nil, recommenderUUID: nil)
        HTTPStub.respond = { _ in (500, "") }
        browser.mode = .latest
        await browser.reload(token: nil, recommenderUUID: nil)
        #expect(browser.page.errorMessage != nil && !browser.page.isLoading)
    }

    @Test func workDetailPageState() async {
        defer { HTTPStub.reset() }
        let detail = WorkDetailPageState(client: makeStubClient())
        HTTPStub.respond = { request in
            (200, request.url!.path.contains("/tracks/") ? #"[{"type":"folder","title":"root","hash":"root","children":[]}]"# : Self.workJSON)
        }
        await detail.load(workID: 1, token: nil)
        #expect(detail.work?.id == 1 && detail.currentPath.first?.id == "root" && !detail.isLoading)
        detail.isPathMenuExpanded = true
        await detail.load(workID: 1, token: nil, force: true)
        #expect(detail.currentPath.first?.id == "root" && detail.isPathMenuExpanded)
        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        await detail.load(workID: 1, token: nil)
        #expect(detail.errorMessage == nil)
        await detail.load(workID: 1, token: nil, force: true)
        #expect(detail.errorMessage != nil && detail.work?.id == 1)
        await detail.mark(.listening, token: "test")
        #expect(detail.markMessage != nil && !detail.isUpdatingMark)
        HTTPStub.respond = { request in
            (200, request.url!.path.hasSuffix("review") ? "{}" : request.url!.path.contains("/tracks/") ? "[]" : Self.workJSON)
        }
        await detail.mark(.listening, token: "test")
        #expect(detail.markMessage == nil)
        await detail.mark(nil, token: "test")
        #expect(detail.markMessage == nil)
        await detail.load(workID: 2, token: nil, force: true)
        #expect(detail.currentPath.isEmpty && !detail.isPathMenuExpanded)
    }

    @Test func playlistMembershipState() async throws {
        defer { HTTPStub.reset() }
        let state = PlaylistMembershipState(workID: 1, client: makeStubClient())
        HTTPStub.respond = { _ in (200, Self.membershipJSON(page: 1)) }
        await state.load(page: 1, token: "test")
        #expect(state.playlists.first?.id == "p1" && state.pagination?.totalPages == 2 && !state.isLoading)

        HTTPStub.respond = { _ in (200, Self.mutationJSON) }
        await state.toggle(state.playlists[0], token: "test")
        #expect(state.playlists[0].exist && state.playlists[0].worksCount == 3 && state.updatingIDs.isEmpty)
        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        await state.toggle(state.playlists[0], token: "test")
        #expect(state.playlists[0].exist && state.playlists[0].worksCount == 3)
        #expect(state.errorMessage == URLError(.notConnectedToInternet).userFacingMessage)
        let decodingFailure = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        #expect(decodingFailure.userFacingMessage == "服务器返回的数据无法识别，请稍后重试")
        HTTPStub.respond = { _ in (200, Self.mutationJSON) }
        await state.toggle(state.playlists[0], token: "test")
        #expect(!state.playlists[0].exist && state.errorMessage == nil)

        HTTPStub.respond = { _ in throw URLError(.timedOut) }
        await state.load(page: 2, token: "test")
        #expect(state.errorMessage != nil && state.currentPage == 1 && state.playlists.first?.id == "p1" && !state.isLoading)

        let gate = RequestGate()
        HTTPStub.hold = { gate.hold($0) }
        let cancelled = PlaylistMembershipState(workID: 1, client: makeStubClient())
        let load = Task { await cancelled.load(page: 1, token: "test") }
        try await waitUntil { gate.count > 0 }
        load.cancel()
        await load.value
        #expect(cancelled.errorMessage == nil && !cancelled.isLoading && cancelled.playlists.isEmpty)
        gate.finish { _ in "" }

        let racing = PlaylistMembershipState(workID: 1, client: makeStubClient())
        let first = Task { await racing.load(page: 1, token: "test") }
        try await waitUntil { gate.count == 1 }
        let second = Task { await racing.load(page: 2, token: "test") }
        try await waitUntil { gate.count == 2 }
        gate.finish { request in
            Self.membershipJSON(page: request.url!.query?.contains("page=2") == true ? 2 : 1)
        }
        await first.value
        await second.value
        #expect(racing.currentPage == 2 && racing.playlists.first?.id == "p2" && !racing.isLoading)
        HTTPStub.hold = nil

        var mutations = 0
        let busy = PlaylistMembershipState(workID: 1, client: makeStubClient())
        HTTPStub.respond = { _ in (200, Self.membershipJSON(page: 1)) }
        await busy.load(page: 1, token: "test")
        HTTPStub.hold = { gate.hold($0) }
        let playlist = busy.playlists[0]
        let toggling = Task { await busy.toggle(playlist, token: "test") }
        try await waitUntil { gate.count == 1 }
        await busy.toggle(playlist, token: "test")
        mutations = gate.count
        gate.finish { _ in Self.mutationJSON }
        await toggling.value
        #expect(mutations == 1 && busy.playlists[0].exist)
        HTTPStub.hold = nil
    }

    @Test func similarWorksState() async throws {
        defer { HTTPStub.reset() }
        let state = SimilarWorksState(workID: 1, client: makeStubClient())
        var pages: [Int] = []
        var fail = false
        HTTPStub.respond = { request in
            #expect(request.url!.path.hasSuffix("recommender/item-neighbors"))
            #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Wisimi/1.0")
            let body = try Self.requestBody(request)
            #expect(body["itemId"] as? String == "1" && body["keyword"] as? String == "")
            #expect((body["localSubtitledWorks"] as? [Int]) == [] && (body["withPlaylistStatus"] as? [Int]) == [])
            let page = body["page"] as! Int
            pages.append(page)
            if fail { throw URLError(.notConnectedToInternet) }
            return (200, Self.similarResponse(page: page, ids: page == 1 ? [1, 2, 2, 3, 4, 5, 6] : page == 2 ? [3, 7, 7] : []))
        }
        #expect(!state.shouldShowSection)
        await state.loadPage(0)
        await state.loadPage(2)
        #expect(pages.isEmpty)
        await state.loadIfNeeded()
        #expect(state.page.works.map(\.id) == [2, 3, 4, 5, 6])
        #expect(state.displayedWorks.map(\.id) == [2, 3, 4, 5] && state.shouldShowSection)
        state.isExpanded = true
        #expect(state.displayedWorks.count == 5)
        await state.loadIfNeeded()
        await state.loadPage(1)
        #expect(pages == [1])
        fail = true
        await state.loadPage(2)
        #expect(state.page.errorMessage != nil && state.page.works.count == 5 && state.page.currentPage == 1)
        fail = false
        await state.retry()
        #expect(pages == [1, 2, 2] && state.page.works.map(\.id) == [3, 7] && state.page.currentPage == 2)
        #expect(state.page.errorMessage == nil && !state.isRetrying)
        state.isExpanded = false
        #expect(state.displayedWorks.map(\.id) == [2, 3, 4, 5])
        state.isExpanded = true
        #expect(state.displayedWorks.map(\.id) == [3, 7])
        await state.loadPage(1)
        #expect(state.page.works.map(\.id) == [2, 3, 4, 5, 6])
        await state.loadPage(3)
        #expect(state.page.works.isEmpty && state.shouldShowSection && state.page.currentPage == 3)
        await state.loadPage(4)
        #expect(pages == [1, 2, 2, 1, 3])

        let empty = SimilarWorksState(workID: 1, client: makeStubClient())
        HTTPStub.respond = { _ in (200, Self.similarResponse(page: 1, ids: [], total: 0)) }
        await empty.loadIfNeeded()
        #expect(!empty.shouldShowSection && empty.page.pagination != nil)

        let failed = SimilarWorksState(workID: 1, client: makeStubClient())
        HTTPStub.respond = { _ in (500, "") }
        await failed.loadIfNeeded()
        #expect(failed.shouldShowSection && failed.page.errorMessage != nil)

        let gate = RequestGate()
        HTTPStub.hold = { gate.hold($0) }
        let retrying = Task { await failed.retry() }
        try await waitUntil { gate.count == 1 }
        #expect(failed.shouldShowSection && failed.isRetrying && failed.page.errorMessage == nil)
        await failed.retry()
        await failed.loadIfNeeded()
        #expect(gate.count == 1)
        gate.finish { _ in Self.similarResponse(page: 1, ids: [2]) }
        await retrying.value
        #expect(failed.displayedWorks.count == 1 && !failed.isRetrying)
        HTTPStub.hold = nil

        HTTPStub.respond = { _ in (200, Self.similarResponse(page: 1, ids: [2])) }
        let abandoned = SimilarWorksState(workID: 1, client: makeStubClient())
        await abandoned.loadIfNeeded()
        HTTPStub.hold = { gate.hold($0) }
        let paging = Task { await abandoned.loadPage(2) }
        try await waitUntil { gate.count == 1 }
        paging.cancel()
        await paging.value
        gate.finish { _ in Self.similarResponse(page: 2, ids: [99]) }
        #expect(abandoned.page.works.map(\.id) == [2] && abandoned.page.currentPage == 1 && abandoned.page.errorMessage == nil)
        HTTPStub.hold = nil
        HTTPStub.respond = { _ in (200, Self.similarResponse(page: 2, ids: [3])) }
        await abandoned.retry()
        #expect(abandoned.page.works.map(\.id) == [3] && abandoned.previewWorks.map(\.id) == [2])
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await abandoned.loadPage(3)
        }
        await preCancelled.value
        #expect(abandoned.page.currentPage == 2)
    }

    @Test func detailAndCatalogRequestRaces() async throws {
        defer { HTTPStub.reset() }
        let gate = RequestGate()
        HTTPStub.hold = { request in request.request.url!.path.contains("/1") ? gate.hold(request) : false }
        HTTPStub.respond = { request in (200, request.url!.path.contains("/tracks/") ? "[]" : Self.workJSON.replacingOccurrences(of: "\"id\":1", with: "\"id\":2")) }
        let detail = WorkDetailPageState(client: makeStubClient())
        let old = Task { await detail.load(workID: 1, token: nil) }
        try await waitUntil { gate.count >= 2 }
        await detail.load(workID: 2, token: nil)
        gate.finish { request in request.url!.path.contains("/tracks/") ? "[]" : Self.workJSON }
        await old.value
        #expect(detail.work?.id == 2 && detail.errorMessage == nil && !detail.isLoading)
        HTTPStub.hold = nil

        HTTPStub.respond = { request in (200, request.url!.path.contains("/tracks/") ? "[]" : Self.workJSON) }
        let marked = WorkDetailPageState(client: makeStubClient())
        await marked.load(workID: 1, token: "test")
        HTTPStub.hold = { request in request.request.url!.path.hasSuffix("/review") ? gate.hold(request) : false }
        let marking = Task { await marked.mark(.listening, token: "test") }
        try await waitUntil { gate.count > 0 }
        await marked.load(workID: 1, token: "test", force: true)
        HTTPStub.respond = { _ in (200, Self.workJSON.replacingOccurrences(of: "\"tags\":[]", with: "\"progress\":\"listening\",\"tags\":[]")) }
        gate.finish { _ in "{}" }
        await marking.value
        #expect(marked.work?.progress == .listening)
        HTTPStub.hold = nil

        HTTPStub.hold = { gate.hold($0) }
        let staleRefresh = Task { await marked.load(workID: 1, token: "test", force: true) }
        try await waitUntil { gate.count >= 2 }
        HTTPStub.hold = nil
        await marked.mark(.listening, token: "test")
        gate.finish { request in request.url!.path.contains("/tracks/") ? "[]" : Self.workJSON }
        await staleRefresh.value
        #expect(marked.work?.progress == .listening)

        HTTPStub.hold = { request in request.request.url!.path.hasSuffix("/review") ? gate.hold(request) : false }
        let oldAccountMark = Task { await marked.mark(.listening, token: "test") }
        try await waitUntil { gate.count > 0 }
        HTTPStub.respond = { request in (200, request.url!.path.contains("/tracks/") ? "[]" : Self.workJSON) }
        await marked.load(workID: 1, token: nil, force: true)
        HTTPStub.respond = { _ in (200, Self.workJSON.replacingOccurrences(of: "\"tags\":[]", with: "\"progress\":\"listening\",\"tags\":[]")) }
        gate.finish { _ in "{}" }
        await oldAccountMark.value
        #expect(marked.work?.progress == nil)
        HTTPStub.hold = nil

        HTTPStub.hold = { gate.hold($0) }
        let catalog = PlaylistCatalog(client: makeStubClient())
        let save = Task { try await catalog.save(id: nil, name: "old-user", privacy: 0, description: "", token: "test") }
        try await waitUntil { gate.count > 0 }
        catalog.reset()
        gate.finish { _ in Self.playlistJSON }
        do {
            _ = try await save.value
            Issue.record("Logout must invalidate pending catalog edits")
        } catch is CancellationError {}
        #expect(catalog.playlists.isEmpty)
        HTTPStub.hold = nil
    }
}
