#if DEBUG
import Foundation

enum DownloadSelfCheck {
    @MainActor
    static func run(baseURL: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory, configuration: .ephemeral)
        defer { store.closeForCheck() }
        try await wait { store.isReady }
        let workJSON = #"{"id":42,"title":"离线测试","name":"测试社团","duration":12,"dl_count":1,"has_subtitle":true,"progress":"marked","tags":[{"id":1,"name":"test"}],"vas":[]}"#
        let work = try JSONDecoder().decode(WorkDetail.self, from: Data(workJSON.utf8))
        func node(_ name: String, size: Int? = nil) throws -> TrackNode {
            var value: [String: Any] = ["type": name.hasSuffix(".mp3") ? "audio" : "text", "title": name,
                                        "hash": name, "mediaDownloadUrl": baseURL.appendingPathComponent(name).absoluteString]
            if let size { value["size"] = size }
            return try JSONDecoder().decode(TrackNode.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let audio = try node("01.mp3", size: 1024)
        let subtitle = try node("01.vtt", size: 1024)
        let image = try node("cover.png", size: 1024)
        let folderJSON: [String: Any] = ["type": "folder", "title": "nested", "children": try [audio, subtitle, image].map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }]
        let folder = try JSONDecoder().decode(TrackNode.self, from: JSONSerialization.data(withJSONObject: folderJSON))
        let nodes = [folder]
        // Presentation is derived from selected files, not the entire work directory.
        func entry(_ state: DownloadEntry.State, received: Int64, expected: Int64, workID: Int = 42) -> DownloadEntry {
            DownloadEntry(id: UUID(), key: UUID().uuidString, workID: workID, track: audio,
                          filename: "test.mp3", state: state, received: received, expected: expected)
        }
        let complete = entry(.completed, received: 100, expected: 100)
        let active = entry(.downloading, received: 50, expected: 300)
        let paused = entry(.paused, received: 0, expected: 100)
        let failedEntry = entry(.failed, received: 0, expected: 100)
        let selected = [complete, active, paused, failedEntry]
        let summary = DownloadSummary(entries: selected)
        assert(summary.completed == 1 && summary.hasUnfinished)
        assert(summary.completionText == "已下载 1/4 个所选文件")
        assert(summary.progress == 0.25)
        assert(summary.count(.paused) == 1 && summary.count(.failed) == 1)
        assert(DownloadSummary(entries: [entry(.downloading, received: 10, expected: 0)]).progress == nil)
        assert(DownloadSummary(entries: []).progress == nil)
        assert(entry(.downloading, received: 0, expected: 100).displayStatus == "等待传输")
        assert(active.displayStatus == "下载中")
        assert(paused.displayStatus == "已暂停")
        let saved = DownloadedWork(work: work, tracks: nodes)
        // Deliver a sub-256 KB callback directly: scheduler/network speed cannot invalidate this regression check.
        let progressDirectory = directory.appendingPathComponent("progress-check")
        try FileManager.default.createDirectory(at: progressDirectory, withIntermediateDirectories: true)
        let progressEntry = entry(.paused, received: 0, expected: 1024)
        let progressManifest: [String: Any] = [
            "entries": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(progressEntry))],
            "works": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))]
        ]
        try JSONSerialization.data(withJSONObject: progressManifest)
            .write(to: progressDirectory.appendingPathComponent("index.json"))
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
        let visibleCompleted = DownloadWorkGroup.make(works: [saved], entries: selected, filter: .completed)
        assert(visibleCompleted.count == 1 && visibleCompleted[0].visibleEntries.map(\.id) == [complete.id])
        assert(visibleCompleted[0].entries.count == 4) // Menu scope remains the whole work.
        assert(DownloadWorkGroup.make(works: [saved], entries: selected, filter: .unfinished)[0].visibleEntries.count == 3)
        assert(DownloadWorkGroup.make(works: [saved], entries: [complete], filter: .unfinished).isEmpty)
        let otherWork = try JSONDecoder().decode(WorkDetail.self, from: Data(workJSON.replacingOccurrences(of: "42", with: "99").utf8))
        let otherSaved = DownloadedWork(work: otherWork, tracks: nodes)
        let otherComplete = entry(.completed, received: 100, expected: 100, workID: 99)
        assert(DownloadWorkGroup.make(works: [otherSaved, saved], entries: selected + [otherComplete], filter: .all).map(\.id) == [42, 99])
        let updated = entry(.downloading, received: 200, expected: 300)
        assert(DownloadWorkGroup.make(works: [otherSaved, saved], entries: [complete, updated, otherComplete], filter: .all).map(\.id) == [42, 99])
        assert(nodes.downloadableFiles.count == 3)
        assert([folder].downloadableFiles.map(\.title) == ["01.mp3", "01.vtt", "cover.png"])
        assert(DownloadSelection.includingSubtitles([audio], in: nodes, workID: 42).map(\.title) == ["01.mp3", "01.vtt"])
        assert(DownloadSelection.includingSubtitles([audio, subtitle], in: nodes, workID: 42).count == 2)
        assert(DownloadStore.key(for: audio, workID: 42) != DownloadStore.key(for: audio, workID: 43))
        assert(store.enqueue(nodes.downloadableFiles, work: work, tracks: nodes))
        assert(store.enqueue(nodes.downloadableFiles, work: work, tracks: nodes))
        assert(store.entries.count == 3)
        try await wait { store.entries.allSatisfy { $0.state == .completed } }
        assert(store.cachedBytes == 3072)
        let local = store.localURL(for: audio, workID: 42)!
        let localData = try Data(contentsOf: local)
        assert(localData.count == 1024)
        assert(local.lastPathComponent.hasSuffix(".mp3"))
        let reloaded = DownloadStore(directory: directory, configuration: .ephemeral)
        defer { reloaded.closeForCheck() }
        try await wait { reloaded.isReady }
        assert(reloaded.entries.count == 3 && reloaded.cachedBytes == 3072)
        assert(reloaded.savedWork(id: 42)?.work.tags.first?.id.value == "1")
        assert(reloaded.savedWork(id: 42)?.work.progress == .marked)
        assert(reloaded.savedWork(id: 42)?.tracks.downloadableFiles.count == 3)
        assert(reloaded.localURL(for: audio, workID: 42) == local)
        // Recreate the state at a crash between file installation and index persistence.
        let indexURL = directory.appendingPathComponent("index.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
        var records = manifest["entries"] as! [[String: Any]]
        records[0]["state"] = "downloading"
        manifest["entries"] = records
        try JSONSerialization.data(withJSONObject: manifest).write(to: indexURL)
        let recovered = DownloadStore(directory: directory, configuration: .ephemeral)
        defer { recovered.closeForCheck() }
        try await wait { recovered.isReady }
        assert(recovered.entry(for: audio, workID: 42)?.state == .completed)
        assert(recovered.localURL(for: audio, workID: 42) == local)
        try FileManager.default.removeItem(at: local)
        assert(reloaded.localURL(for: audio, workID: 42) == nil)
        assert(reloaded.enqueue([audio], work: work, tracks: nodes))
        try await wait { reloaded.entry(for: audio, workID: 42)?.state == .completed }
        let failures = try [node("missing.mp3"), node("html.mp3"), node("short.mp3", size: 2048)]
        assert(reloaded.enqueue(failures, work: work, tracks: nodes + failures))
        try await wait { failures.allSatisfy { reloaded.entry(for: $0, workID: 42)?.state == .failed } }
        assert(failures.allSatisfy { reloaded.localURL(for: $0, workID: 42) == nil })
        let failed = reloaded.entry(for: failures[0], workID: 42)!
        reloaded.retry(failed.id)
        assert(reloaded.entry(for: failures[0], workID: 42)?.id != failed.id)
        try await wait { reloaded.entry(for: failures[0], workID: 42)?.state == .failed }
        let slow = try node("slow.mp3", size: 1_048_576)
        assert(reloaded.enqueue([slow], work: work, tracks: nodes + [slow]))
        let slowID = reloaded.entry(for: slow, workID: 42)!.id
        try await wait { (reloaded.entry(for: slow, workID: 42)?.received ?? 0) > 0 }
        reloaded.pause(slowID)
        assert(reloaded.entry(for: slow, workID: 42)?.state == .paused)
        reloaded.resume(slowID)
        assert(reloaded.entry(for: slow, workID: 42)?.state == .downloading)
        try await wait { reloaded.entry(for: slow, workID: 42)?.state == .completed }
        let cancelled = try node("cancel.mp3")
        assert(reloaded.enqueue([cancelled], work: work, tracks: nodes))
        reloaded.remove(Set(reloaded.entries.map(\.id)))
        try await Task.sleep(for: .milliseconds(100))
        assert(reloaded.entries.isEmpty && reloaded.works.isEmpty && reloaded.cachedBytes == 0)
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        assert(Set(remainingFiles) == ["index.json", "progress-check"])
        let brokenDirectory = directory.appendingPathComponent("broken")
        let broken = DownloadStore(directory: brokenDirectory, configuration: .ephemeral)
        defer { broken.closeForCheck() }
        try await wait { broken.isReady }
        let brokenIndex = brokenDirectory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: brokenIndex)
        try FileManager.default.createDirectory(at: brokenIndex, withIntermediateDirectories: true)
        assert(!broken.enqueue([audio], work: work, tracks: nodes))
        assert(broken.entries.isEmpty && broken.message != nil)
        print("Download checks passed: recursive selection, subtitles, deduplication, HTTP validation, pause/resume, persistence, local lookup, retry and cancellation/deletion")
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
