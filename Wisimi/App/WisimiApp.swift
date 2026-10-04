import SwiftUI

@main
struct WisimiApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    init() {
        #if DEBUG
        DecodeSelfCheck.run()
        VideoTrackSelfCheck.run()
        AuthSelfCheck.run()
        ASMRClientURLSelfCheck.run()
        PlaybackStateSelfCheck.run()
        SleepTimerSelfCheck.run()
        AudioPlayerSelfCheck.run()
        WorksNavigationSelfCheck.run()
        WorksFilterContextSelfCheck.run()
        WorkDetailStateSelfCheck.run()
        TTSMixSettingsSelfCheck.run()
        TTSModelsSelfCheck.run()
        EdgeOnlineTTSSelfCheck.run()
        OpenRouterTTSSelfCheck.run()
        OpenRouterTokenStoreSelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorksListView()
        }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadStore.sessionIdentifier else { completionHandler(); return }
        DownloadStore.shared.backgroundCompletion = completionHandler
    }
}
