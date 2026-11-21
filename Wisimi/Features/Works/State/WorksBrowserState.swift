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

    func reload(token: String?, recommenderUUID: String?) async {
        page.reset()
        await load(page: 1, token: token, recommenderUUID: recommenderUUID)
    }

    func load(page requestedPage: Int = 1, token: String?, recommenderUUID: String?) async {
        guard requestedPage >= 1 else { return }
        if let totalPages = page.pagination?.totalPages, requestedPage > totalPages { return }
        let keyword = keyword, mode = mode, filter = filter, reviewFilter = reviewFilter
        await page.load(page: requestedPage) {
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
