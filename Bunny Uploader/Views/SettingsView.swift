import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var store: LibraryStore

    @State private var selectedLibraryID: UUID? = nil
    @State private var nameCache: String = ""
    @State private var apiKeyCache: String = ""
    @State private var selectedCollection: String = ""

    @AppStorage("autoResumeUploads") private var autoResumeUploads: Bool = true

    @State private var showAddLibrarySheet: Bool = false
    @State private var newLibName: String = ""
    @State private var newLibID: String = ""
    @State private var newLibKey: String = ""

    var selectedLibrary: LibraryConfig? {
        store.libraries.first(where: { $0.id == selectedLibraryID })
    }

    var body: some View {
        VStack(spacing: 16) {

            Text("Libraries")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 4)

            // MARK: Library Selector (horizontal Pills)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.libraries) { lib in
                        Button {
                            selectLibrary(lib)
                        } label: {
                            Text(lib.name)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    selectedLibraryID == lib.id
                                    ? Color("AccentColor").opacity(0.2)
                                    : Color.gray.opacity(0.12)
                                )
                                .foregroundColor(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.06))
            )
            .padding(.horizontal)

            Divider()

            // MARK: Details Panel
            if let lib = selectedLibrary {
                VStack(alignment: .leading, spacing: 16) {

                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        TextField("Name", text: Binding(
                            get: { nameCache },
                            set: { newVal in
                                nameCache = newVal
                                store.renameLibrary(id: lib.id, newName: newVal)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    }

                    // Library ID (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library ID")
                            .font(.caption2)
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
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        SecureField("AccessKey", text: Binding(
                            get: { apiKeyCache },
                            set: { newVal in
                                apiKeyCache = newVal
                                KeychainService.save(key: lib.id.uuidString, value: newVal)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    }

                    // Default Collection (Dropdown)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Collection")
                            .font(.caption2)
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
                        .frame(maxWidth: 240)
                    }

                    Divider().padding(.vertical, 6)

                    // Delete Button
                    Button(role: .destructive) {
                        store.deleteLibrary(lib)
                        selectedLibraryID = nil
                    } label: {
                        Text("Delete library")
                            .font(.callout)
                    }
                    .padding(.top, 4)

                }
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
            }
            .padding(.top, 8)

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
    }

    // MARK: Helpers

    private func selectLibrary(_ lib: LibraryConfig) {
        selectedLibraryID = lib.id
        nameCache = lib.name
        apiKeyCache = store.apiKey(for: lib) ?? ""
        selectedCollection = store.defaultCollection(for: lib) ?? ""
        store.loadCollections(for: lib)
    }

}
