import SwiftUI

@main
struct WisimiApp: App {
    init() {
        #if DEBUG
        DecodeSelfCheck.run()
        AuthSelfCheck.run()
        ASMRClientURLSelfCheck.run()
        PlaybackStateSelfCheck.run()
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
