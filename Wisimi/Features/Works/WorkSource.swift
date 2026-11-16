import Foundation

nonisolated struct WorkCardSummary: Identifiable, Sendable {
    let id: WorkReference
    let title: String
    let circle: String?
    let duration: Double?
    let rating: Double?
    let hasSubtitle: Bool
    let coverURL: URL?
    let tags: [NameItem]
    let voiceActors: [NameItem]
}

extension WorkSummary {
    var card: WorkCardSummary {
        WorkCardSummary(id: .asmrOne(id), title: title, circle: name, duration: duration,
                        rating: rateAverage, hasSubtitle: hasSubtitle, coverURL: thumbnailCoverURL,
                        tags: tags, voiceActors: vas)
    }
}

extension WorkPresentation {
    nonisolated var card: WorkCardSummary {
        WorkCardSummary(id: reference, title: title, circle: circle, duration: duration,
                        rating: rating, hasSubtitle: hasSubtitle, coverURL: coverURL,
                        tags: tags, voiceActors: voiceActors)
    }
}

nonisolated struct WorkCatalogPage: Sendable {
    let works: [WorkCardSummary]
    let pagination: WorksPagination
    let unreadableCount: Int
    var totalBytes: Int64 = 0
}

protocol WorkCatalog: Sendable {
    func page(_ number: Int, pageSize: Int, refresh: Bool) async throws -> WorkCatalogPage
}

nonisolated struct WorkPresentation: Sendable {
    let reference: WorkReference
    let title: String
    let circle: String?
    let duration: Double?
    let rating: Double?
    let sales: Int?
    let catalogCode: String?
    let hasSubtitle: Bool
    let coverURL: URL?
    let tags: [NameItem]
    let voiceActors: [NameItem]
}

extension WorkDetail {
    var presentation: WorkPresentation {
        WorkPresentation(reference: .asmrOne(id), title: title, circle: name, duration: duration,
                         rating: rateAverage, sales: dlCount, catalogCode: rjCode, hasSubtitle: hasSubtitle,
                         coverURL: mainCoverURL, tags: tags, voiceActors: vas)
    }
}

nonisolated struct SourceWork: Sendable {
    let work: WorkPresentation
    let tracks: [TrackNode]
    var metadataWarning: String? = nil
    var onlineWorkID: Int? = nil
}

struct OnlineWorkSnapshot {
    let work: WorkDetail
    let tracks: [TrackNode]
}

@MainActor
struct OnlineWorkSource {
    let client: ASMRClient

    func loadWork(_ id: Int, token: String? = nil) async throws -> OnlineWorkSnapshot {
        let (work, tracks) = try await client.fetchWorkWithTracks(id: id, token: token)
        return OnlineWorkSnapshot(work: work, tracks: tracks)
    }
}

@MainActor
struct WorkSource {
    let online: OnlineWorkSource
    let library: LocalWorkLibrary

    func loadWork(_ reference: WorkReference) async throws -> SourceWork {
        switch reference {
        case .asmrOne(let id):
            let snapshot = try await online.loadWork(id)
            return SourceWork(work: snapshot.work.presentation, tracks: snapshot.tracks, onlineWorkID: id)
        case .local(let id):
            return try await library.loadWork(id)
        }
    }

    func subtitleText(at url: URL) async throws -> String {
        if url.isFileURL { return try TrackTextDecoder.decode(Data(contentsOf: url)) }
        return try await online.client.fetchText(url)
    }
}
