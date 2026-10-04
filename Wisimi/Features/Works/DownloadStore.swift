import Foundation
import CryptoKit
import Observation

struct DownloadEntry: Codable, Identifiable {
    enum State: String, Codable {
        case downloading, paused, completed, failed
        var title: String {
            switch self {
            case .downloading: "下载中"
            case .paused: "已暂停"
            case .completed: "已缓存"
            case .failed: "下载失败"
            }
        }
        var symbol: String {
            switch self {
            case .downloading: "arrow.down.circle"
            case .paused: "pause.circle"
            case .completed: "checkmark.circle.fill"
            case .failed: "exclamationmark.circle"
            }
        }
    }
    let id: UUID
    let key: String
    let workID: Int
    let track: TrackNode
    let filename: String
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var progress: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }
}

struct DownloadedWork: Codable, Identifiable {
    var id: Int { work.id }
    let work: WorkDetail
    let tracks: [TrackNode]
}

private struct DownloadManifest: Codable {
    var entries: [DownloadEntry] = []
    var works: [DownloadedWork] = []
}

@MainActor
@Observable
final class DownloadStore: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadStore()
    nonisolated static let sessionIdentifier = "com.wisimi.file-downloads"
    private(set) var entries: [DownloadEntry] = []
    private(set) var works: [DownloadedWork] = []
    private(set) var isReady = false
    var message: String?
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        super.init()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            var excluded = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let index = self.directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let manifest = try JSONDecoder().decode(DownloadManifest.self, from: Data(contentsOf: index))
                entries = manifest.entries
                works = manifest.works
            }
        } catch {
            message = "无法读取下载目录：\(error.localizedDescription)"
            return
        }
        let config: URLSessionConfiguration
        if let configuration {
            config = configuration
        } else {
            #if os(iOS)
            config = .background(withIdentifier: Self.sessionIdentifier)
            config.sessionSendsLaunchEvents = true
            config.isDiscretionary = false
            #else
            config = .default
            #endif
        }
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        Task { await reconnect() }
    }

    static func key(for track: TrackNode, workID: Int) -> String {
        let identity = "\(workID):\(track.hash ?? track.downloadSourceURL?.absoluteString ?? track.title)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(for track: TrackNode, workID: Int) -> DownloadEntry? {
        let key = Self.key(for: track, workID: workID)
        return entries.first { $0.key == key }
    }

    func localURL(for track: TrackNode, workID: Int) -> URL? {
        guard let entry = entry(for: track, workID: workID), entry.state == .completed else { return nil }
        let url = directory.appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var cachedBytes: Int64 {
        entries.reduce(0) { total, entry in
            guard entry.state == .completed,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path) else { return total }
            return total + entry.received
        }
    }

    func savedWork(id: Int) -> DownloadedWork? { works.first { $0.id == id } }

    @discardableResult
    func enqueue(_ files: [TrackNode], work: WorkDetail, tracks: [TrackNode]) -> Bool {
        guard isReady else { return false }
        let oldEntries = entries
        let oldWorks = works
        works.removeAll { $0.id == work.id }
        works.append(DownloadedWork(work: work, tracks: tracks))
        var added: [DownloadEntry] = []
        for track in files where track.downloadSourceURL != nil {
            let key = Self.key(for: track, workID: work.id)
            var previousFilename: String?
            if let existing = entry(for: track, workID: work.id) {
                if existing.state != .failed && (existing.state != .completed || localURL(for: track, workID: work.id) != nil) { continue }
                previousFilename = existing.filename
                entries.removeAll { $0.id == existing.id }
            }
            let id = UUID()
            let ext = (track.title as NSString).pathExtension.lowercased()
            let safeExtension = !ext.isEmpty && ext.count <= 10 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let entry = DownloadEntry(id: id, key: key, workID: work.id, track: track,
                                      filename: previousFilename ?? (id.uuidString + (safeExtension ? ".\(ext)" : "")),
                                      state: .downloading, expected: Int64(track.size ?? 0))
            entries.append(entry)
            added.append(entry)
        }
        guard persist() else {
            entries = oldEntries
            works = oldWorks
            return false
        }
        for entry in added { start(entry) }
        return true
    }

    func pause(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .downloading else { return }
        entries[index].state = .paused
        guard persist() else { entries[index].state = .downloading; return }
        tasks[id]?.suspend()
    }

    func resume(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .paused else { return }
        entries[index].state = .downloading
        guard persist() else { entries[index].state = .paused; return }
        if let task = tasks[id] { task.resume() } else {
            entries[index].received = 0
            start(entries[index])
        }
    }

    func retry(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }),
              let snapshot = savedWork(id: entry.workID) else { return }
        enqueue([entry.track], work: snapshot.work, tracks: snapshot.tracks)
    }

    func remove(_ ids: Set<UUID>) {
        var removed: Set<UUID> = []
        for entry in entries where ids.contains(entry.id) {
            tasks.removeValue(forKey: entry.id)?.cancel()
            let url = directory.appendingPathComponent(entry.filename)
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                removed.insert(entry.id)
            } catch {
                message = "删除失败：\(error.localizedDescription)"
            }
        }
        entries.removeAll { removed.contains($0.id) }
        works.removeAll { work in !entries.contains { $0.workID == work.id } }
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(DownloadManifest(entries: entries, works: works))
            try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            return true
        } catch {
            message = "保存下载记录失败：\(error.localizedDescription)"
            return false
        }
    }

    private func start(_ entry: DownloadEntry) {
        guard let url = entry.track.downloadSourceURL else { return }
        guard url.scheme == "https" || url.scheme == "http" else {
            finish(entry.id, staged: nil, error: "不支持的下载地址")
            return
        }
        let task = session.downloadTask(with: url)
        task.taskDescription = entry.id.uuidString
        tasks[entry.id] = task
        task.resume()
    }

    private func reconnect() async {
        let existing = await session.allTasks
        for task in existing {
            guard let task = task as? URLSessionDownloadTask,
                  let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
                  let entry = entries.first(where: { $0.id == id }),
                  entry.state == .downloading || entry.state == .paused else { task.cancel(); continue }
            tasks[id] = task
            if entry.state == .paused { task.suspend() } else { task.resume() }
        }
        for index in entries.indices {
            let entry = entries[index]
            let file = directory.appendingPathComponent(entry.filename)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if entry.state != .completed, size > 0,
               (entry.track.size ?? 0) <= 0 || entry.track.size == size {
                tasks.removeValue(forKey: entry.id)?.cancel()
                entries[index].state = .completed
                entries[index].received = Int64(size)
                entries[index].expected = Int64(size)
                entries[index].error = nil
            } else if entry.state == .completed && localURL(for: entry.track, workID: entry.workID) == nil {
                entries[index].state = .failed
                entries[index].error = "本地文件已丢失，请重新下载"
            } else if entry.state == .downloading && tasks[entry.id] == nil {
                entries[index].state = .failed
                entries[index].error = "下载已中断，请重试"
            }
        }
        persist()
        isReady = true
    }

    private func finish(_ id: UUID, staged: URL?, error: String?) {
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        tasks.removeValue(forKey: id)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].state == .downloading || entries[index].state == .paused else { return }
        do {
            if let error { throw DownloadError(message: error) }
            guard let staged else { throw DownloadError(message: "没有收到文件") }
            let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw DownloadError(message: "下载文件为空") }
            if let expected = entries[index].track.size, expected > 0, size != expected {
                throw DownloadError(message: "文件不完整，请重试")
            }
            let destination = directory.appendingPathComponent(entries[index].filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            entries[index].received = Int64(size)
            entries[index].expected = Int64(size)
            entries[index].state = .completed
            entries[index].error = nil
        } catch {
            entries[index].state = .failed
            entries[index].error = error.localizedDescription
        }
        if !persist(), entries[index].state == .completed {
            entries[index].state = .failed
            entries[index].error = "文件已保存，但下载记录保存失败，请重启应用恢复"
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor in
            guard let index = self.entries.firstIndex(where: { $0.id == id }),
                  self.entries[index].state == .downloading || self.entries[index].state == .paused else { return }
            let old = self.entries[index].received
            guard totalBytesWritten - old >= 256_000 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            self.entries[index].received = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.entries[index].expected = totalBytesExpectedToWrite }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var failure: String?
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                throw DownloadError(message: "服务器返回异常，请重试")
            }
            if downloadTask.response?.mimeType == "text/html" {
                throw DownloadError(message: "服务器返回了网页，请重试")
            }
            try FileManager.default.moveItem(at: location, to: staged)
        } catch { failure = error.localizedDescription }
        let result = failure
        Task { @MainActor in self.finish(id, staged: staged, error: result) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let message = error.localizedDescription
        Task { @MainActor in self.finish(id, staged: nil, error: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }

    #if DEBUG
    func closeForCheck() { session.invalidateAndCancel() }
    #if os(iOS)
    func seedDebugEntries(work: WorkDetail, tracks: [TrackNode], files: [URL]) throws {
        remove(Set(entries.filter { $0.workID == work.id }.map(\.id)))
        works.removeAll { $0.id == work.id }
        works.append(DownloadedWork(work: work, tracks: tracks))
        for (index, track) in tracks.prefix(5).enumerated() {
            let id = UUID()
            let filename = id.uuidString + "." + (track.title as NSString).pathExtension
            var entry = DownloadEntry(id: id, key: Self.key(for: track, workID: work.id), workID: work.id,
                                      track: track, filename: filename,
                                      state: index < 2 ? .completed : index == 2 ? .downloading : index == 3 ? .paused : .failed,
                                      received: 8_000_000, expected: 20_000_000)
            if index < files.count {
                try FileManager.default.copyItem(at: files[index], to: directory.appendingPathComponent(filename))
                entry.received = Int64(try files[index].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                entry.expected = entry.received
            }
            if index == 4 { entry.error = "网络连接已断开，请重试" }
            entries.append(entry)
        }
        persist()
    }
    #endif
    #endif
}

private struct DownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Selection and playback share the same subtitle matching rule.
@MainActor
enum DownloadSelection {
    static func includingSubtitles(_ selected: [TrackNode], in nodes: [TrackNode], workID: Int) -> [TrackNode] {
        var files = selected
        let selectedKeys = Set(selected.map { DownloadStore.key(for: $0, workID: workID) })
        func visit(_ siblings: [TrackNode]) {
            for node in siblings {
                if node.isFolder { visit(node.children ?? []) }
                else if node.isPlayable, selectedKeys.contains(DownloadStore.key(for: node, workID: workID)),
                        let subtitle = siblings.matchingSubtitle(for: node), subtitle.downloadSourceURL != nil {
                    files.append(subtitle)
                }
            }
        }
        visit(nodes)
        var seen: Set<String> = []
        return files.filter { seen.insert(DownloadStore.key(for: $0, workID: workID)).inserted }
    }
}
