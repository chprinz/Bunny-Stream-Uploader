//
//  LibraryStore.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation
import Combine

struct CollectionItem: Identifiable, Codable {
    let id: String
    let name: String
}

final class LibraryStore: ObservableObject {

    @Published var libraries: [LibraryConfig] = []
    @Published var defaultCollections: [UUID: String] = [:]
    @Published var keepAwake: Bool = true
    @Published var collections: [UUID: [CollectionItem]] = [:]

    private let keepAwakeKey = "KeepAwakeSetting_v1"

private let storageKey = "SavedLibraries_v1"
private let defaultsKey = "SavedDefaultCollections_v1"
private let lastLibraryKey = "LastSelectedLibrary_v1"

    init() {
        load()
        loadDefaultCollections()
        self.keepAwake = UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool ?? true
    }

    func addLibrary(name: String, libraryId: String, apiKey: String) {
        let lib = LibraryConfig(id: UUID(), name: name, libraryId: libraryId)
        libraries.append(lib)
        save()
        KeychainService.save(key: lib.id.uuidString, value: apiKey)
    }

    func deleteLibrary(_ lib: LibraryConfig) {
        libraries.removeAll { $0.id == lib.id }
        save()
        // Keychain delete lassen wir minimal (optional später)
    }
    
    func renameLibrary(id: UUID, newName: String) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].name = newName
        save()
    }

    func apiKey(for lib: LibraryConfig) -> String? {
        KeychainService.load(key: lib.id.uuidString)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(libraries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let libs = try? JSONDecoder().decode([LibraryConfig].self, from: data) else {
            return
        }
        libraries = libs
    }

    // MARK: - Default Collection Handling

    func setDefaultCollection(for lib: LibraryConfig, collectionId: String?) {
        if let cid = collectionId {
            defaultCollections[lib.id] = cid
        } else {
            defaultCollections.removeValue(forKey: lib.id)
        }
        saveDefaultCollections()
    }

    func defaultCollection(for lib: LibraryConfig) -> String? {
        defaultCollections[lib.id]
    }

    private func saveDefaultCollections() {
        if let data = try? JSONEncoder().encode(defaultCollections) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadDefaultCollections() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([UUID: String].self, from: data) else {
            return
        }
        defaultCollections = dict
    }
    func setKeepAwake(_ value: Bool) {
        keepAwake = value
        UserDefaults.standard.set(value, forKey: keepAwakeKey)
    }
    func loadCollections(for lib: LibraryConfig) {
        guard let apiKey = apiKey(for: lib) else { return }

        let api = APIService(streamKey: apiKey)
        api.fetchCollections(libraryId: lib.libraryId) { [weak self] raw in
            guard let self,
                  let dict = raw,
                  let list = dict["items"] as? [[String: Any]] else { return }

            let parsed: [CollectionItem] = list.compactMap {
                guard
                    let id = $0["guid"] as? String,
                    let name = $0["name"] as? String
                else { return nil }
                return CollectionItem(id: id, name: name)
            }

            DispatchQueue.main.async {
                self.collections[lib.id] = parsed
            }
        }
    }
// MARK: - Last Selected Library

func saveLastSelectedLibrary(id: UUID?) {
    if let id = id {
        UserDefaults.standard.set(id.uuidString, forKey: lastLibraryKey)
    } else {
        UserDefaults.standard.removeObject(forKey: lastLibraryKey)
    }
}

func loadLastSelectedLibrary() -> LibraryConfig? {
    guard let raw = UserDefaults.standard.string(forKey: lastLibraryKey),
          let uuid = UUID(uuidString: raw)
    else { return nil }

    return libraries.first { $0.id == uuid }
}
}
