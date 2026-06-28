import SwiftUI

@main
struct WisimiApp: App {
    init() {
        #if DEBUG
        DecodeSelfCheck.run()
        AuthSelfCheck.run()
        AudioPlayerSelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorksListView()
        }
    }
}
