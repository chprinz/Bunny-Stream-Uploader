import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var uploads: UploadManager

    @State private var selectedLibraryId: UUID?

    private var currentLibrary: LibraryConfig? {
        store.libraries.first(where: { selectedLibraryId != nil && $0.id == selectedLibraryId! })
    }

    private var defaultCollectionName: String? {
        guard let lib = currentLibrary,
              let colId = store.defaultCollection(for: lib),
              let col = store.collections[lib.id]?.first(where: { $0.id == colId })
        else { return nil }
        return col.name
    }

    var body: some View {
        VStack(spacing: 0) {

            // Top bar with library picker and settings
            HStack(spacing: 12) {
                Picker("Library", selection:
                    Binding(
                        get: {
                            selectedLibraryId ?? store.libraries.first?.id
                        },
                        set: { newValue in
                            selectedLibraryId = newValue
                        }
                    )
                ) {
                    ForEach(store.libraries) { lib in
                        Text(lib.name).tag(Optional(lib.id))
                    }
                }
                .frame(minWidth: 260)

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Drop area in center
            UploadDropArea(defaultLibrary: currentLibrary,
                           defaultCollectionName: defaultCollectionName)
                .padding(.top, 18)
                .padding(.horizontal, 24)

            // Upload list
            UploadListView(selectedLibraryId: selectedLibraryId)
                .padding(.top, 12)

            // Bottom status bar with centered buttons
            HStack(spacing: 24) {
                Button {
                    uploads.pauseAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.circle")
                        Text("Pause All")
                    }
                }

                Button {
                    uploads.resumeAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                        Text("Resume All")
                    }
                }

            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 640,
               minHeight: 600, idealHeight: 660, maxHeight: 800)
        .onAppear {
            if let saved = store.loadLastSelectedLibrary() {
                selectedLibraryId = saved.id
            } else if let first = store.libraries.first {
                selectedLibraryId = first.id
            }
        }
        .onReceive(store.$libraries) { libs in
            if let saved = store.loadLastSelectedLibrary(),
               libs.contains(where: { $0.id == saved.id }) {
                selectedLibraryId = saved.id
            } else if let first = libs.first {
                selectedLibraryId = first.id
            }
        }
    }
}
