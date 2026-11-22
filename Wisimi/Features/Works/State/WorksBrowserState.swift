import Foundation
import Observation

@MainActor
@Observable
final class WorksBrowserState {
    let page = WorksPageState()
    let catalog: PlaylistCatalog
    var mode: WorksMode = .latest
    var keyword = ""
    var filter = WorksFilter.default
    var reviewFilter = ReviewFilter.default
    private let client: ASMRClient

    init(client: ASMRClient, catalog: PlaylistCatalog) {
        self.client = client
        self.catalog = catalog
    }

    var filterContext: WorksFilterContext {
        WorksFilterContext.resolve(isSearchActive: !keyword.isEmpty, mode: mode)
    }

    var summaryText: String? {
        let totalCount = page.pagination?.totalCount
        let countText = totalCount.map { "共 \($0) 部" }

        if !keyword.isEmpty {
            let parts = ["搜索：\(keyword)"] + filterParts(includeSort: true, countText: countText)
            return parts.joined(separator: " · ")
        }

        switch mode {
        case .favorites:
            var parts = [
                reviewFilter.status.title,
                reviewFilter.order.title,
                reviewFilter.sort.title(for: reviewFilter.order)
            ]
            if let countText { parts.append(countText) }
            return parts.joined(separator: " · ")
        case .playlists:
            guard let selectedPlaylist = catalog.selectedPlaylist else { return "播放列表" }
            let count = totalCount ?? selectedPlaylist.worksCount
            return "\(selectedPlaylist.displayName) · \(count) 个作品"
        case .latest:
            let parts = filterParts(includeSort: true, countText: countText)
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .popular, .recommended:
            let parts = filterParts(includeSort: false, countText: countText)
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private func filterParts(includeSort: Bool, countText: String?) -> [String] {
        var parts: [String] = []
        if filter.hasSubtitle { parts.append("有字幕") }
        if includeSort, hasCustomSort { parts.append("\(filter.order.title) \(filter.sort.title)") }
        if let countText { parts.append(countText) }
        return parts
    }

    private var hasCustomSort: Bool {
        filter.order != WorksFilter.default.order || filter.sort != WorksFilter.default.sort
    }

    func reload(token: String?, recommenderUUID: String?) async {
        page.reset()
        await load(page: 1, token: token, recommenderUUID: recommenderUUID)
    }

    func load(page requestedPage: Int = 1, token: String?, recommenderUUID: String?) async {
        guard requestedPage >= 1 else { return }
        if let totalPages = page.pagination?.totalPages, requestedPage > totalPages { return }
        let keyword = keyword, mode = mode, filter = filter, reviewFilter = reviewFilter
        await page.loadWorks(page: requestedPage) {
            if !keyword.isEmpty {
                return try await self.client.searchWorks(keyword: keyword, page: requestedPage, filter: filter)
            }
            switch mode {
            case .latest:
                return try await self.client.fetchWorks(page: requestedPage, filter: filter)
            case .popular:
                return try await self.client.fetchPopular(page: requestedPage, filter: filter)
            case .favorites:
                guard let token else { throw ASMRClientError.loginRequired }
                return try await self.client.fetchFavorites(page: requestedPage, token: token, filter: reviewFilter)
            case .playlists:
                guard let token else { throw ASMRClientError.loginRequired }
                let id = try await self.catalog.ensureSelection(token: token)
                try Task.checkCancellation()
                return try await self.client.fetchPlaylistWorks(id: id, page: requestedPage, token: token)
            case .recommended:
                guard let token else { throw ASMRClientError.loginRequired }
                guard let recommenderUUID, !recommenderUUID.isEmpty else { throw ASMRClientError.missingRecommenderUuid }
                return try await self.client.fetchRecommended(page: requestedPage, uuid: recommenderUUID, token: token, filter: filter)
            }
        }
    }
}
