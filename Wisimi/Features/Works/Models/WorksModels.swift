import Foundation

struct WorksResponse: Decodable {
    let works: [WorkSummary]
    let pagination: WorksPagination
}

nonisolated struct WorksPagination: Decodable, Sendable {
    let currentPage: Int
    let pageSize: Int
    let totalCount: Int

    private enum CodingKeys: String, CodingKey {
        case currentPage
        case page
        case pageSize
        case totalCount
    }

    init(currentPage: Int, pageSize: Int, totalCount: Int) {
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.totalCount = totalCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = try container.decodeIfPresent(Int.self, forKey: .currentPage)
            ?? container.decode(Int.self, forKey: .page)
        pageSize = try container.decode(Int.self, forKey: .pageSize)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
    }

    var totalPages: Int {
        guard pageSize > 0 else { return 1 }
        return max(Int(ceil(Double(totalCount) / Double(pageSize))), 1)
    }
}

struct PlaylistsResponse: Decodable {
    let playlists: [PlaylistSummary]
    let pagination: WorksPagination
}

struct PlaylistSummary: Decodable, Identifiable, Equatable {
    let id: String
    var name: String
    let privacy: Int
    let description: String
    var worksCount: Int
    var exist: Bool

    var countText: String { "\(worksCount) 个作品" }
    var displayName: String {
        switch name {
        case "__SYS_PLAYLIST_LIKED": "我喜欢的"
        case "__SYS_PLAYLIST_MARKED": "我标记的"
        default: name
        }
    }
    var isSystemPreserved: Bool { name.hasPrefix("__SYS_PLAYLIST_") }
    var systemImage: String? { isSystemPreserved ? "lock.fill" : nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case privacy
        case description
        case worksCount = "works_count"
        case exist
    }

    init(id: String, name: String, privacy: Int, description: String, worksCount: Int, exist: Bool = false) {
        self.id = id
        self.name = name
        self.privacy = privacy
        self.description = description
        self.worksCount = worksCount
        self.exist = exist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        privacy = try container.decode(Int.self, forKey: .privacy)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        worksCount = try container.decodeIfPresent(Int.self, forKey: .worksCount) ?? 0
        exist = try container.decodeIfPresent(Bool.self, forKey: .exist) ?? false
    }
}

struct WorkSummary: Decodable, Identifiable {
    let id: Int
    let title: String
    let name: String
    let duration: Double?
    let rateAverage: Double?
    let hasSubtitle: Bool
    let thumbnailCover: String?
    let tags: [NameItem]
    let vas: [NameItem]

    var thumbnailCoverURL: URL? { thumbnailCover.flatMap(URL.init(string:)) }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case duration
        case rateAverage = "rate_average_2dp"
        case hasSubtitle = "has_subtitle"
        case thumbnailCover = "thumbnailCoverUrl"
        case tags
        case vas
    }
}

struct WorkDetail: Codable {
    let id: Int
    let title: String
    let name: String
    let duration: Double?
    let dlCount: Int
    let rateAverage: Double?
    let hasSubtitle: Bool
    let mainCover: String?
    let progress: ReviewStatus?
    let tags: [NameItem]
    let vas: [NameItem]

    var mainCoverURL: URL? { mainCover.flatMap(URL.init(string:)) }
    var rjCode: String { "RJ\(id)" }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case duration
        case dlCount = "dl_count"
        case rateAverage = "rate_average_2dp"
        case hasSubtitle = "has_subtitle"
        case mainCover = "mainCoverUrl"
        case progress
        case tags
        case vas
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        name = try container.decode(String.self, forKey: .name)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        dlCount = try container.decode(Int.self, forKey: .dlCount)
        rateAverage = try container.decodeIfPresent(Double.self, forKey: .rateAverage)
        hasSubtitle = try container.decode(Bool.self, forKey: .hasSubtitle)
        mainCover = try container.decodeIfPresent(String.self, forKey: .mainCover)
        progress = try container.decodeIfPresent(String.self, forKey: .progress).flatMap(ReviewStatus.init(rawValue:))
        tags = try container.decode([NameItem].self, forKey: .tags)
        vas = try container.decode([NameItem].self, forKey: .vas)
    }
}

