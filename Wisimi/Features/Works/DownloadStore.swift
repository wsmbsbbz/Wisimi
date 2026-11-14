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
            case .completed: "已下载"
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
    let localWorkID: UUID
    let trackID: String
    let track: TrackNode
    let relativePath: String
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var progress: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }
}

struct DownloadedWork: Codable, Identifiable {
    let localWorkID: UUID
    var importedAt: Date
    let work: WorkDetail
    var tracks: [TrackNode]
    var coverFilename: String?
    var id: Int { work.id }
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
    private(set) var catalogRevision = 0
    var message: String?
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var lastProgressUpdate: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var coverTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var coverSession: URLSession!
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let library: LocalWorkLibrary?
    @ObservationIgnored private let availableCapacityProvider: () -> Int64?

    init(
        directory: URL? = nil,
        library: LocalWorkLibrary? = nil,
        configuration: URLSessionConfiguration? = nil,
        availableCapacity: (() -> Int64?)? = nil
    ) {
        let resolvedDirectory = directory ?? LocalWorkLibrary.shared.directory
        self.directory = resolvedDirectory
        self.library = library ?? (directory == nil ? LocalWorkLibrary.shared : nil)
        self.availableCapacityProvider = availableCapacity ?? { Self.defaultAvailableCapacity(at: resolvedDirectory) }
        super.init()
        if directory == nil {
            let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.removeItem(at: legacy)
        }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            var excluded = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let index = self.directory.appendingPathComponent(".downloads.json")
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
        let coverConfig = configuration ?? .default
        coverSession = URLSession(configuration: coverConfig)
        Task { await reconnect() }
    }

    static func key(for track: TrackNode, workID: Int) -> String {
        let identity = "\(workID):\(track.hash ?? track.downloadSourceURL?.absoluteString ?? track.title)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func workDirectory(for localWorkID: UUID) -> URL {
        directory.appendingPathComponent(localWorkID.uuidString, isDirectory: true)
    }

    func filesDirectory(for localWorkID: UUID) -> URL {
        workDirectory(for: localWorkID).appendingPathComponent("files", isDirectory: true)
    }

    func fileURL(for entry: DownloadEntry) -> URL {
        filesDirectory(for: entry.localWorkID).appendingPathComponent(entry.relativePath)
    }

    func entry(for track: TrackNode, workID: Int) -> DownloadEntry? {
        let key = Self.key(for: track, workID: workID)
        return entries.first { $0.key == key }
    }

    func entry(for track: TrackNode, localWorkID: UUID) -> DownloadEntry? {
        entries.first { $0.localWorkID == localWorkID && $0.trackID == track.id }
    }

    func entries(forLocalWork id: UUID) -> [DownloadEntry] {
        entries.filter { $0.localWorkID == id }
    }

    func localURL(for track: TrackNode, workID: Int) -> URL? {
        guard let entry = entry(for: track, workID: workID) else { return nil }
        return localURL(for: entry)
    }

