#if DEBUG
import Foundation

enum DownloadSelfCheck {
    @MainActor
    static func run(baseURL: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalWorkLibrary(directory: directory, requiresSecurityScope: false)
        let store = DownloadStore(directory: directory, library: library, configuration: .ephemeral)
        defer { store.closeForCheck() }
        try await wait { store.isReady }

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
        let extra = try node("02.mp3", size: 1024) // Intentionally nil hash to exercise relativePath trackID + retry.
        let image = try node("cover.png", type: "image", size: 1024)
        let folderJSON: [String: Any] = ["type": "folder", "title": "nested", "children": try [audio, subtitle, extra, image].map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }]
        let folder = try JSONDecoder().decode(TrackNode.self, from: JSONSerialization.data(withJSONObject: folderJSON))
        let nodes = [folder]

        // 1. Summary & card badge presentation checks
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
        assert(summary.completed == 1 && summary.hasUnfinished && summary.unfinishedWorkCount == 1)
        assert(summary.completionText == "已下载 1/4 个文件")
        assert(summary.cardBadgeText == "下载中 1/4" && summary.cardBadgeSymbol == "arrow.down.circle")
        assert(DownloadSummary(entries: [complete, failedEntry]).cardBadgeText == "1 个失败")
        assert(DownloadSummary(entries: [complete, paused]).cardBadgeText == "已暂停 1/2")
        assert(DownloadSummary(entries: [complete]).cardBadgeText == nil)
        assert(summary.progress == 0.25)
        assert(DownloadSummary(entries: [makeEntry(.downloading, received: 10, expected: 0)]).progress == nil)
        assert(DownloadSummary(entries: []).progress == nil)
        assert(makeEntry(.downloading, received: 0, expected: 100).displayStatus == "等待传输")
        assert(active.displayStatus == "下载中")
        assert(paused.displayStatus == "已暂停")

        // 2. Progress callback check (sub-256 KB immediate first delivery)
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
        let progressStore = DownloadStore(directory: progressDirectory, configuration: .ephemeral)
        defer { progressStore.closeForCheck() }
        try await wait { progressStore.isReady }
        let callbackSession = URLSession(configuration: .ephemeral)
        defer { callbackSession.invalidateAndCancel() }
        let callbackTask = callbackSession.downloadTask(with: baseURL)
        callbackTask.taskDescription = progressEntry.id.uuidString
        progressStore.urlSession(callbackSession, downloadTask: callbackTask, didWriteData: 64,
                                 totalBytesWritten: 64, totalBytesExpectedToWrite: 1024)
        try await wait { progressStore.entries.first?.received == 64 }
        progressStore.urlSession(callbackSession, downloadTask: callbackTask, didWriteData: 960,
                                 totalBytesWritten: 1024, totalBytesExpectedToWrite: 1024)
        try await wait { progressStore.entries.first?.received == 1024 }

        // 3. Selection & subtitle matching checks
        assert(nodes.downloadableFiles.count == 4)
        assert([folder].downloadableFiles.map(\.title) == ["01.mp3", "01.vtt", "02.mp3", "cover.png"])
        assert(DownloadSelection.includingSubtitles([audio], in: nodes, workID: 42).map(\.title) == ["01.mp3", "01.vtt"])
        assert(DownloadSelection.includingSubtitles([audio, subtitle], in: nodes, workID: 42).count == 2)
        assert(DownloadStore.key(for: audio, workID: 42) != DownloadStore.key(for: audio, workID: 43))

        // 4. Insufficient space guard before submission
        let tightDir = directory.appendingPathComponent("tight")
        let tightStore = DownloadStore(directory: tightDir, configuration: .ephemeral, availableCapacity: { 500 })
        defer { tightStore.closeForCheck() }
        try await wait { tightStore.isReady }
        assert(!tightStore.enqueue([audio], work: work, tracks: nodes))
        assert(tightStore.entries.isEmpty && tightStore.works.isEmpty && tightStore.message != nil)

        // 5. Partial enqueue -> immediate visibility in LocalWorkLibrary -> completion -> merge second selection
        let initialSelection = DownloadSelection.includingSubtitles([audio], in: nodes, workID: 42)
        assert(store.enqueue(initialSelection, work: work, tracks: nodes))
        assert(store.enqueue(initialSelection, work: work, tracks: nodes)) // Dedupes same files
        assert(store.entries.count == 2 && store.works.count == 1)
        let savedLocalID = store.savedWork(id: 42)!.localWorkID

