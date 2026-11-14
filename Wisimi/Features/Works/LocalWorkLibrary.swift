import Foundation

nonisolated struct LocalWorkMetadata: Codable, Sendable {
    var title: String?
    var circle: String?
    var duration: Double?
    var rating: Double?
    var sales: Int?
    var catalogCode: String?
    var tags: [String]?
    var voiceActors: [String]?
    var cover: String?
}

nonisolated struct LocalWorkEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let importedAt: Date
    let folderName: String
    let metadata: LocalWorkMetadata
    let hasSubtitle: Bool
    let metadataWarning: String?
    let needsDLsiteSync: Bool
    let onlineWorkID: Int?
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case id, importedAt, folderName, metadata, hasSubtitle, metadataWarning, needsDLsiteSync, onlineWorkID, byteCount
    }

    init(
        id: UUID,
        importedAt: Date,
        folderName: String,
        metadata: LocalWorkMetadata,
        hasSubtitle: Bool,
        metadataWarning: String?,
        needsDLsiteSync: Bool = false,
        onlineWorkID: Int? = nil,
        byteCount: Int64 = 0
    ) {
        self.id = id
        self.importedAt = importedAt
        self.folderName = folderName
        self.metadata = metadata
        self.hasSubtitle = hasSubtitle
        self.metadataWarning = metadataWarning
        self.needsDLsiteSync = needsDLsiteSync
        self.onlineWorkID = onlineWorkID
        self.byteCount = byteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        folderName = try container.decode(String.self, forKey: .folderName)
        metadata = try container.decode(LocalWorkMetadata.self, forKey: .metadata)
        hasSubtitle = try container.decode(Bool.self, forKey: .hasSubtitle)
        metadataWarning = try container.decodeIfPresent(String.self, forKey: .metadataWarning)
        needsDLsiteSync = try container.decodeIfPresent(Bool.self, forKey: .needsDLsiteSync) ?? false
        onlineWorkID = try container.decodeIfPresent(Int.self, forKey: .onlineWorkID)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount) ?? 0
    }

    var title: String { Self.text(metadata.title) ?? folderName }

    func updating(metadata: LocalWorkMetadata, needsDLsiteSync: Bool, warning: String?, byteCount: Int64? = nil) -> LocalWorkEntry {
        LocalWorkEntry(
            id: id,
            importedAt: importedAt,
            folderName: folderName,
            metadata: metadata,
            hasSubtitle: hasSubtitle,
            metadataWarning: warning,
            needsDLsiteSync: needsDLsiteSync,
            onlineWorkID: onlineWorkID,
            byteCount: byteCount ?? self.byteCount
        )
    }

    func presentation(in directory: URL) -> WorkPresentation {
        WorkPresentation(
            reference: .local(id), title: title, circle: Self.text(metadata.circle),
            duration: metadata.duration.flatMap { $0 >= 0 && Int(exactly: $0.rounded()) != nil ? $0 : nil },
            rating: metadata.rating.flatMap { (0...5).contains($0) ? $0 : nil },
            sales: metadata.sales.flatMap { $0 >= 0 ? $0 : nil }, catalogCode: Self.text(metadata.catalogCode),
            hasSubtitle: hasSubtitle, coverURL: metadata.cover.map { directory.appendingPathComponent($0) },
            tags: Self.names(metadata.tags), voiceActors: Self.names(metadata.voiceActors)
        )
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func names(_ values: [String]?) -> [NameItem] {
        var seen: Set<String> = []
        return (values ?? []).compactMap { value in
            guard let name = text(value), seen.insert(name).inserted else { return nil }
            return NameItem(id: FlexibleID(name), name: name)
        }
    }
}

nonisolated struct LocalImportPlan: Sendable {
    let source: URL
    let title: String
    let bytes: Int64
}

nonisolated struct LocalWorkManifest: Codable, Sendable {
    let entry: LocalWorkEntry
    let tracks: [TrackNode]
}

