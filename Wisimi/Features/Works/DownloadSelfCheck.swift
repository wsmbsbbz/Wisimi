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
        assert(remainingFiles == ["index.json"])
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
