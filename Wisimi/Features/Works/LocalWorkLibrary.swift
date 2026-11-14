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

    var title: String { Self.text(metadata.title) ?? folderName }

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

actor LocalWorkLibrary {
    static let shared = LocalWorkLibrary()

    private struct Manifest: Codable {
        let entry: LocalWorkEntry
        let tracks: [TrackNode]
    }

    private struct Scan {
        var playable = false
        var hasSubtitle = false
        var images: Set<String> = []
        var bytes: Int64 = 0
    }

    nonisolated let directory: URL
    private let requiresSecurityScope: Bool
    private let files = FileManager.default
    private var isPrepared = false

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "LocalWorks", directoryHint: .isDirectory),
         requiresSecurityScope: Bool = true) {
        self.directory = directory
        self.requiresSecurityScope = requiresSecurityScope
    }

    func list() throws -> [LocalWorkEntry] {
        try prepareDirectory()
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { URL in
                guard let id = UUID(uuidString: URL.lastPathComponent) else { return nil }
                return try read(id).entry
            }
            .sorted { ($0.importedAt, $0.id.uuidString) > ($1.importedAt, $1.id.uuidString) }
    }

    func loadWork(_ id: UUID) throws -> SourceWork {
        let manifest = try read(id)
        let root = contentDirectory(for: id)
        return SourceWork(work: manifest.entry.presentation(in: root), tracks: resolve(manifest.tracks, in: root),
                          metadataWarning: manifest.entry.metadataWarning)
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
            return Manifest(entry: scan.entry, tracks: scan.tracks)
        }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("index.json"), options: .atomic)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: workDirectory(id))
        return manifest.entry
    }

    func remove(_ id: UUID) throws {
        try prepareDirectory()
        let staging = directory.appendingPathComponent(".remove-\(id.uuidString)", isDirectory: true)
        try files.moveItem(at: workDirectory(id), to: staging)
        try? files.removeItem(at: staging)
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

    private func read(_ id: UUID) throws -> Manifest {
        let index = workDirectory(id).appendingPathComponent("index.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: index))
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
        if files.fileExists(atPath: json.path) {
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
        let entry = LocalWorkEntry(id: id, importedAt: Date(), folderName: root.lastPathComponent, metadata: metadata,
                                   hasSubtitle: scan.hasSubtitle, metadataWarning: warning)
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
            return TrackNode(type: track.type, title: track.title, hash: track.hash, duration: track.duration,
                             children: track.children.map { resolve($0, in: url) },
                             mediaStreamUrl: track.isFolder ? nil : url.absoluteString,
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
