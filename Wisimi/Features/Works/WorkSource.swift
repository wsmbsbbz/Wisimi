import Foundation

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
}

@MainActor
struct OnlineWorkSource {
    let client: ASMRClient
    var cachedWork: @MainActor (Int) -> DownloadedWork? = { DownloadStore.shared.savedWork(id: $0) }

    func loadWork(_ id: Int, token: String? = nil) async throws -> DownloadedWork {
        let (work, tracks) = try await client.fetchWorkWithTracks(id: id, token: token)
        return DownloadedWork(work: work, tracks: tracks)
    }
}

@MainActor
struct WorkSource {
    let online: OnlineWorkSource
    let library: LocalWorkLibrary

    func loadWork(_ reference: WorkReference) async throws -> SourceWork {
        switch reference {
        case .asmrOne(let id):
            let snapshot: DownloadedWork
            if let saved = online.cachedWork(id) { snapshot = saved }
            else { snapshot = try await online.loadWork(id) }
            return SourceWork(work: snapshot.work.presentation, tracks: snapshot.tracks)
        case .local(let id):
            return try await library.loadWork(id)
        }
    }

    static func resourceURL(for track: TrackNode, in reference: WorkReference?, fallback: URL?) -> URL? {
        reference?.onlineID.flatMap { DownloadStore.shared.localURL(for: track, workID: $0) } ?? fallback
    }

    func subtitleText(at url: URL) async throws -> String {
        if url.isFileURL { return try String(contentsOf: url, encoding: .utf8) }
        return try await online.client.fetchText(url)
    }
}