actor LocalWorkLibrary: WorkCatalog {
    static let shared = LocalWorkLibrary()

    private struct ManifestHeader: Decodable {
        let entry: LocalWorkEntry
    }

    private struct Scan {
        var playable = false
        var hasSubtitle = false
        var images: Set<String> = []
        var bytes: Int64 = 0
    }

    nonisolated let directory: URL
    private let requiresSecurityScope: Bool
    private let dlsiteClient: any DLsiteMetadataFetching
    private let files = FileManager.default
    private var isPrepared = false
    private var catalog: [LocalWorkEntry]?
    private var unreadableCount = 0

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "LocalWorks", directoryHint: .isDirectory),
         requiresSecurityScope: Bool = true,
         dlsiteClient: any DLsiteMetadataFetching = DLsiteMetadataClient()) {
        self.directory = directory
        self.requiresSecurityScope = requiresSecurityScope
        self.dlsiteClient = dlsiteClient
    }

    func page(_ number: Int, pageSize: Int, refresh: Bool) throws -> WorkCatalogPage {
        precondition(pageSize > 0)
        if refresh || catalog == nil { try loadCatalog() }
        let entries = catalog ?? []
        let pageCount = entries.isEmpty ? 1 : (entries.count - 1) / pageSize + 1
        let currentPage = min(max(number, 1), pageCount)
        let start = (currentPage - 1) * pageSize
        let works = entries.dropFirst(start).prefix(pageSize).map { entry in
            entry.presentation(in: contentDirectory(for: entry.id)).card
        }
        let totalBytes = entries.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }
        return WorkCatalogPage(works: works,
                               pagination: WorksPagination(currentPage: currentPage, pageSize: pageSize, totalCount: entries.count),
                               unreadableCount: unreadableCount,
                               totalBytes: totalBytes)
    }

    func invalidateCatalog() {
        catalog = nil
    }

    private func loadCatalog() throws {
        try prepareDirectory()
        let folders = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var entries: [LocalWorkEntry] = []
        var failed = 0
        for folder in folders {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                let index = folder.appendingPathComponent("index.json")
                let header = try JSONDecoder().decode(ManifestHeader.self, from: Data(contentsOf: index))
                guard header.entry.id == id else { throw CocoaError(.fileReadCorruptFile) }
                if header.entry.onlineWorkID == nil, header.entry.byteCount == 0 {
                    let measuredBytes = directorySize(at: folder.appendingPathComponent("files", isDirectory: true))
                    if measuredBytes > 0 {
                        let backfilled = header.entry.updating(
                            metadata: header.entry.metadata,
                            needsDLsiteSync: header.entry.needsDLsiteSync,
                            warning: header.entry.metadataWarning,
                            byteCount: measuredBytes
                        )
                        try? persistUpdatedEntry(backfilled)
                        entries.append(backfilled)
                        continue
                    }
                }
                entries.append(header.entry)
            } catch {
                failed += 1
            }
        }
        catalog = entries.sorted(by: Self.newestFirst)
        unreadableCount = failed
    }

    private func directorySize(at root: URL) -> Int64 {
        guard let enumerator = files.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink == false else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private nonisolated static func newestFirst(_ first: LocalWorkEntry, _ second: LocalWorkEntry) -> Bool {
        (first.importedAt, first.id.uuidString) > (second.importedAt, second.id.uuidString)
    }

    func loadWork(_ id: UUID) throws -> SourceWork {
        let manifest = try read(id)
        let root = contentDirectory(for: id)
        return SourceWork(work: manifest.entry.presentation(in: root), tracks: resolve(manifest.tracks, in: root),
                          metadataWarning: manifest.entry.metadataWarning, onlineWorkID: manifest.entry.onlineWorkID)
    }

    nonisolated func contentDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathComponent("files", isDirectory: true)
    }

    func inspect(_ source: URL) throws -> LocalImportPlan {
        try coordinatedRead(source) { url in
            let manifest = try scan(url, id: UUID())
            return LocalImportPlan(source: source, title: manifest.entry.title, bytes: manifest.bytes)
        }
    }

    func importWork(_ plan: LocalImportPlan) throws -> LocalWorkEntry {
        try prepareDirectory()
        let id = UUID()
        let staging = directory.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        let destination = staging.appendingPathComponent("files", isDirectory: true)
        defer { try? files.removeItem(at: staging) }

        let manifest = try coordinatedRead(plan.source) { source in
            let scan = try scan(source, id: id)
            let volume = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let available = volume?.volumeAvailableCapacity, Int64(available) < scan.bytes {
                throw LocalLibraryError.insufficientSpace
            }
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            try copy(scan.tracks, from: source, to: destination)
            return LocalWorkManifest(entry: scan.entry, tracks: scan.tracks)
        }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("index.json"), options: .atomic)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: workDirectory(id))
        catalog?.append(manifest.entry)
        catalog?.sort(by: Self.newestFirst)
        return manifest.entry
    }

    func remove(_ id: UUID) throws {
        try prepareDirectory()
        let workDir = workDirectory(id)
        if files.fileExists(atPath: workDir.path) {
            let staging = directory.appendingPathComponent(".remove-\(id.uuidString)", isDirectory: true)
            try files.moveItem(at: workDir, to: staging)
            try? files.removeItem(at: staging)
        }
        catalog?.removeAll { $0.id == id }
    }

    func syncPendingDLsiteMetadataIfNeeded() async -> Bool {
        if catalog == nil { try? loadCatalog() }
        var didUpdate = false
        var attemptedIDs: Set<UUID> = []
        while !Task.isCancelled {
            guard let entry = (catalog ?? []).first(where: { $0.needsDLsiteSync && !attemptedIDs.contains($0.id) }) else {
                break
            }
            attemptedIDs.insert(entry.id)
            if await performDLsiteSync(for: entry) {
                didUpdate = true
            }
        }
        return didUpdate
    }

    private func performDLsiteSync(for entry: LocalWorkEntry) async -> Bool {
        guard entry.onlineWorkID == nil, let rjCode = RJCodeExtractor.extract(from: entry.folderName) else {
            try? persistUpdatedEntry(entry.updating(metadata: entry.metadata, needsDLsiteSync: false, warning: entry.metadataWarning))
            return false
        }
        let root = contentDirectory(for: entry.id)
        let jsonURL = root.appendingPathComponent("wisimi.json")
        if files.fileExists(atPath: jsonURL.path) {
            try? persistUpdatedEntry(entry.updating(metadata: entry.metadata, needsDLsiteSync: false, warning: entry.metadataWarning))
            return false
        }

        do {
            let result = try await dlsiteClient.fetchMetadata(for: rjCode)
            try Task.checkCancellation()
            guard files.fileExists(atPath: workDirectory(entry.id).path) else { return false }

            var merged = result.metadata
            merged.duration = merged.duration ?? entry.metadata.duration
            merged.cover = entry.metadata.cover
            if merged.cover == nil, let coverURL = result.coverURL {
                let coverData = try? await dlsiteClient.downloadCover(from: coverURL)
                try Task.checkCancellation()
                guard files.fileExists(atPath: workDirectory(entry.id).path) else { return false }
                if let coverData {
                    let ext = coverURL.pathExtension.isEmpty ? "jpg" : coverURL.pathExtension.lowercased()
                    let coverName = "cover.\(ext)"
                    if (try? coverData.write(to: root.appendingPathComponent(coverName), options: .atomic)) != nil {
                        merged.cover = coverName
                    }
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(merged).write(to: jsonURL, options: .atomic)
            try persistUpdatedEntry(entry.updating(metadata: merged, needsDLsiteSync: false, warning: nil))
            return true
        } catch DLsiteMetadataError.notFound {
            guard files.fileExists(atPath: workDirectory(entry.id).path) else { return false }
            try? persistUpdatedEntry(entry.updating(metadata: entry.metadata, needsDLsiteSync: false, warning: entry.metadataWarning))
            return false
        } catch {
            return false
        }
    }

    private func persistUpdatedEntry(_ updated: LocalWorkEntry, manifest: LocalWorkManifest? = nil) throws {
        let currentManifest = try manifest ?? read(updated.id)
        let updatedManifest = LocalWorkManifest(entry: updated, tracks: currentManifest.tracks)
        let indexURL = workDirectory(updated.id).appendingPathComponent("index.json")
        try JSONEncoder().encode(updatedManifest).write(to: indexURL, options: .atomic)
        if let index = catalog?.firstIndex(where: { $0.id == updated.id }) {
            catalog?[index] = updated
        }
    }

    private func prepareDirectory() throws {
        guard !isPrepared else { return }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(".import-") || url.lastPathComponent.hasPrefix(".remove-") {
            try? files.removeItem(at: url)
        }
        isPrepared = true
    }

    private func workDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func read(_ id: UUID) throws -> LocalWorkManifest {
        let index = workDirectory(id).appendingPathComponent("index.json")
        let manifest = try JSONDecoder().decode(LocalWorkManifest.self, from: Data(contentsOf: index))
        guard manifest.entry.id == id else { throw CocoaError(.fileReadCorruptFile) }
        return manifest
    }

    private func coordinatedRead<T>(_ source: URL, _ operation: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        let accessing = source.startAccessingSecurityScopedResource()
        guard accessing || !requiresSecurityScope else { throw LocalLibraryError.accessDenied }
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            result = Result { try operation(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LocalLibraryError.accessDenied }
        return try result.get()
    }

    private func scan(_ root: URL, id: UUID) throws -> (entry: LocalWorkEntry, tracks: [TrackNode], bytes: Int64) {
        var scan = Scan()
        let tracks = try scanDirectory(root, prefix: "", scan: &scan)
        guard scan.playable else { throw LocalLibraryError.noMedia }
        var metadata = LocalWorkMetadata()
        var warning: String?
        let json = root.appendingPathComponent("wisimi.json")
        let hasLocalJSON = files.fileExists(atPath: json.path)
        if hasLocalJSON {
            do {
                let values = try json.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isRegularFile == true, values.isSymbolicLink == false, let size = values.fileSize, size <= 256 * 1024 {
                    metadata = try JSONDecoder().decode(LocalWorkMetadata.self, from: Data(contentsOf: json))
                } else {
                    warning = "无法读取 wisimi.json，已使用文件夹信息。"
                }
            } catch {
                warning = "无法读取 wisimi.json，已使用文件夹信息。"
            }
        }
        if let cover = metadata.cover, !scan.images.contains(cover) {
            warning = "wisimi.json 的封面未找到，已使用默认封面。"
            metadata.cover = nil
        }
        metadata.cover = metadata.cover ?? ["cover.jpg", "cover.png"].first(where: scan.images.contains)
        let folderName = root.lastPathComponent
        let needsSync = !hasLocalJSON && RJCodeExtractor.extract(from: folderName) != nil
        let entry = LocalWorkEntry(id: id, importedAt: Date(), folderName: folderName, metadata: metadata,
                                   hasSubtitle: scan.hasSubtitle, metadataWarning: warning, needsDLsiteSync: needsSync,
                                   onlineWorkID: nil, byteCount: scan.bytes)
        return (entry, tracks, scan.bytes)
    }

    private func scanDirectory(_ folder: URL, prefix: String, scan: inout Scan) throws -> [TrackNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
        let children = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return try children.compactMap { url in
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink == false, values.isPackage != true else { return nil }
            let name = url.lastPathComponent
            let path = prefix + name
            if values.isDirectory == true {
                let tracks = try scanDirectory(url, prefix: path + "/", scan: &scan)
                guard !tracks.isEmpty else { return nil }
                return TrackNode(type: "folder", title: name, hash: path, duration: nil, children: tracks,
                                 mediaStreamUrl: nil, mediaDownloadUrl: nil, size: nil)
            }
            guard values.isRegularFile == true else { return nil }
            let type: String
            switch url.pathExtension.lowercased() {
            case "mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "caf":
                type = "audio"
                scan.playable = true
            case "mp4":
                type = "video"
                scan.playable = true
            case "lrc", "vtt":
                type = "text"
                scan.hasSubtitle = true
            case "jpg", "jpeg", "png", "webp", "gif":
                type = "image"
                scan.images.insert(path)
            default:
                return nil
            }
            scan.bytes += Int64(values.fileSize ?? 0)
            return TrackNode(type: type, title: name, hash: path, duration: nil, children: nil,
                             mediaStreamUrl: nil, mediaDownloadUrl: nil, size: values.fileSize)
        }
    }

    private func copy(_ tracks: [TrackNode], from source: URL, to destination: URL) throws {
        for track in tracks {
            try Task.checkCancellation()
            let input = source.appendingPathComponent(track.title)
            let output = destination.appendingPathComponent(track.title)
            if let children = track.children {
                try files.createDirectory(at: output, withIntermediateDirectories: false)
                try copy(children, from: input, to: output)
            } else {
                try files.copyItem(at: input, to: output)
                let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink == false else { throw LocalLibraryError.accessDenied }
            }
        }
    }

    private func resolve(_ tracks: [TrackNode], in root: URL) -> [TrackNode] {
        tracks.map { track in
            let url = root.appendingPathComponent(track.title)
            let exists = !track.isFolder && files.fileExists(atPath: url.path)
            return TrackNode(type: track.type, title: track.title, hash: track.hash, duration: track.duration,
                             children: track.children.map { resolve($0, in: url) },
                             mediaStreamUrl: exists ? url.absoluteString : nil,
                             mediaDownloadUrl: nil, size: track.size)
        }
    }
}

private enum LocalLibraryError: LocalizedError {
    case accessDenied, noMedia, insufficientSpace

    var errorDescription: String? {
        switch self {
        case .accessDenied: "无法读取所选文件夹，请在「文件」中重新选择。"
        case .noMedia: "这个文件夹中没有可导入的音频或 MP4。"
        case .insufficientSpace: "设备空间不足，无法导入此作品。"
        }
    }
}
