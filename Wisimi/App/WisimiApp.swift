import SwiftUI

@main
struct WisimiApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate

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
