import SwiftUI

@main
struct WisimiApp: App {
    init() {
        #if DEBUG
        DecodeSelfCheck.run()
        AudioPlayerSelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorksListView()
        }
    }
}
