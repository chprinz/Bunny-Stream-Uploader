import SwiftUI
import UserNotifications

@main
struct Bunny_UploaderApp: App {

    @StateObject private var store: LibraryStore
    @StateObject private var uploads: UploadManager

    init() {
        let s = LibraryStore()
        _store = StateObject(wrappedValue: s)
        _uploads = StateObject(wrappedValue: UploadManager(store: s))

        // Ask for notification permission up front for ready-state alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(uploads)
        }
        .defaultSize(width: 640, height: 760)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