    func localURL(for entry: DownloadEntry) -> URL? {
        guard entry.state == .completed else { return nil }
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func savedWork(id: Int) -> DownloadedWork? { works.first { $0.id == id } }

    func savedWork(localWorkID: UUID) -> DownloadedWork? { works.first { $0.localWorkID == localWorkID } }

    private func notifyCatalogChanged() {
        catalogRevision += 1
        if let library {
            Task { await library.invalidateCatalog() }
        }
    }

    @discardableResult
    func enqueue(_ files: [TrackNode], work: WorkDetail, tracks: [TrackNode]) -> Bool {
        guard isReady else { return false }
        let pendingFiles = files.filter { file in
            guard file.downloadSourceURL != nil else { return false }
            if let existing = entry(for: file, workID: work.id) {
                return existing.state == .failed || (existing.state == .completed && localURL(for: existing) == nil)
            }
            return true
        }
        let requiredBytes = pendingFiles.reduce(Int64(0)) { $0 + max(Int64($1.size ?? 0), 0) }
        if requiredBytes > 0, let available = availableCapacityProvider(), available < requiredBytes {
            message = "设备空间不足，无法下载所选文件。"
            return false
        }

        let oldEntries = entries
        let oldWorks = works
        let existingWork = savedWork(id: work.id)
        let localWorkID = existingWork?.localWorkID ?? UUID()
        var existingByKey: [String: DownloadEntry] = [:]
        for entry in entries where entry.workID == work.id {
            existingByKey[entry.key] = entry
        }

        var selectedByKey: [String: TrackNode] = [:]
        for track in files where track.downloadSourceURL != nil {
            selectedByKey[Self.key(for: track, workID: work.id)] = track
        }

        let managedKeys = Set(existingByKey.keys).union(selectedByKey.keys)
        guard !managedKeys.isEmpty else { return false }

        let built = Self.buildPrunedTree(
            from: tracks,
            workID: work.id,
            managedKeys: managedKeys,
            existingEntries: existingByKey
        )
        var prunedTracks = built.tracks
        var pathByKey = built.paths

        // Keep any existing entries whose tracks no longer appear in the latest remote tree.
        for existing in entries where existing.workID == work.id && pathByKey[existing.key] == nil {
            let key = existing.key
            let track = existing.track
            let components = existing.relativePath.split(separator: "/").map(String.init)
            guard let leafName = components.last else { continue }
            let leafNode = TrackNode(
                type: track.type,
                title: leafName,
                hash: track.hash,
                duration: track.duration,
                children: nil,
                mediaStreamUrl: track.mediaStreamUrl,
                mediaDownloadUrl: track.mediaDownloadUrl,
                size: track.size
            )
            Self.insertNode(leafNode, folderComponents: Array(components.dropLast()), into: &prunedTracks)
            pathByKey[key] = (relativePath: existing.relativePath, trackID: existing.trackID)
        }

        var movedEntries: [(oldURL: URL, newURL: URL)] = []
        for index in entries.indices where entries[index].workID == work.id {
            guard let mapped = pathByKey[entries[index].key],
                  mapped.relativePath != entries[index].relativePath else { continue }
            let oldURL = fileURL(for: entries[index])
            let newURL = filesDirectory(for: localWorkID).appendingPathComponent(mapped.relativePath)
            if FileManager.default.fileExists(atPath: oldURL.path) {
                do {
                    try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: newURL.path) {
                        _ = try FileManager.default.replaceItemAt(newURL, withItemAt: oldURL)
                    } else {
                        try FileManager.default.moveItem(at: oldURL, to: newURL)
                    }
                    movedEntries.append((oldURL, newURL))
                } catch {
                    message = "保存下载目录失败：\(error.localizedDescription)"
                    return false
                }
            }
            entries[index] = DownloadEntry(
                id: entries[index].id,
                key: entries[index].key,
                workID: entries[index].workID,
                localWorkID: localWorkID,
                trackID: mapped.trackID,
                track: entries[index].track,
                relativePath: mapped.relativePath,
                state: entries[index].state,
                received: entries[index].received,
                expected: entries[index].expected,
                error: entries[index].error
            )
        }

        var added: [DownloadEntry] = []
        for track in files where track.downloadSourceURL != nil {
            let key = Self.key(for: track, workID: work.id)
            guard let mapped = pathByKey[key] else { continue }
            if let existing = entries.first(where: { $0.key == key }) {
                if existing.state != .failed && (existing.state != .completed || localURL(for: existing) != nil) { continue }
                entries.removeAll { $0.id == existing.id }
            }
            let id = UUID()
            let entry = DownloadEntry(
                id: id,
                key: key,
                workID: work.id,
                localWorkID: localWorkID,
                trackID: mapped.trackID,
                track: track,
                relativePath: mapped.relativePath,
                state: .downloading,
                expected: Int64(track.size ?? 0)
            )
            entries.append(entry)
            added.append(entry)
        }

        var coverFilename = existingWork?.coverFilename
        if coverFilename == nil {
            coverFilename = detectRootCover(localWorkID: localWorkID)
        }
        let importedAt = added.isEmpty ? (existingWork?.importedAt ?? Date()) : Date()
        let saved = DownloadedWork(
            localWorkID: localWorkID,
            importedAt: importedAt,
            work: work,
            tracks: prunedTracks,
            coverFilename: coverFilename
        )
        works.removeAll { $0.id == work.id }
        works.append(saved)

        guard persist(localWorkIDs: [localWorkID]) else {
            for moved in movedEntries.reversed() {
                try? FileManager.default.moveItem(at: moved.newURL, to: moved.oldURL)
            }
            entries = oldEntries
            works = oldWorks
            if existingWork == nil {
                try? FileManager.default.removeItem(at: workDirectory(for: localWorkID))
            }
            return false
        }
        message = nil
        notifyCatalogChanged()
        for entry in added { start(entry) }
        downloadCoverIfNeeded(for: saved)
        return true
    }

