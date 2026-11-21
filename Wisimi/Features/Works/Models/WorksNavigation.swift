import Foundation

enum WorksMode: String, CaseIterable, Identifiable {
    case latest
    case popular
    case favorites
    case playlists
    case recommended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: "最新"
        case .popular: "热门作品"
        case .favorites: "收藏"
        case .playlists: "播放列表"
        case .recommended: "推荐作品"
        }
    }

    var systemImage: String {
        switch self {
        case .latest: "clock"
        case .popular: "flame"
        case .favorites: "heart"
        case .playlists: "music.note.list"
        case .recommended: "sparkles"
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .latest, .popular: false
        case .favorites, .playlists, .recommended: true
        }
    }
}

enum WorksFilterContext: Equatable {
    case works
    case favorites
    case playlists

    static func resolve(isSearchActive: Bool, mode: WorksMode) -> Self {
        guard !isSearchActive else { return .works }

        return switch mode {
        case .favorites: .favorites
        case .playlists: .playlists
        case .latest, .popular, .recommended: .works
        }
    }
}

nonisolated enum WorkReference: Hashable, Sendable {
    case asmrOne(Int)
    case local(UUID)

    var onlineID: Int? {
        if case .asmrOne(let id) = self { return id }
        return nil
    }

    var localID: UUID? {
        if case .local(let id) = self { return id }
        return nil
    }
}

enum WorksRoute: Hashable {
    case detail(WorkReference)
    case player

    static func replacingPlayer(withDetail workID: WorkReference, in path: [Self]) -> [Self] {
        guard path.last == .player else { return path }
        let previousPath = path.dropLast()
        return previousPath.last == .detail(workID) ? Array(previousPath) : previousPath + [.detail(workID)]
    }
}
