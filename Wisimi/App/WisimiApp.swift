import SwiftUI

@main
struct WisimiApp: App {
    init() {
        #if DEBUG
        DecodeSelfCheck.run()
        AuthSelfCheck.run()
        ASMRClientURLSelfCheck.run()
        AudioPlayerSelfCheck.run()
        WorksNavigationSelfCheck.run()
        WorkDetailStateSelfCheck.run()
        TTSMixSettingsSelfCheck.run()
        EdgeOnlineTTSSelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorksListView()
        }
    }
}
