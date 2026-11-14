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

enum WorksFilterContextSelfCheck {
    static func run() {
        assert(WorksFilterContext.resolve(isSearchActive: true, mode: .favorites) == .works)
        assert(WorksFilterContext.resolve(isSearchActive: true, mode: .playlists) == .works)
        assert(WorksFilterContext.resolve(isSearchActive: false, mode: .favorites) == .favorites)
        assert(WorksFilterContext.resolve(isSearchActive: false, mode: .playlists) == .playlists)
        assert(WorksFilterContext.resolve(isSearchActive: false, mode: .latest) == .works)
        assert(WorksFilterContext.resolve(isSearchActive: false, mode: .popular) == .works)
        assert(WorksFilterContext.resolve(isSearchActive: false, mode: .recommended) == .works)
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

enum WorksNavigationSelfCheck {
    static func run() {
        let online = WorkReference.asmrOne(1)
        let local = WorkReference.local(UUID())
        assert(WorksRoute.replacingPlayer(withDetail: online, in: [.player]) == [.detail(online)])
        assert(WorksRoute.replacingPlayer(withDetail: online, in: [.detail(online), .player]) == [.detail(online)])
        assert(WorksRoute.replacingPlayer(withDetail: local, in: [.detail(online), .player]) == [.detail(online), .detail(local)])
    }
}
