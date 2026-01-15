import SwiftUI

@main
struct Bunny_UploaderApp: App {

    @StateObject private var store: LibraryStore
    @StateObject private var uploads: UploadManager

    init() {
        let s = LibraryStore()
        _store = StateObject(wrappedValue: s)
        _uploads = StateObject(wrappedValue: UploadManager(store: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(uploads)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
