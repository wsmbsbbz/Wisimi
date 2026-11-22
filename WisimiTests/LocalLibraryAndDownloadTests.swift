import AVFoundation
import Foundation
import Testing
@testable import Wisimi

@Suite("Local Work Library and Downloads", .serialized)
@MainActor
struct LocalLibraryAndDownloadTests {
    private static func downloadSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return configuration
    }

    private static func configureDownloadHTTPStub() {
        HTTPStub.reset()
        HTTPStub.stream = { stub in
            guard let path = stub.request.url?.path, path == "/slow.mp3" || path == "/cancel.mp3" else {
                return false
            }
            let totalSize = 1_048_576
            let response = HTTPURLResponse(
                url: stub.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": "\(totalSize)"
                ]
            )!
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global(qos: .userInitiated).async {
                let chunk = Data(repeating: 0x78, count: 1024)
                for _ in 0..<(totalSize / 1024) {
                    if stub.isCancelled { return }
                    stub.client?.urlProtocol(stub, didLoad: chunk)
                    Thread.sleep(forTimeInterval: 0.002)
                }
                if !stub.isCancelled {
                    stub.client?.urlProtocolDidFinishLoading(stub)
                }
            }
            return true
        }
        HTTPStub.respondWithHeaders = { request in
            let path = request.url?.path ?? ""
            if path == "/missing.mp3" {
                return (404, [:], Data())
            }
            let contentType = path == "/html.mp3" ? "text/html" : "application/octet-stream"
            let data = Data(repeating: 0x78, count: 1024)
            return (200, ["Content-Type": contentType, "Content-Length": "\(data.count)"], data)
        }
    }

    @Test func localWorkLibraryImportMetadataAndTextDecoding() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }

        let original = root.appendingPathComponent("本地作品")
        let storage = root.appendingPathComponent("Library")
        let library = LocalWorkLibrary(directory: storage, requiresSecurityScope: false)
        let source = WorkSource(client: ASMRClient(), library: library)
        let catalog: any WorkCatalog = library
        let emptyPage = try await catalog.page(1, pageSize: 2, refresh: false)
        #expect(emptyPage.works.isEmpty && emptyPage.pagination.currentPage == 1)

        for name in ["Track 2", "Track 10"] {
            let folder = original.appendingPathComponent(name)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: TestFixtures.silenceMP3URL, to: folder.appendingPathComponent("01 #雨.mp3"))
            try "[00:00.00]本地字幕".write(to: folder.appendingPathComponent("01 #雨.lrc"), atomically: true, encoding: .utf8)
        }
        let nestedCover = original.appendingPathComponent("Track 2/封面.png")
        try Data([0]).write(to: nestedCover)
        try files.createSymbolicLink(
            at: original.appendingPathComponent("ignored.mp3"),
            withDestinationURL: original.appendingPathComponent("Track 2/01 #雨.mp3")
        )

        let plan = try await library.inspect(original)
        let plain = try await library.importWork(plan)
        let loaded = try await source.loadWork(.local(plain.id))
        #expect(plan.title == "本地作品" && plan.bytes > 0)
        #expect(loaded.work.reference == .local(plain.id) && loaded.work.hasSubtitle && loaded.metadataWarning == nil)
        #expect(loaded.tracks.map(\.title) == ["Track 2", "Track 10"])
        let firstFolder = try #require(loaded.tracks[0].children)
        let firstTrack = firstFolder.playableTracks[0]
        #expect((firstTrack.duration ?? 0) > 0)
        #expect((loaded.work.duration ?? 0) > 0)
        #expect(firstTrack.id != loaded.tracks[1].children?.playableTracks[0].id)
        #expect(firstTrack.playbackURL?.isFileURL == true && files.fileExists(atPath: firstTrack.playbackURL!.path))

        let subtitle = try #require(firstFolder.matchingSubtitle(for: firstTrack))
        let text = try await source.subtitleText(at: try #require(subtitle.downloadSourceURL))
        #expect(text == "[00:00.00]本地字幕")

        let textOnlySource = root.appendingPathComponent("文本台本作品")
        try files.createDirectory(at: textOnlySource, withIntermediateDirectories: true)
        try files.copyItem(at: TestFixtures.silenceMP3URL, to: textOnlySource.appendingPathComponent("01.mp3"))
        let wavURL = textOnlySource.appendingPathComponent("02.wav")
        do {
            let wavFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
            let wavFile = try AVAudioFile(forWriting: wavURL, settings: wavFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let wavBuffer = AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: 44100)!
            wavBuffer.frameLength = 44100
            try wavFile.write(from: wavBuffer)
        }
        try "台本内容".write(to: textOnlySource.appendingPathComponent("script.txt"), atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:01,000\n你好\n".write(to: textOnlySource.appendingPathComponent("01.srt"), atomically: true, encoding: .utf8)
        let textLibrary = LocalWorkLibrary(directory: root.appendingPathComponent("TextLibrary"), requiresSecurityScope: false)
        let textSource = WorkSource(client: ASMRClient(), library: textLibrary)
        let textOnlyPlan = try await textLibrary.inspect(textOnlySource)
        let textOnlyImported = try await textLibrary.importWork(textOnlyPlan)
        let textOnlyLoaded = try await textSource.loadWork(.local(textOnlyImported.id))
        #expect(textOnlyLoaded.work.hasSubtitle == false)
        let wavNode = textOnlyLoaded.tracks.first { $0.title == "02.wav" }
        #expect((wavNode?.duration ?? 0) >= 0.9)
        let txtNode = textOnlyLoaded.tracks.first { $0.title == "script.txt" }
        let srtNode = textOnlyLoaded.tracks.first { $0.title == "01.srt" }
        #expect(txtNode?.isReadableText == true && txtNode?.isSubtitle == false && txtNode?.textPreviewURL?.isFileURL == true)
        #expect(srtNode?.isReadableText == true && srtNode?.isSubtitle == false && srtNode?.textPreviewURL?.isFileURL == true)

        #expect((try? TrackTextDecoder.decode(Data())) == "")
        let shiftJIS = Data("おやすみ".utf8)
        #expect((try? TrackTextDecoder.decode(shiftJIS)) == "おやすみ")
        if let sjisData = "おやすみ".data(using: .shiftJIS) {
            #expect((try? TrackTextDecoder.decode(sjisData)) == "おやすみ")
        }
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let gbData = "中文台本".data(using: gbEncoding) {
            #expect((try? TrackTextDecoder.decode(gbData)) == "中文台本")
        }
        #expect(throws: (any Error).self) {
            _ = try TrackTextDecoder.decode(Data(repeating: 65, count: 16), maxBytes: 8)
        }

        let metadataURL = original.appendingPathComponent("wisimi.json")
        try Data(#"{"title":"注册标题","circle":"本地社团","duration":120,"rating":4.5,"sales":12,"catalogCode":"TEST-7","tags":["雨声","雨声"],"voiceActors":["测试声优"],"cover":"Track 2/封面.png"}"#.utf8).write(to: metadataURL)
        let registered = try await library.importWork(library.inspect(original))
        let firstPage = try await catalog.page(1, pageSize: 1, refresh: false)
        #expect(firstPage.pagination.totalCount == 2 && firstPage.pagination.totalPages == 2)
        #expect(firstPage.works.map(\.id) == [.local(registered.id)])
        #expect(firstPage.works.first?.tags.map(\.name) == ["雨声"])
        let secondPage = try await catalog.page(2, pageSize: 1, refresh: false)
        #expect(secondPage.works.map(\.id) == [.local(plain.id)])
        let reopened = LocalWorkLibrary(directory: storage, requiresSecurityScope: false)
        let saved = try await reopened.loadWork(registered.id)
        #expect(saved.work.title == "注册标题" && saved.work.circle == "本地社团")
        #expect(saved.work.rating == 4.5 && saved.work.duration == 120 && saved.work.sales == 12 && saved.work.catalogCode == "TEST-7")
        #expect(saved.work.tags.map(\.name) == ["雨声"] && saved.work.voiceActors.map(\.name) == ["测试声优"])
        #expect(saved.work.coverURL?.lastPathComponent == "封面.png" && files.fileExists(atPath: saved.work.coverURL!.path))

        try Data(#"{"cover":"../外部.png"}"#.utf8).write(to: metadataURL)
        let unsafe = try await library.importWork(library.inspect(original))
        let unsafeWork = try await library.loadWork(unsafe.id)
        #expect(unsafeWork.work.coverURL == nil && unsafeWork.metadataWarning != nil)
        try Data("{".utf8).write(to: metadataURL)
        let malformed = try await library.importWork(library.inspect(original))
        #expect(malformed.title == "本地作品" && malformed.metadataWarning != nil && malformed.hasSubtitle)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await library.importWork(plan)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled import published a work") }
        catch is CancellationError {}

        let empty = root.appendingPathComponent("empty")
        try files.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect((try? await library.inspect(empty)) == nil)
        try await library.remove(plain.id)
        let remaining = try await catalog.page(4, pageSize: 1, refresh: false)
        #expect(remaining.pagination.currentPage == 3 && remaining.pagination.totalCount == 3)
        #expect(remaining.works.map(\.id) == [.local(registered.id)])
        #expect(files.fileExists(atPath: nestedCover.path) && files.fileExists(atPath: metadataURL.path))
        let storedDirectories = try files.contentsOfDirectory(atPath: storage.path)
        #expect(storedDirectories.allSatisfy { UUID(uuidString: $0) != nil })

        let broken = storage.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("index.json"))
        let reloaded = try await reopened.page(1, pageSize: 12, refresh: true)
        #expect(reloaded.unreadableCount == 1)
        #expect(Set(reloaded.works.map(\.id)) == [.local(registered.id), .local(unsafe.id), .local(malformed.id)])
        #expect(reloaded.totalBytes > 0)

        let downloadID = UUID()
        let downloadDir = storage.appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let downloadFiles = downloadDir.appendingPathComponent("files", isDirectory: true)
        try files.createDirectory(at: downloadFiles, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: downloadFiles.appendingPathComponent("01.mp3"))
        let downloadEntry = LocalWorkEntry(
            id: downloadID,
            importedAt: Date().addingTimeInterval(60),
            folderName: "RJ99999999 下载测试",
            metadata: LocalWorkMetadata(title: "下载来源测试", circle: "测试社团", catalogCode: "RJ99999999"),
            hasSubtitle: false,
            metadataWarning: nil,
            needsDLsiteSync: false,
            onlineWorkID: 99999999,
            byteCount: 5
        )
        let downloadTrack = TrackNode(type: "audio", title: "01.mp3", hash: "01.mp3", duration: 10, children: nil,
                                      mediaStreamUrl: nil, mediaDownloadUrl: nil, size: 5)
        try JSONEncoder().encode(LocalWorkManifest(entry: downloadEntry, tracks: [downloadTrack]))
            .write(to: downloadDir.appendingPathComponent("index.json"))
        let combined = try await reopened.page(1, pageSize: 12, refresh: true)
        #expect(combined.works.first?.id == .local(downloadID))
        #expect(combined.totalBytes == reloaded.totalBytes + 5)
        let loadedDownload = try await reopened.loadWork(downloadID)
        #expect(loadedDownload.onlineWorkID == 99999999)
        #expect(loadedDownload.tracks.first?.playbackURL?.isFileURL == true)
    }

    @Test func dlsiteMetadataSyncAndParsing() async throws {
        defer { HTTPStub.reset() }
        #expect(RJCodeExtractor.extract(from: "RJ01649840") == "RJ01649840")
        #expect(RJCodeExtractor.extract(from: "rj123456") == "RJ123456")
        #expect(RJCodeExtractor.extract(from: "【中文版】[RJ12345678] 作品标题 (CV.测试)") == "RJ12345678")
        #expect(RJCodeExtractor.extract(from: "prefix_rj1_suffix") == "RJ1")
        #expect(RJCodeExtractor.extract(from: "TRJ123456") == nil)
        #expect(RJCodeExtractor.extract(from: "RJ123456789") == nil)
        #expect(RJCodeExtractor.extract(from: "纯本地作品无编号") == nil)

        let productJSON = Data(#"[{"workno":"RJ01649840","work_name":"测试标题","maker_name":"みんなで翻訳","genres":[{"name":"魔女"},{"name":"魔女"}],"creaters":{"voice_by":[{"name":"大山チロル"}]},"translation_info":{"original_workno":"RJ01631266"},"image_main":{"url":"//img.dlsite.jp/test/cover.jpg"}}]"#.utf8)
        let parsedProduct = try DLsiteMetadataClient.parseProductJSON(productJSON)
        #expect(parsedProduct.workno == "RJ01649840" && parsedProduct.translationInfo?.originalWorkno == "RJ01631266")
        #expect(DLsiteMetadataClient.resolveImageURL(parsedProduct.imageMain?.url)?.absoluteString == "https://img.dlsite.jp/test/cover.jpg")
        let ajaxJSON = Data(#"{"RJ01649840":{"dl_count":27,"rate_average_2dp":4.78}}"#.utf8)
        let parsedAjax = try DLsiteMetadataClient.parseAjaxJSON(ajaxJSON, for: "RJ01649840")
        #expect(parsedAjax.dlCount == 27 && parsedAjax.rateAverage2dp == 4.78)

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
        #expect(imported.needsDLsiteSync && missing.needsDLsiteSync)
        let didSync = await library.syncPendingDLsiteMetadataIfNeeded()
        #expect(didSync && Set(stub.fetchedCodes) == ["RJ01649840", "RJ99999999"] && stub.fetchedCodes.count == 2)

        let savedJSON = library.contentDirectory(for: imported.id).appendingPathComponent("wisimi.json")
        #expect(files.fileExists(atPath: savedJSON.path))
        let decodedJSON = try JSONDecoder().decode(LocalWorkMetadata.self, from: Data(contentsOf: savedJSON))
        #expect(decodedJSON.title == "DLsite 标题" && decodedJSON.circle == "原社团" && decodedJSON.cover == "cover.jpg")
        #expect(decodedJSON.sales == 27 && decodedJSON.rating == 4.78 && decodedJSON.catalogCode == "RJ01649840")

        let loaded = try await library.loadWork(imported.id)
        #expect(loaded.work.title == "DLsite 标题" && loaded.work.coverURL?.lastPathComponent == "cover.jpg")

        let restarted = LocalWorkLibrary(directory: storage, requiresSecurityScope: false, dlsiteClient: stub)
        let didSyncAfterRestart = await restarted.syncPendingDLsiteMetadataIfNeeded()
        #expect(!didSyncAfterRestart && stub.fetchedCodes.count == 2)
        let missingLoaded = try await restarted.loadWork(missing.id)
        #expect(missingLoaded.work.title == "RJ99999999_不存在")

        let existingSource = root.appendingPathComponent("RJ01753619_自带元数据")
        try files.createDirectory(at: existingSource, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: existingSource.appendingPathComponent("01.mp3"))
        try Data(#"{"title":"本地自定义标题","catalogCode":"RJ01753619"}"#.utf8)
            .write(to: existingSource.appendingPathComponent("wisimi.json"))
        let existingEntry = try await restarted.importWork(restarted.inspect(existingSource))
        #expect(!existingEntry.needsDLsiteSync)
        let didSyncExisting = await restarted.syncPendingDLsiteMetadataIfNeeded()
        #expect(!didSyncExisting && stub.fetchedCodes.count == 2)

        let stubClient = DLsiteMetadataClient(session: URLSession(configuration: Self.downloadSessionConfiguration()))
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
        #expect(fetched.metadata.title == "翻译标题" && fetched.metadata.circle == "愛毒レース")
        #expect(fetched.metadata.sales == 27 && fetched.metadata.rating == 4.78)
        #expect(fetched.coverURL?.absoluteString == "https://img.dlsite.jp/test/RJ01631266_img_main.jpg")

        HTTPStub.payload = Data([0xFF, 0xD8, 0xFF, 0xD9])
        HTTPStub.respond = { _ in (200, "") }
        let coverBytes = try await stubClient.downloadCover(from: fetched.coverURL!)
        #expect(coverBytes == Data([0xFF, 0xD8, 0xFF, 0xD9]))

        HTTPStub.payload = nil
        HTTPStub.respond = { _ in (200, "<html>error</html>") }
        do {
            _ = try await stubClient.downloadCover(from: fetched.coverURL!)
            Issue.record("HTML payload must be rejected for cover download")
        } catch let error as DLsiteMetadataError {
            #expect(error == .invalidResponse)
        }

        HTTPStub.respond = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await stubClient.fetchMetadata(for: "RJ01649840")
            Issue.record("URLError should propagate")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }

    @Test func downloadStoreLifecycleAndValidation() async throws {
        Self.configureDownloadHTTPStub()
        defer { HTTPStub.reset() }

        let baseURL = URL(string: "https://downloads.wisimi.test")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalWorkLibrary(directory: directory, requiresSecurityScope: false)
        let store = DownloadStore(directory: directory, library: library, configuration: Self.downloadSessionConfiguration())
        defer { store.closeForCheck() }
        try await waitUntil({ store.isReady }, maxAttempts: 1000)

        let coverURL = baseURL.appendingPathComponent("cover.png").absoluteString
        let workJSON = #"{"id":42,"title":"离线测试","name":"测试社团","duration":12,"dl_count":1,"has_subtitle":true,"mainCoverUrl":"\#(coverURL)","progress":"marked","tags":[{"id":1,"name":"test"}],"vas":[]}"#
        let work = try JSONDecoder().decode(WorkDetail.self, from: Data(workJSON.utf8))
        func node(_ name: String, type: String? = nil, size: Int? = nil, hash: String? = nil) throws -> TrackNode {
            let resolvedType = type ?? (name.hasSuffix(".mp3") ? "audio" : name.hasSuffix(".png") ? "image" : "text")
            var value: [String: Any] = [
                "type": resolvedType,
                "title": name,
                "mediaDownloadUrl": baseURL.appendingPathComponent(name).absoluteString
            ]
            if let hash { value["hash"] = hash }
            if let size { value["size"] = size }
            return try JSONDecoder().decode(TrackNode.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let audio = try node("01.mp3", size: 1024, hash: "01.mp3")
        let subtitle = try node("01.vtt", size: 1024, hash: "01.vtt")
        let extra = try node("02.mp3", size: 1024)
        let image = try node("cover.png", type: "image", size: 1024)
        let folderJSON: [String: Any] = ["type": "folder", "title": "nested", "children": try [audio, subtitle, extra, image].map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }]
        let folder = try JSONDecoder().decode(TrackNode.self, from: JSONSerialization.data(withJSONObject: folderJSON))
        let nodes = [folder]

        let localID = UUID()
        func makeEntry(_ state: DownloadEntry.State, received: Int64, expected: Int64, workID: Int = 42) -> DownloadEntry {
            DownloadEntry(
                id: UUID(),
                key: UUID().uuidString,
                workID: workID,
                localWorkID: localID,
                trackID: "nested/01.mp3",
                track: audio,
                relativePath: "nested/01.mp3",
                state: state,
                received: received,
                expected: expected
            )
        }
        let complete = makeEntry(.completed, received: 100, expected: 100)
        let active = makeEntry(.downloading, received: 50, expected: 300)
        let paused = makeEntry(.paused, received: 0, expected: 100)
        let failedEntry = makeEntry(.failed, received: 0, expected: 100)
        let summary = DownloadSummary(entries: [complete, active, paused, failedEntry])
        #expect(summary.completed == 1 && summary.hasUnfinished && summary.unfinishedWorkCount == 1)
        #expect(summary.completionText == "已下载 1/4 个文件")
        #expect(summary.cardBadgeText == "下载中 1/4" && summary.cardBadgeSymbol == "arrow.down.circle")
        #expect(DownloadSummary(entries: [complete, failedEntry]).cardBadgeText == "1 个失败")
        #expect(DownloadSummary(entries: [complete, paused]).cardBadgeText == "已暂停 1/2")
        #expect(DownloadSummary(entries: [complete]).cardBadgeText == nil)
        #expect(summary.progress == 0.25)
        #expect(DownloadSummary(entries: [makeEntry(.downloading, received: 10, expected: 0)]).progress == nil)
        #expect(DownloadSummary(entries: []).progress == nil)
        #expect(makeEntry(.downloading, received: 0, expected: 100).displayStatus == "等待传输")
        #expect(active.displayStatus == "下载中")
        #expect(paused.displayStatus == "已暂停")

        let progressDirectory = directory.appendingPathComponent("progress-check")
        try FileManager.default.createDirectory(at: progressDirectory, withIntermediateDirectories: true)
        let progressEntry = makeEntry(.paused, received: 0, expected: 1024)
        let progressSaved = DownloadedWork(localWorkID: localID, importedAt: Date(), work: work, tracks: nodes, coverFilename: nil)
        let progressManifest: [String: Any] = [
            "entries": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(progressEntry))],
            "works": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(progressSaved))]
        ]
        try JSONSerialization.data(withJSONObject: progressManifest)
            .write(to: progressDirectory.appendingPathComponent(".downloads.json"))
        let progressStore = DownloadStore(directory: progressDirectory, configuration: Self.downloadSessionConfiguration())
        defer { progressStore.closeForCheck() }
        try await waitUntil({ progressStore.isReady }, maxAttempts: 1000)
        let callbackSession = URLSession(configuration: Self.downloadSessionConfiguration())
        defer { callbackSession.invalidateAndCancel() }
        let callbackTask = callbackSession.downloadTask(with: baseURL)
        callbackTask.taskDescription = progressEntry.id.uuidString
        progressStore.urlSession(callbackSession, downloadTask: callbackTask, didWriteData: 64,
                                 totalBytesWritten: 64, totalBytesExpectedToWrite: 1024)
        try await waitUntil({ progressStore.entries.first?.received == 64 }, maxAttempts: 1000)
        progressStore.urlSession(callbackSession, downloadTask: callbackTask, didWriteData: 960,
                                 totalBytesWritten: 1024, totalBytesExpectedToWrite: 1024)
        try await waitUntil({ progressStore.entries.first?.received == 1024 }, maxAttempts: 1000)

        #expect(nodes.downloadableFiles.count == 4)
        #expect([folder].downloadableFiles.map(\.title) == ["01.mp3", "01.vtt", "02.mp3", "cover.png"])
        #expect(DownloadSelection.includingSubtitles([audio], in: nodes, workID: 42).map(\.title) == ["01.mp3", "01.vtt"])
        #expect(DownloadSelection.includingSubtitles([audio, subtitle], in: nodes, workID: 42).count == 2)
        #expect(DownloadStore.key(for: audio, workID: 42) != DownloadStore.key(for: audio, workID: 43))

        let tightDir = directory.appendingPathComponent("tight")
        let tightStore = DownloadStore(directory: tightDir, configuration: Self.downloadSessionConfiguration(), availableCapacity: { 500 })
        defer { tightStore.closeForCheck() }
        try await waitUntil({ tightStore.isReady }, maxAttempts: 1000)
        #expect(!tightStore.enqueue([audio], work: work, tracks: nodes))
        #expect(tightStore.entries.isEmpty && tightStore.works.isEmpty && tightStore.message != nil)

        let initialSelection = DownloadSelection.includingSubtitles([audio], in: nodes, workID: 42)
        #expect(store.enqueue(initialSelection, work: work, tracks: nodes))
        #expect(store.enqueue(initialSelection, work: work, tracks: nodes))
        #expect(store.entries.count == 2 && store.works.count == 1)
        let savedLocalID = try #require(store.savedWork(id: 42)?.localWorkID)

        let firstPage = try await library.page(1, pageSize: 12, refresh: true)
        #expect(firstPage.works.map(\.id) == [.local(savedLocalID)])
        try await waitUntil({ store.entries.allSatisfy { $0.state == .completed } && store.savedWork(id: 42)?.coverFilename != nil }, maxAttempts: 1000)

        let loadedFirst = try await library.loadWork(savedLocalID)
        #expect(loadedFirst.onlineWorkID == 42)
        #expect(loadedFirst.work.coverURL?.lastPathComponent == "cover.png")
        #expect(FileManager.default.fileExists(atPath: loadedFirst.work.coverURL!.path))
        #expect(loadedFirst.tracks.count == 1 && loadedFirst.tracks[0].title == "nested")
        let firstFolderFiles = try #require(loadedFirst.tracks[0].children)
        #expect(firstFolderFiles.map(\.title) == ["01.mp3", "01.vtt"])
        #expect(firstFolderFiles[0].playbackURL == store.localURL(for: audio, workID: 42))

        #expect(store.enqueue([extra, image], work: work, tracks: nodes))
        #expect(store.entries.count == 4 && store.works.count == 1)
        try await waitUntil({ store.entries.allSatisfy { $0.state == .completed } }, maxAttempts: 1000)
        let mergedPage = try await library.page(1, pageSize: 12, refresh: true)
        #expect(mergedPage.pagination.totalCount == 1 && mergedPage.totalBytes == 4096)

        let localAudio = try #require(store.localURL(for: audio, workID: 42))
        #expect(localAudio.path.contains(savedLocalID.uuidString) && localAudio.lastPathComponent == "01.mp3")
        #expect(try Data(contentsOf: localAudio).count == 1024)
        let loadedMerged = try await library.loadWork(savedLocalID)
        #expect(loadedMerged.tracks[0].children?.map(\.title) == ["01.mp3", "01.vtt", "02.mp3", "cover.png"])
        #expect(loadedMerged.tracks[0].children?[2].playbackURL == store.localURL(for: extra, workID: 42))

        let reloadedLibrary = LocalWorkLibrary(directory: directory, requiresSecurityScope: false)
        let reloaded = DownloadStore(directory: directory, library: reloadedLibrary, configuration: Self.downloadSessionConfiguration())
        defer { reloaded.closeForCheck() }
        try await waitUntil({ reloaded.isReady }, maxAttempts: 1000)
        #expect(reloaded.entries.count == 4)
        #expect(reloaded.savedWork(id: 42)?.work.tags.first?.id.value == "1")
        #expect(reloaded.savedWork(id: 42)?.work.progress == .marked)
        #expect(reloaded.localURL(for: audio, workID: 42) == localAudio)

        let indexURL = directory.appendingPathComponent(".downloads.json")
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        var records = try #require(manifest["entries"] as? [[String: Any]])
        records[0]["state"] = "downloading"
        manifest["entries"] = records
        try JSONSerialization.data(withJSONObject: manifest).write(to: indexURL)
        let recovered = DownloadStore(directory: directory, configuration: Self.downloadSessionConfiguration())
        defer { recovered.closeForCheck() }
        try await waitUntil({ recovered.isReady }, maxAttempts: 1000)
        #expect(recovered.entry(for: audio, workID: 42)?.state == .completed)
        #expect(recovered.localURL(for: audio, workID: 42) == localAudio)

        try FileManager.default.removeItem(at: localAudio)
        #expect(reloaded.localURL(for: audio, workID: 42) == nil)
        let whileMissing = try await reloadedLibrary.loadWork(savedLocalID)
        #expect(whileMissing.tracks[0].children?[0].playbackURL == nil)
        #expect(reloaded.enqueue([audio], work: work, tracks: nodes))
        try await waitUntil({ reloaded.entry(for: audio, workID: 42)?.state == .completed }, maxAttempts: 1000)

        let failures = try [node("missing.mp3"), node("html.mp3"), node("short.mp3", size: 2048)]
        #expect(reloaded.enqueue(failures, work: work, tracks: nodes + failures))
        try await waitUntil({ failures.allSatisfy { reloaded.entry(for: $0, workID: 42)?.state == .failed } }, maxAttempts: 1000)
        #expect(failures.allSatisfy { reloaded.localURL(for: $0, workID: 42) == nil })
        let failed = try #require(reloaded.entry(for: failures[0], workID: 42))
        reloaded.retry(failed.id)
        #expect(reloaded.entry(for: failures[0], workID: 42)?.id != failed.id)
        try await waitUntil({ reloaded.entry(for: failures[0], workID: 42)?.state == .failed }, maxAttempts: 1000)
        reloaded.retryFailed(localWorkID: savedLocalID)
        try await waitUntil({ failures.allSatisfy { reloaded.entry(for: $0, workID: 42)?.state == .failed } }, maxAttempts: 1000)

        let slow = try node("slow.mp3", size: 1_048_576)
        #expect(reloaded.enqueue([slow], work: work, tracks: nodes + [slow]))
        let slowID = try #require(reloaded.entry(for: slow, workID: 42)?.id)
        try await waitUntil({ (reloaded.entry(for: slow, workID: 42)?.received ?? 0) > 0 }, maxAttempts: 1000)
        reloaded.pause(slowID)
        #expect(reloaded.entry(for: slow, workID: 42)?.state == .paused)
        reloaded.resumeAll(localWorkID: savedLocalID)
        #expect(reloaded.entry(for: slow, workID: 42)?.state == .downloading)
        reloaded.pauseAll()
        #expect(reloaded.entry(for: slow, workID: 42)?.state == .paused)
        reloaded.resume(slowID)
        try await waitUntil({ reloaded.entry(for: slow, workID: 42)?.state == .completed }, maxAttempts: 1000)

        let slowEntry = try #require(reloaded.entry(for: slow, workID: 42))
        reloaded.remove([slowEntry.id])
        #expect(reloaded.entry(for: slow, workID: 42) == nil && reloaded.works.count == 1)
        let afterSingleDelete = try await reloadedLibrary.loadWork(savedLocalID)
        #expect(!afterSingleDelete.tracks.contains(where: { $0.title == "slow.mp3" }))
        #expect(Set(afterSingleDelete.tracks.map(\.title)) == ["nested", "missing.mp3", "html.mp3", "short.mp3"])
        #expect(!FileManager.default.fileExists(atPath: reloaded.fileURL(for: slowEntry).path))

        let failureIDs = Set(failures.compactMap { reloaded.entry(for: $0, workID: 42)?.id })
        reloaded.remove(failureIDs)
        let afterFailuresDelete = try await reloadedLibrary.loadWork(savedLocalID)
        #expect(afterFailuresDelete.tracks.map(\.title) == ["nested"])

        let cancelled = try node("cancel.mp3")
        #expect(reloaded.enqueue([cancelled], work: work, tracks: nodes + [cancelled]))
        reloaded.remove(Set(reloaded.entries.map(\.id)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(reloaded.entries.isEmpty && reloaded.works.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reloaded.workDirectory(for: savedLocalID).path))
        let finalPage = try await reloadedLibrary.page(1, pageSize: 12, refresh: true)
        #expect(finalPage.works.isEmpty && finalPage.totalBytes == 0)

        let brokenDirectory = directory.appendingPathComponent("broken")
        let broken = DownloadStore(directory: brokenDirectory, configuration: Self.downloadSessionConfiguration())
        defer { broken.closeForCheck() }
        try await waitUntil({ broken.isReady }, maxAttempts: 1000)
        let brokenIndex = brokenDirectory.appendingPathComponent(".downloads.json")
        if FileManager.default.fileExists(atPath: brokenIndex.path) {
            try FileManager.default.removeItem(at: brokenIndex)
        }
        try FileManager.default.createDirectory(at: brokenIndex, withIntermediateDirectories: true)
        #expect(!broken.enqueue([audio], work: work, tracks: nodes))
        #expect(broken.entries.isEmpty && broken.works.isEmpty && broken.message != nil)
    }
}
