import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var uploads: UploadManager

    @State private var selectedLibraryId: UUID?
    @State private var didNormalizeWindow = false

    private var currentLibrary: LibraryConfig? {
        guard let sel = selectedLibraryId else { return nil }
        return store.libraries.first(where: { $0.id == sel })
    }

    private var librarySelection: Binding<UUID?> {
        Binding(
            get: {
                // ensure the selection always maps to a real tag in the picker
                if let sel = selectedLibraryId,
                   store.libraries.contains(where: { $0.id == sel }) {
                    return sel
                }
                return store.libraries.first?.id
            },
            set: { selectedLibraryId = $0 }
        )
    }

    private var defaultCollectionName: String? {
        guard let lib = currentLibrary,
              let colId = store.defaultCollection(for: lib)
        else { return nil }
        if let col = store.collections[lib.id]?.first(where: { $0.id == colId }) {
            return col.name
        }
        // fall back to ID if name is not yet loaded
        return colId
    }

    var body: some View {
        VStack(spacing: 0) {

            // Top bar with library picker and settings
            HStack(spacing: 12) {
                Picker("Library", selection: librarySelection) {
                    ForEach(store.libraries) { lib in
                        Text(lib.name).tag(Optional(lib.id))
                    }
                }
                .frame(minWidth: 260, maxWidth: 320, minHeight: 32)

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

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
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 680,
               minHeight: 620, idealHeight: 700, maxHeight: 820)
        .onAppear {
            normalizeWindowWidthIfNeeded()
            if let saved = store.loadLastSelectedLibrary(),
               store.libraries.contains(where: { $0.id == saved.id }) {
                selectedLibraryId = saved.id
            } else if let first = store.libraries.first {
                selectedLibraryId = first.id
            } else {
                selectedLibraryId = nil
            }
            if let sel = selectedLibraryId {
                store.saveLastSelectedLibrary(id: sel)
            } else {
                store.saveLastSelectedLibrary(id: nil)
            }
            if let lib = currentLibrary {
                store.loadCollections(for: lib)
            }
        }
        .onReceive(store.$libraries) { libs in
            if let saved = store.loadLastSelectedLibrary(),
               libs.contains(where: { $0.id == saved.id }) {
                selectedLibraryId = saved.id
            } else if let first = libs.first {
                selectedLibraryId = first.id
            } else {
                selectedLibraryId = nil
            }
            if let sel = selectedLibraryId {
                store.saveLastSelectedLibrary(id: sel)
            } else {
                store.saveLastSelectedLibrary(id: nil)
            }
        }
        .onChange(of: selectedLibraryId) { _, newValue in
            if let libId = newValue,
               let lib = store.libraries.first(where: { $0.id == libId }) {
                store.loadCollections(for: lib)
                store.saveLastSelectedLibrary(id: libId)
            } else {
                store.saveLastSelectedLibrary(id: nil)
            }
        }
    }

    // MARK: - Window sizing

    private func normalizeWindowWidthIfNeeded() {
        guard !didNormalizeWindow else { return }
        guard let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.mainWindow else { return }

        let targetWidth: CGFloat = 680
        let minWidth: CGFloat = 520
        let current = window.frame
        let clampedWidth = min(max(current.size.width, minWidth), targetWidth)
        if abs(current.size.width - clampedWidth) < 1 {
            didNormalizeWindow = true
            return
        }

        let delta = current.size.width - clampedWidth
        let newOrigin = NSPoint(x: current.origin.x + delta / 2, y: current.origin.y)
        let newFrame = NSRect(x: newOrigin.x, y: newOrigin.y, width: clampedWidth, height: current.size.height)
        window.setFrame(newFrame, display: true, animate: false)

        didNormalizeWindow = true
    }
}