        let firstPage = try await library.page(1, pageSize: 12, refresh: true)
        assert(firstPage.works.map(\.id) == [.local(savedLocalID)])
        try await wait { store.entries.allSatisfy { $0.state == .completed } && store.savedWork(id: 42)?.coverFilename != nil }

        let loadedFirst = try await library.loadWork(savedLocalID)
        assert(loadedFirst.onlineWorkID == 42)
        assert(loadedFirst.work.coverURL?.lastPathComponent == "cover.png")
        assert(FileManager.default.fileExists(atPath: loadedFirst.work.coverURL!.path))
        assert(loadedFirst.tracks.count == 1 && loadedFirst.tracks[0].title == "nested")
        let firstFolderFiles = loadedFirst.tracks[0].children!
        assert(firstFolderFiles.map(\.title) == ["01.mp3", "01.vtt"])
        assert(firstFolderFiles[0].playbackURL == store.localURL(for: audio, workID: 42))

        // Merge second download selection into the same local work
        assert(store.enqueue([extra, image], work: work, tracks: nodes))
        assert(store.entries.count == 4 && store.works.count == 1)
        try await wait { store.entries.allSatisfy { $0.state == .completed } }
        let mergedPage = try await library.page(1, pageSize: 12, refresh: true)
        assert(mergedPage.pagination.totalCount == 1 && mergedPage.totalBytes == 4096)

        let localAudio = store.localURL(for: audio, workID: 42)!
        assert(localAudio.path.contains(savedLocalID.uuidString) && localAudio.lastPathComponent == "01.mp3")
        let localAudioSize = try Data(contentsOf: localAudio).count
        assert(localAudioSize == 1024)
        let loadedMerged = try await library.loadWork(savedLocalID)
        assert(loadedMerged.tracks[0].children?.map(\.title) == ["01.mp3", "01.vtt", "02.mp3", "cover.png"])
        assert(loadedMerged.tracks[0].children?[2].playbackURL == store.localURL(for: extra, workID: 42))

        // 6. Restart recovery & crash between file move and index persistence
        let reloadedLibrary = LocalWorkLibrary(directory: directory, requiresSecurityScope: false)
        let reloaded = DownloadStore(directory: directory, library: reloadedLibrary, configuration: .ephemeral)
        defer { reloaded.closeForCheck() }
        try await wait { reloaded.isReady }
        assert(reloaded.entries.count == 4)
        assert(reloaded.savedWork(id: 42)?.work.tags.first?.id.value == "1")
        assert(reloaded.savedWork(id: 42)?.work.progress == .marked)
        assert(reloaded.localURL(for: audio, workID: 42) == localAudio)

