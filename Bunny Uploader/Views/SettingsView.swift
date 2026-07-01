import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
    
struct SettingsView: View {

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var uploads: UploadManager

    @State private var selectedLibraryID: UUID? = nil
    @State private var nameCache: String = ""
    @State private var apiKeyCache: String = ""
    @State private var selectedCollection: String = ""
    @State private var pullZoneHostCache: String = ""

    @AppStorage("autoResumeUploads") private var autoResumeUploads: Bool = true
    @AppStorage("maxConcurrentUploads") private var maxConcurrentUploads: Int = 1

    @State private var showAddLibrarySheet: Bool = false
    @State private var newLibName: String = ""
    @State private var newLibID: String = ""
    @State private var newLibKey: String = ""
    @State private var diagnosticsMessage: String = ""

    var selectedLibrary: LibraryConfig? {
        store.libraries.first(where: { $0.id == selectedLibraryID })
    }

    var body: some View {
        VStack(spacing: 18) {

            Text("Libraries")
                .font(.title3.weight(.semibold))
                .padding(.horizontal)
                .padding(.top, 6)

            // MARK: Library Selector (horizontal Pills)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.libraries) { lib in
                        Button {
                            selectLibrary(lib)
                        } label: {
                            Text(lib.name)
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(minHeight: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selectedLibraryID == lib.id
                                              ? Color("AccentColor").opacity(0.2)
                                              : Color.primary.opacity(0.07))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(selectedLibraryID == lib.id
                                                ? Color("AccentColor").opacity(0.7)
                                                : Color.primary.opacity(0.08),
                                                lineWidth: 1)
                                )
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename") { nameCache = lib.name }
                            Button("Delete library", role: .destructive) {
                                store.deleteLibrary(lib)
                                if selectedLibraryID == lib.id {
                                    selectedLibraryID = nil
                                }
                            }
                        }
                    }

                    // Add new library
                    Button {
                        showAddLibrarySheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(minHeight: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
            .padding(.horizontal)

            Divider()

            // MARK: Details Panel
            if let lib = selectedLibrary {
                VStack(alignment: .leading, spacing: 14) {

                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        TextField("Name", text: Binding(
                            get: { nameCache },
                            set: { newVal in
                                nameCache = newVal
                                store.renameLibrary(id: lib.id, newName: newVal)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    }

                    // Library ID (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library ID")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        Text(lib.libraryId)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // API Key
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        SecureField("AccessKey", text: Binding(
                            get: { apiKeyCache },
                            set: { newVal in
                                apiKeyCache = newVal
                                KeychainService.save(key: lib.id.uuidString, value: newVal)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    }

                    // Pull Zone Host
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CDN Host (pull zone)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        TextField("vz-xxxx.b-cdn.net", text: Binding(
                            get: { pullZoneHostCache },
                            set: { newVal in
                                pullZoneHostCache = newVal
                                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                store.setPullZoneHost(for: lib, host: trimmed.isEmpty ? nil : trimmed)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                        Text("Optional. Use your pull zone host, e.g. vz-12345.b-cdn.net")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 1)
                            Text("No thumbnail preview? Disable \"Block direct URL file access\" in Bunny Stream Security.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    // Default Collection (Dropdown)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Collection")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        Picker("Default Collection", selection: Binding(
                            get: { selectedCollection },
                            set: { newVal in
                                selectedCollection = newVal
                                store.setDefaultCollection(for: lib,
                                                           collectionId: newVal.isEmpty ? nil : newVal)
                            }
                        )) {
                            Text("None").tag("")

                            ForEach(store.collections[lib.id] ?? []) { col in
                                Text(col.name).tag(col.id)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Divider().padding(.vertical, 6)

                    // Delete Button
                    Button(role: .destructive) {
                        store.deleteLibrary(lib)
                        selectedLibraryID = nil
                    } label: {
                        Text("Delete library")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)

                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
            } else {
                Text("Select a library to edit its settings")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.top, 24)
            }

            // MARK: Upload Behavior
            VStack(alignment: .leading, spacing: 12) {
                Text("Upload behavior")
                    .font(.headline)
                    .padding(.horizontal)

                Toggle(isOn: Binding(
                    get: { store.keepAwake },
                    set: { store.setKeepAwake($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Mac awake while uploading")
                            .font(.body)
                        Text("Prevents idle sleep while uploads are active. Does not override sleep when the lid is closed.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)

                Toggle(isOn: $autoResumeUploads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-resume uploads")
                            .font(.body)
                        Text("Restart paused uploads after relaunch or when the connection returns.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $maxConcurrentUploads, in: 1...6) {
                        Text("Max concurrent uploads: \(maxConcurrentUploads)")
                            .font(.body)
                    }
                    Text("1 is most stable for weak networks. Increase only if your connection is reliable.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("Diagnostics")
                    .font(.headline)
                    .padding(.horizontal)

                HStack(spacing: 10) {
                    Button("Open Log") {
                        openDiagnosticsLog()
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Recent") {
                        let ok = uploads.copyRecentDiagnosticsLines(200)
                        diagnosticsMessage = ok ? "Copied recent log lines." : "No diagnostics logs yet."
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Log", role: .destructive) {
                        uploads.clearDiagnosticsLog()
                        diagnosticsMessage = "Diagnostics log cleared."
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Text(uploads.diagnosticsLogPath)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                if !diagnosticsMessage.isEmpty {
                    Text(diagnosticsMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.top, 6)

            Spacer()

            HStack {
                Text("⌘, opens Settings")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 4)

        }
        .padding(.vertical)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 450)
        .sheet(isPresented: $showAddLibrarySheet) {
            VStack(alignment: .leading, spacing: 16) {

                Text("Add new library")
                    .font(.headline)

                TextField("Name", text: $newLibName)
                    .textFieldStyle(.roundedBorder)

                TextField("Library ID", text: $newLibID)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key", text: $newLibKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        showAddLibrarySheet = false
                    }
                    Button("Add") {
                        store.addLibrary(name: newLibName,
                                         libraryId: newLibID,
                                         apiKey: newLibKey)

                        showAddLibrarySheet = false
                        newLibName = ""
                        newLibID = ""
                        newLibKey = ""
                    }
                    .disabled(newLibName.isEmpty || newLibID.isEmpty || newLibKey.isEmpty)
                }

                Spacer(minLength: 8)
            }
            .padding(20)
            .frame(width: 360)
        }
        .onChange(of: maxConcurrentUploads) { _, _ in
            uploads.schedule()
        }
    }

    // MARK: Helpers

    private func selectLibrary(_ lib: LibraryConfig) {
        selectedLibraryID = lib.id
        nameCache = lib.name
        apiKeyCache = store.apiKey(for: lib) ?? ""
        selectedCollection = store.defaultCollection(for: lib) ?? ""
        pullZoneHostCache = lib.pullZoneHost ?? ""
        store.loadCollections(for: lib)
    }

    private func openDiagnosticsLog() {
        let url = URL(fileURLWithPath: uploads.diagnosticsLogPath)
#if canImport(AppKit)
        uploads.ensureDiagnosticsLogExists()
        NSWorkspace.shared.open(url)
        diagnosticsMessage = ""
#endif
    }

}