    func pause(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .downloading else { return }
        entries[index].state = .paused
        guard persist() else { entries[index].state = .downloading; return }
        tasks[id]?.suspend()
    }

    func pauseAll(localWorkID: UUID? = nil) {
        let targets = entries.indices.filter {
            entries[$0].state == .downloading && (localWorkID == nil || entries[$0].localWorkID == localWorkID)
        }
        guard !targets.isEmpty else { return }
        let snapshot = entries
        for idx in targets { entries[idx].state = .paused }
        guard persist() else { entries = snapshot; return }
        for idx in targets { tasks[entries[idx].id]?.suspend() }
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

    func resumeAll(localWorkID: UUID? = nil) {
        let targets = entries.indices.filter {
            entries[$0].state == .paused && (localWorkID == nil || entries[$0].localWorkID == localWorkID)
        }
        guard !targets.isEmpty else { return }
        let snapshot = entries
        for idx in targets { entries[idx].state = .downloading }
        guard persist() else { entries = snapshot; return }
        for idx in targets {
            let entry = entries[idx]
            if let task = tasks[entry.id] { task.resume() } else {
                entries[idx].received = 0
                start(entries[idx])
            }
        }
    }

    func retry(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }),
              let snapshot = savedWork(id: entry.workID) else { return }
        enqueue([entry.track], work: snapshot.work, tracks: snapshot.tracks)
    }

    func retryFailed(localWorkID: UUID? = nil) {
        let failed = entries.filter {
            $0.state == .failed && (localWorkID == nil || $0.localWorkID == localWorkID)
        }
        guard !failed.isEmpty else { return }
        let grouped = Dictionary(grouping: failed, by: \.workID)
        for (workID, items) in grouped {
            guard let snapshot = savedWork(id: workID) else { continue }
            enqueue(items.map(\.track), work: snapshot.work, tracks: snapshot.tracks)
        }
    }

    func remove(_ ids: Set<UUID>) {
        var removed: Set<UUID> = []
        var touchedWorkIDs: Set<Int> = []
        for entry in entries where ids.contains(entry.id) {
            tasks.removeValue(forKey: entry.id)?.cancel()
            lastProgressUpdate.removeValue(forKey: entry.id)
            let url = fileURL(for: entry)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    pruneEmptyParentDirectories(startingAt: url.deletingLastPathComponent(), stopAt: filesDirectory(for: entry.localWorkID))
                }
                removed.insert(entry.id)
                touchedWorkIDs.insert(entry.workID)
            } catch {
                message = "删除失败：\(error.localizedDescription)"
            }
        }
        entries.removeAll { removed.contains($0.id) }
        var updatedLocalWorkIDs: Set<UUID> = []
        for workID in touchedWorkIDs {
            let remaining = entries.filter { $0.workID == workID }
            if remaining.isEmpty {
                if let saved = savedWork(id: workID) {
                    coverTasks.removeValue(forKey: saved.localWorkID)?.cancel()
                    try? FileManager.default.removeItem(at: workDirectory(for: saved.localWorkID))
                }
                works.removeAll { $0.id == workID }
            } else if let idx = works.firstIndex(where: { $0.id == workID }) {
                let remainingKeys = Set(remaining.map(\.key))
                works[idx].tracks = Self.pruneRemainingTracks(works[idx].tracks, workID: workID, keepingKeys: remainingKeys)
                let localWorkID = works[idx].localWorkID
                if let cover = works[idx].coverFilename,
                   !FileManager.default.fileExists(atPath: filesDirectory(for: localWorkID).appendingPathComponent(cover).path) {
                    works[idx].coverFilename = detectRootCover(localWorkID: localWorkID)
                }
                updatedLocalWorkIDs.insert(localWorkID)
            }
        }
        persist(localWorkIDs: updatedLocalWorkIDs)
        if !removed.isEmpty {
            notifyCatalogChanged()
        }
    }

    func removeWork(localWorkID: UUID) {
        let matching = entries.filter { $0.localWorkID == localWorkID }
        guard !matching.isEmpty || works.contains(where: { $0.localWorkID == localWorkID }) else { return }
        for entry in matching {
            tasks.removeValue(forKey: entry.id)?.cancel()
            lastProgressUpdate.removeValue(forKey: entry.id)
        }
        coverTasks.removeValue(forKey: localWorkID)?.cancel()
        entries.removeAll { $0.localWorkID == localWorkID }
        works.removeAll { $0.localWorkID == localWorkID }
        try? FileManager.default.removeItem(at: workDirectory(for: localWorkID))
        persist()
        notifyCatalogChanged()
    }

    @discardableResult
    private func persist(localWorkIDs: Set<UUID> = []) -> Bool {
        do {
            let data = try JSONEncoder().encode(DownloadManifest(entries: entries, works: works))
            try data.write(to: directory.appendingPathComponent(".downloads.json"), options: .atomic)
            for saved in works where localWorkIDs.contains(saved.localWorkID) {
                try persistLocalManifest(for: saved)
            }
            return true
        } catch {
            message = "保存下载记录失败：\(error.localizedDescription)"
            return false
        }
    }

    private func persistLocalManifest(for saved: DownloadedWork) throws {
        let workDir = workDirectory(for: saved.localWorkID)
        let filesDir = filesDirectory(for: saved.localWorkID)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let workEntries = entries.filter { $0.localWorkID == saved.localWorkID }
        let bytes = workEntries.reduce(Int64(0)) { total, entry in
            guard localURL(for: entry) != nil else { return total }
            return total + entry.received
        }
        let metadata = LocalWorkMetadata(
            title: saved.work.title,
            circle: saved.work.name,
            duration: saved.work.duration,
            rating: saved.work.rateAverage,
            sales: saved.work.dlCount,
            catalogCode: saved.work.rjCode,
            tags: saved.work.tags.map(\.name),
            voiceActors: saved.work.vas.map(\.name),
            cover: saved.coverFilename
        )
        let entry = LocalWorkEntry(
            id: saved.localWorkID,
            importedAt: saved.importedAt,
            folderName: saved.work.title,
            metadata: metadata,
            hasSubtitle: Self.containsSubtitle(in: saved.tracks) || saved.work.hasSubtitle,
            metadataWarning: nil,
            needsDLsiteSync: false,
            onlineWorkID: saved.work.id,
            byteCount: bytes
        )
        let manifest = LocalWorkManifest(entry: entry, tracks: Self.localManifestTracks(from: saved.tracks))
        try JSONEncoder().encode(manifest).write(to: workDir.appendingPathComponent("index.json"), options: .atomic)
    }

    private func start(_ entry: DownloadEntry) {
        guard let url = entry.track.downloadSourceURL else { return }
        guard url.scheme == "https" || url.scheme == "http" else {
            finish(entry.id, staged: nil, error: "不支持的下载地址")
            return
        }
        lastProgressUpdate.removeValue(forKey: entry.id)
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
        var changed = false
        for index in entries.indices {
            let entry = entries[index]
            let file = fileURL(for: entry)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if entry.state != .completed, size > 0,
               (entry.track.size ?? 0) <= 0 || entry.track.size == size {
                tasks.removeValue(forKey: entry.id)?.cancel()
                entries[index].state = .completed
                entries[index].received = Int64(size)
                entries[index].expected = Int64(size)
                entries[index].error = nil
                changed = true
            } else if entry.state == .completed && !FileManager.default.fileExists(atPath: file.path) {
                entries[index].state = .failed
                entries[index].error = "文件缺失，请重新下载"
                changed = true
            } else if entry.state == .downloading && tasks[entry.id] == nil {
                entries[index].state = .failed
                entries[index].error = "下载已中断，请重试"
                changed = true
            }
        }
        let orphanedWorks = works.filter { work in !entries.contains { $0.localWorkID == work.localWorkID } }
        for orphan in orphanedWorks {
            try? FileManager.default.removeItem(at: workDirectory(for: orphan.localWorkID))
            changed = true
        }
        works.removeAll { work in !entries.contains { $0.localWorkID == work.localWorkID } }
        if changed || !works.isEmpty {
            persist(localWorkIDs: Set(works.map(\.localWorkID)))
        }
        if changed {
            notifyCatalogChanged()
        }
        isReady = true
    }

    private func finish(_ id: UUID, staged: URL?, error: String?) {
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        tasks.removeValue(forKey: id)
        lastProgressUpdate.removeValue(forKey: id)
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
            let destination = fileURL(for: entries[index])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            entries[index].received = Int64(size)
            entries[index].expected = Int64(size)
            entries[index].state = .completed
            entries[index].error = nil
            let entry = entries[index]
            if let workIdx = works.firstIndex(where: { $0.localWorkID == entry.localWorkID }),
               works[workIdx].coverFilename == nil,
               Self.isRootCoverFilename(entry.relativePath) {
                works[workIdx].coverFilename = entry.relativePath
            }
        } catch {
            entries[index].state = .failed
            entries[index].error = error.localizedDescription
        }
        let didComplete = entries[index].state == .completed
        if !persist(localWorkIDs: didComplete ? [entries[index].localWorkID] : []), didComplete {
            entries[index].state = .failed
            entries[index].error = "文件已保存，但下载记录保存失败，请重启应用恢复"
        }
        if entries[index].state == .completed {
            notifyCatalogChanged()
        }
    }

    private func detectRootCover(localWorkID: UUID) -> String? {
        let rootFiles = filesDirectory(for: localWorkID)
        for name in ["cover.jpg", "cover.jpeg", "cover.png", "cover.webp"] {
            if FileManager.default.fileExists(atPath: rootFiles.appendingPathComponent(name).path) {
                return name
            }
        }
        return nil
    }

    private func downloadCoverIfNeeded(for saved: DownloadedWork) {
        let localWorkID = saved.localWorkID
        guard saved.coverFilename == nil,
              coverTasks[localWorkID] == nil,
              let coverURL = saved.work.mainCoverURL,
              coverURL.scheme == "https" || coverURL.scheme == "http" else { return }
        let hasPendingCover = entries.contains {
            $0.localWorkID == localWorkID && Self.isRootCoverFilename($0.relativePath)
        }
        guard !hasPendingCover else { return }
        let ext = Self.safeCoverExtension(from: coverURL)
        let coverFilename = "cover.\(ext)"
        let coverSession = self.coverSession!
        coverTasks[localWorkID] = Task { [weak self] in
            defer { self?.coverTasks.removeValue(forKey: localWorkID) }
            do {
                let (data, response) = try await coverSession.data(from: coverURL)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      200..<300 ~= http.statusCode,
                      http.mimeType != "text/html",
                      !data.isEmpty,
                      let self,
                      let index = self.works.firstIndex(where: { $0.localWorkID == localWorkID }),
                      self.works[index].coverFilename == nil else { return }
                let filesDir = self.filesDirectory(for: localWorkID)
                try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
                try data.write(to: filesDir.appendingPathComponent(coverFilename), options: .atomic)
                self.works[index].coverFilename = coverFilename
                if self.persist(localWorkIDs: [localWorkID]) {
                    self.notifyCatalogChanged()
                }
            } catch {}
        }
    }

    private func pruneEmptyParentDirectories(startingAt folder: URL, stopAt root: URL) {
        let rootPath = root.standardizedFileURL.path
        var current = folder.standardizedFileURL
        while current.path.hasPrefix(rootPath), current.path != rootPath {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  contents.isEmpty else { break }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor in
            guard let index = self.entries.firstIndex(where: { $0.id == id }),
                  self.entries[index].state == .downloading || self.entries[index].state == .paused else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let isComplete = totalBytesExpectedToWrite > 0 && totalBytesWritten == totalBytesExpectedToWrite
            if let last = self.lastProgressUpdate[id], !isComplete, now - last < 0.25 { return }
            self.lastProgressUpdate[id] = now
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

    // MARK: - Path & Tree Helpers

    private static func defaultAvailableCapacity(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    private static func isRootCoverFilename(_ relativePath: String) -> Bool {
        ["cover.jpg", "cover.jpeg", "cover.png", "cover.webp"].contains(relativePath.lowercased())
    }

    private static func safeCoverExtension(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let allowed = ["jpg", "jpeg", "png", "webp", "gif"]
        return allowed.contains(ext) ? ext : "jpg"
    }

    private static func containsSubtitle(in tracks: [TrackNode]) -> Bool {
        tracks.contains { node in
            node.isFolder ? containsSubtitle(in: node.children ?? []) : node.isSubtitle
        }
    }

    private static func sanitizedComponent(_ raw: String, used: inout Set<String>) -> String {
        var base = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        if base.isEmpty || base == "." || base == ".." {
            base = "_"
        }
        var candidate = base
        var suffix = 2
        let ext = (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        while !used.insert(candidate).inserted {
            candidate = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            suffix += 1
        }
        return candidate
    }

    private static func buildPrunedTree(
        from nodes: [TrackNode],
        workID: Int,
        managedKeys: Set<String>,
        existingEntries: [String: DownloadEntry]
    ) -> (tracks: [TrackNode], paths: [String: (relativePath: String, trackID: String)]) {
        var paths: [String: (relativePath: String, trackID: String)] = [:]

        func walk(_ siblings: [TrackNode], prefix: String) -> [TrackNode] {
            var usedNames: Set<String> = []
            var result: [TrackNode] = []
            for node in siblings {
                if node.isFolder {
                    let folderName = sanitizedComponent(node.title, used: &usedNames)
                    let nextPrefix = prefix.isEmpty ? folderName : "\(prefix)/\(folderName)"
                    let children = walk(node.children ?? [], prefix: nextPrefix)
                    guard !children.isEmpty else { continue }
                    result.append(TrackNode(
                        type: node.type,
                        title: folderName,
                        hash: node.hash ?? nextPrefix,
                        duration: node.duration,
                        children: children,
                        mediaStreamUrl: nil,
                        mediaDownloadUrl: nil,
                        size: nil
                    ))
                } else {
                    let key = Self.key(for: node, workID: workID)
                    guard managedKeys.contains(key) else { continue }
                    let preferredName = (existingEntries[key]?.relativePath as NSString?)?.lastPathComponent
                    let fileName = sanitizedComponent(preferredName ?? node.title, used: &usedNames)
                    let relativePath = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
                    let trackID = node.hash ?? relativePath
                    paths[key] = (relativePath, trackID)
                    result.append(TrackNode(
                        type: node.type,
                        title: fileName,
                        hash: node.hash,
                        duration: node.duration,
                        children: nil,
                        mediaStreamUrl: node.mediaStreamUrl,
                        mediaDownloadUrl: node.mediaDownloadUrl,
                        size: node.size
                    ))
                }
            }
            return result
        }

        return (walk(nodes, prefix: ""), paths)
    }

    private static func insertNode(_ leaf: TrackNode, folderComponents: [String], into nodes: inout [TrackNode]) {
        guard let first = folderComponents.first else {
            nodes.append(leaf)
            return
        }
        if let index = nodes.firstIndex(where: { $0.isFolder && $0.title == first }) {
            var children = nodes[index].children ?? []
            insertNode(leaf, folderComponents: Array(folderComponents.dropFirst()), into: &children)
            nodes[index] = TrackNode(
                type: nodes[index].type,
                title: nodes[index].title,
                hash: nodes[index].hash,
                duration: nodes[index].duration,
                children: children,
                mediaStreamUrl: nil,
                mediaDownloadUrl: nil,
                size: nil
            )
        } else {
            var children: [TrackNode] = []
            insertNode(leaf, folderComponents: Array(folderComponents.dropFirst()), into: &children)
            nodes.append(TrackNode(
                type: "folder",
                title: first,
                hash: nil,
                duration: nil,
                children: children,
                mediaStreamUrl: nil,
                mediaDownloadUrl: nil,
                size: nil
            ))
        }
    }

    private static func localManifestTracks(from nodes: [TrackNode], prefix: String = "") -> [TrackNode] {
        nodes.map { node in
            let nextPrefix = prefix.isEmpty ? node.title : "\(prefix)/\(node.title)"
            return TrackNode(
                type: node.type,
                title: node.title,
                hash: node.hash ?? nextPrefix,
                duration: node.duration,
                children: node.isFolder ? localManifestTracks(from: node.children ?? [], prefix: nextPrefix) : nil,
                mediaStreamUrl: nil,
                mediaDownloadUrl: nil,
                size: node.isFolder ? nil : node.size
            )
        }
    }

    private static func pruneRemainingTracks(_ nodes: [TrackNode], workID: Int, keepingKeys: Set<String>) -> [TrackNode] {
        nodes.compactMap { node in
            if node.isFolder {
                let children = pruneRemainingTracks(node.children ?? [], workID: workID, keepingKeys: keepingKeys)
                guard !children.isEmpty else { return nil }
                return TrackNode(
                    type: node.type,
                    title: node.title,
                    hash: node.hash,
                    duration: node.duration,
                    children: children,
                    mediaStreamUrl: nil,
                    mediaDownloadUrl: nil,
                    size: nil
                )
            }
            return keepingKeys.contains(Self.key(for: node, workID: workID)) ? node : nil
        }
    }

    #if DEBUG
    func closeForCheck() {
        for task in coverTasks.values { task.cancel() }
        coverTasks.removeAll()
        coverSession.invalidateAndCancel()
        session.invalidateAndCancel()
    }

    #if os(iOS)
    func seedDebugEntries(work: WorkDetail, tracks: [TrackNode], files: [URL], states: [DownloadEntry.State]? = nil, importedAt: Date = Date()) throws {
        if let existing = savedWork(id: work.id) {
            removeWork(localWorkID: existing.localWorkID)
        }
        let localWorkID = UUID()
        let fixtureStates = states ?? [.completed, .completed, .downloading, .paused, .failed]
        let downloadable = Array(tracks.downloadableFiles.prefix(fixtureStates.count))
        var keys = Set(downloadable.map { Self.key(for: $0, workID: work.id) })
        let built = Self.buildPrunedTree(from: tracks, workID: work.id, managedKeys: keys, existingEntries: [:])
        var savedCover: String?
        let filesDir = filesDirectory(for: localWorkID)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        for (index, track) in downloadable.enumerated() {
            let key = Self.key(for: track, workID: work.id)
            guard let mapped = built.paths[key] else { continue }
            let id = UUID()
            var entry = DownloadEntry(
                id: id,
                key: key,
                workID: work.id,
                localWorkID: localWorkID,
                trackID: mapped.trackID,
                track: track,
                relativePath: mapped.relativePath,
                state: fixtureStates[index],
                received: states == nil ? 8_000_000 : 0,
                expected: states == nil ? 20_000_000 : Int64(track.size ?? 0)
            )
            if index < files.count {
                let dest = fileURL(for: entry)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: files[index], to: dest)
                entry.received = Int64(try files[index].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                entry.expected = entry.received
                if savedCover == nil, Self.isRootCoverFilename(entry.relativePath) {
                    savedCover = entry.relativePath
                }
            }
            if entry.state == .failed { entry.error = "网络连接已断开，请重试" }
            entries.append(entry)
        }
        keys = Set(entries.filter { $0.localWorkID == localWorkID }.map(\.key))
        let finalTree = Self.buildPrunedTree(from: tracks, workID: work.id, managedKeys: keys, existingEntries: [:]).tracks
        let saved = DownloadedWork(localWorkID: localWorkID, importedAt: importedAt, work: work, tracks: finalTree, coverFilename: savedCover)
        works.append(saved)
        persist(localWorkIDs: [localWorkID])
        notifyCatalogChanged()
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
