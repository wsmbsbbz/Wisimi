#if DEBUG
import Foundation

@MainActor
struct DebugLaunchConfig {
    let screen: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.screen = environment["WISIMI_DEBUG_SCREEN"]
    }

    static let current = DebugLaunchConfig()

    var usesLargeText: Bool {
        ProcessInfo.processInfo.environment["WISIMI_DEBUG_LARGE_TEXT"] == "1"
    }

    var isWorkActionsPreview: Bool {
        screen == "work-actions"
    }

    func makeClient() -> ASMRClient {
        screen?.hasPrefix("similar") == true ? DebugSimilarWorksFixture.client() : ASMRClient()
    }

    struct InitialState {
        var path: [WorksRoute] = []
        var showsLocalLibrary = false
        var isNarrationSettingsPresented = false
    }

    func configureInitialState(player: WorkAudioPlayer) -> InitialState {
        var state = InitialState()
        let env = ProcessInfo.processInfo.environment

        if screen?.hasPrefix("similar") == true {
            state.path = [.detail(.asmrOne(DebugSimilarWorksFixture.workID))]
            if env["WISIMI_DEBUG_SIMILAR_MINIPLAYER"] == "1" {
                try? player.prepareDebugPlayback()
            }
        }
        state.isNarrationSettingsPresented = (screen == "tts-settings" || screen == "openrouter-credentials")
        if screen?.hasPrefix("download") == true, env["WISIMI_DEBUG_DOWNLOAD_MINIPLAYER"] == "1" {
            try? player.prepareDebugPlayback()
        }
        state.showsLocalLibrary = (
            screen == "local-library" ||
            screen == "tts-settings" ||
            screen == "local-detail" ||
            screen?.hasPrefix("downloads") == true ||
            screen == "download-local-detail"
        )
        if screen == "local-detail",
           let rawID = env["WISIMI_DEBUG_LOCAL_ID"],
           let uuid = UUID(uuidString: rawID) {
            state.path = [.detail(.local(uuid))]
        }
        if screen == "player" || screen == "mini-player" || screen == "video" || screen == "narration" {
            try? player.prepareDebugPlayback()
            if screen == "narration" { try? player.prepareDebugNarrationPreview() }
            if env["WISIMI_SLEEP_TIMER"] == "1" {
                player.setSleepTimer(.deadline(.now.addingTimeInterval(1800)))
            }
            state.path = screen != "mini-player" ? [.player] : []
        }
        return state
    }

    enum InitialLoadResult {
        case notHandled
        case handled(newPath: [WorksRoute]? = nil)
    }

    func handleInitialLoadIfNeeded(
        pageState: WorksPageState,
        player: WorkAudioPlayer
    ) async -> InitialLoadResult {
        if screen == "local-library" { return .handled() }
        if let screen, screen.hasPrefix("download") {
            var newPath: [WorksRoute]?
            do {
                try await DownloadStore.shared.prepareDebugDownloads()
                if screen == "download-local-detail", let saved = DownloadStore.shared.savedWork(id: 99999999) {
                    newPath = [.detail(.local(saved.localWorkID))]
                }
            } catch {
                DownloadStore.shared.message = error.localizedDescription
            }
            return .handled(newPath: newPath)
        }
        if screen == "list-error" {
            let json = #"{"works":[{"id":1,"title":"晚安 · 轻声陪伴与耳边细语","name":"Wisimi","has_subtitle":true,"tags":[],"vas":[]}],"pagination":{"currentPage":1,"pageSize":12,"totalCount":36}}"#
            await pageState.load(page: 1) {
                try JSONDecoder().decode(WorksResponse.self, from: Data(json.utf8))
            }
            await pageState.load(page: 2) { throw URLError(.notConnectedToInternet) }
            return .handled()
        }
        if screen == "video" {
            do { try await player.prepareDebugVideoPlayback() }
            catch { assertionFailure("Video preview failed: \(error)") }
            return .handled()
        }
        return .notHandled
    }
}
#endif