        let indexURL = directory.appendingPathComponent(".downloads.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
        var records = manifest["entries"] as! [[String: Any]]
        records[0]["state"] = "downloading"
        manifest["entries"] = records
        try JSONSerialization.data(withJSONObject: manifest).write(to: indexURL)
        let recovered = DownloadStore(directory: directory, configuration: .ephemeral)
        defer { recovered.closeForCheck() }
        try await wait { recovered.isReady }
        assert(recovered.entry(for: audio, workID: 42)?.state == .completed)
        assert(recovered.localURL(for: audio, workID: 42) == localAudio)

        // 7. Missing file detection & re-enqueue
        try FileManager.default.removeItem(at: localAudio)
        assert(reloaded.localURL(for: audio, workID: 42) == nil)
        let whileMissing = try await reloadedLibrary.loadWork(savedLocalID)
        assert(whileMissing.tracks[0].children?[0].playbackURL == nil)
        assert(reloaded.enqueue([audio], work: work, tracks: nodes))
        try await wait { reloaded.entry(for: audio, workID: 42)?.state == .completed }

        // 8. HTTP 404, HTML response, incomplete size validation & retry
        let failures = try [node("missing.mp3"), node("html.mp3"), node("short.mp3", size: 2048)]
        assert(reloaded.enqueue(failures, work: work, tracks: nodes + failures))
        try await wait { failures.allSatisfy { reloaded.entry(for: $0, workID: 42)?.state == .failed } }
        assert(failures.allSatisfy { reloaded.localURL(for: $0, workID: 42) == nil })
        let failed = reloaded.entry(for: failures[0], workID: 42)!
        reloaded.retry(failed.id)
        assert(reloaded.entry(for: failures[0], workID: 42)?.id != failed.id)
        try await wait { reloaded.entry(for: failures[0], workID: 42)?.state == .failed }
        reloaded.retryFailed(localWorkID: savedLocalID)
        try await wait { failures.allSatisfy { reloaded.entry(for: $0, workID: 42)?.state == .failed } }

        // 9. Pause / resume / pauseAll / resumeAll
        let slow = try node("slow.mp3", size: 1_048_576)
        assert(reloaded.enqueue([slow], work: work, tracks: nodes + [slow]))
        let slowID = reloaded.entry(for: slow, workID: 42)!.id
        try await wait { (reloaded.entry(for: slow, workID: 42)?.received ?? 0) > 0 }
        reloaded.pause(slowID)
        assert(reloaded.entry(for: slow, workID: 42)?.state == .paused)
        reloaded.resumeAll(localWorkID: savedLocalID)
        assert(reloaded.entry(for: slow, workID: 42)?.state == .downloading)
        reloaded.pauseAll()
        assert(reloaded.entry(for: slow, workID: 42)?.state == .paused)
        reloaded.resume(slowID)
        try await wait { reloaded.entry(for: slow, workID: 42)?.state == .completed }

        // 10. Single-file deletion prunes tree & empty-work deletion removes directory
        let slowEntry = reloaded.entry(for: slow, workID: 42)!
        reloaded.remove([slowEntry.id])
        assert(reloaded.entry(for: slow, workID: 42) == nil && reloaded.works.count == 1)
        let afterSingleDelete = try await reloadedLibrary.loadWork(savedLocalID)
        assert(!afterSingleDelete.tracks.contains(where: { $0.title == "slow.mp3" }))
        assert(Set(afterSingleDelete.tracks.map(\.title)) == ["nested", "missing.mp3", "html.mp3", "short.mp3"])
        assert(!FileManager.default.fileExists(atPath: reloaded.fileURL(for: slowEntry).path))

        let failureIDs = Set(failures.compactMap { reloaded.entry(for: $0, workID: 42)?.id })
        reloaded.remove(failureIDs)
        let afterFailuresDelete = try await reloadedLibrary.loadWork(savedLocalID)
        assert(afterFailuresDelete.tracks.map(\.title) == ["nested"])

        let cancelled = try node("cancel.mp3")
        assert(reloaded.enqueue([cancelled], work: work, tracks: nodes + [cancelled]))
        reloaded.remove(Set(reloaded.entries.map(\.id)))
        try await Task.sleep(for: .milliseconds(100))
        assert(reloaded.entries.isEmpty && reloaded.works.isEmpty)
        assert(!FileManager.default.fileExists(atPath: reloaded.workDirectory(for: savedLocalID).path))
        let finalPage = try await reloadedLibrary.page(1, pageSize: 12, refresh: true)
        assert(finalPage.works.isEmpty && finalPage.totalBytes == 0)

        // 11. Broken index rollback check
        let brokenDirectory = directory.appendingPathComponent("broken")
        let broken = DownloadStore(directory: brokenDirectory, configuration: .ephemeral)
        defer { broken.closeForCheck() }
        try await wait { broken.isReady }
        let brokenIndex = brokenDirectory.appendingPathComponent(".downloads.json")
        if FileManager.default.fileExists(atPath: brokenIndex.path) {
            try FileManager.default.removeItem(at: brokenIndex)
        }
        try FileManager.default.createDirectory(at: brokenIndex, withIntermediateDirectories: true)
        assert(!broken.enqueue([audio], work: work, tracks: nodes))
        assert(broken.entries.isEmpty && broken.works.isEmpty && broken.message != nil)
        print("Download checks passed: local-library merge, recursive selection, subtitles, space check, HTTP validation, pause/resume, restart recovery, single-file & work deletion")
    }

    @MainActor
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
}
#endif