nonisolated struct NameItem: Codable, Identifiable, Sendable {
    let id: FlexibleID
    let name: String
}

nonisolated struct TrackNode: Codable, Identifiable, Sendable {
    let type: String
    let title: String
    let hash: String?
    let duration: Double?
    let children: [TrackNode]?
    let mediaStreamUrl: String?
    let mediaDownloadUrl: String?
    let size: Int?

    var id: String { hash ?? "\(type)-\(title)" }
    var isVideo: Bool { !isFolder && (type == "video" || title.lowercased().hasSuffix(".mp4")) }
    var isAudio: Bool { type == "audio" && !isVideo }
    var isPlayable: Bool { isAudio || isVideo }
    var isFolder: Bool { type == "folder" }
    private static let readableTextExtensions = [".txt", ".vtt", ".lrc", ".srt", ".md", ".log"]

    var isSubtitle: Bool { title.lowercased().hasSuffix(".vtt") || title.lowercased().hasSuffix(".lrc") }
    var isReadableText: Bool {
        !isFolder && Self.readableTextExtensions.contains { title.lowercased().hasSuffix($0) }
    }
    var isImage: Bool {
        [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { title.lowercased().hasSuffix($0) }
    }
    var playbackURL: URL? {
        guard isPlayable else { return nil }
        return (mediaStreamUrl ?? mediaDownloadUrl).flatMap(URL.init(string:))
    }
    var imagePreviewURL: URL? {
        guard isImage else { return nil }
        return (mediaStreamUrl ?? mediaDownloadUrl).flatMap(URL.init(string:))
    }
    var textPreviewURL: URL? {
        guard isReadableText else { return nil }
        return (mediaStreamUrl ?? mediaDownloadUrl).flatMap(URL.init(string:))
    }
    var downloadSourceURL: URL? {
        guard !isFolder else { return nil }
        return (mediaDownloadUrl ?? mediaStreamUrl).flatMap(URL.init(string:))
    }
    var durationText: String { duration.formattedDuration }
}

extension Array where Element == TrackNode {
    func matchingSubtitle(for audio: TrackNode) -> TrackNode? {
        let base = (audio.title as NSString).deletingPathExtension.lowercased()
        let subtitleFiles = filter(\.isSubtitle)
        return subtitleFiles.first { $0.title.lowercased() == "\(base).vtt" || $0.title.lowercased() == "\(base).lrc" }
            ?? subtitleFiles.first { file in
                let subtitleBase = (file.title as NSString).deletingPathExtension.lowercased()
                return subtitleBase.hasPrefix(base) || base.hasPrefix(subtitleBase)
            }
    }

    var downloadableFiles: [TrackNode] {
        flatMap { node in
            node.isFolder ? (node.children ?? []).downloadableFiles : (node.downloadSourceURL == nil ? [] : [node])
        }
    }

    var playableTracks: [TrackNode] {
        filter { $0.isPlayable && $0.playbackURL != nil }
    }

    var defaultDirectoryPath: [TrackNode] {
        count == 1 && self[0].isFolder ? [self[0]] : []
    }
}

nonisolated struct FlexibleID: Codable, Hashable, Sendable {
    let value: String

    init(_ value: String) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}


extension Array where Element == TrackNode {
    func resolvingDirectoryPath(ids: [TrackNode.ID]) -> [TrackNode]? {
        guard !ids.isEmpty else { return [] }

        var siblings = self
        var resolvedPath: [TrackNode] = []
        for id in ids {
            guard let folder = siblings.first(where: { $0.id == id && $0.isFolder }) else { return nil }
            resolvedPath.append(folder)
            siblings = folder.children ?? []
        }
        return resolvedPath
    }
}

enum TrackTextDecodeError: LocalizedError {
    case fileTooLarge(limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let limitBytes):
            return "文件超过 \(limitBytes / 1_000_000) MB，暂不支持预览。"
        }
    }
}

enum TrackTextDecoder {
    static let defaultMaxBytes = 2_000_000

    static func decode(_ data: Data, maxBytes: Int = defaultMaxBytes) throws -> String {
        guard data.count <= maxBytes else {
            throw TrackTextDecodeError.fileTooLarge(limitBytes: maxBytes)
        }
        if data.isEmpty { return "" }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if encoding != 0, let text = converted as String? {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}
