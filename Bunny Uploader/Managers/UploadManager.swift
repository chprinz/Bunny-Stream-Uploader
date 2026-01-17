//
//  UploadManager.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation
import Combine
import SwiftUI
import IOKit.pwr_mgt

final class UploadManager: ObservableObject {

    @Published var items: [UploadItem] = []
    @AppStorage("autoResumeUploads") private var autoResumeUploads: Bool = true

    private let store: LibraryStore
    private let network = NetworkMonitor()
    private var cancellables = Set<AnyCancellable>()

    // Stabil für 4G: 1 Upload gleichzeitig
    private let maxConcurrent = 1

    // Task registry fürs Cancel
    private var activeClients: [UUID: BunnyUploadClient] = [:]

    // Sleep assertion (optional via Settings)
    private var sleepAssertionID: IOPMAssertionID = 0
    private var sleepAssertionActive = false

    private var persistenceURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("BunnyUploader", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("uploads.json")
    }

    init(store: LibraryStore) {
        self.store = store
        loadPersistedItems()

        // Auto-resume persisted unfinished uploads (if enabled)
        if autoResumeUploads {
            for i in items.indices {
                switch items[i].status {
                case .uploading, .pending, .paused:
                    items[i].status = .pending
                default:
                    break
                }
            }
            self.schedule()
        }

        network.$isConnected
            .sink { [weak self] connected in
                guard let self else { return }

                if !connected {
                    let now = Date()
                    for itemId in Array(self.activeClients.keys) {
                        if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                            self.activeClients[itemId]?.pause()
                            self.activeClients[itemId] = nil
                            self.items[idx].status = .paused
                            self.items[idx].lastResumeAttempt = now
                        }
                    }
                    self.releaseSleepAssertionIfNeeded()
                    return
                }

                if connected && self.autoResumeUploads {
                    let now = Date()
                    for i in self.items.indices {
                        if self.items[i].status == .paused {
                            if self.items[i].lastResumeAttempt != nil {
                                self.items[i].status = .pending
                            }
                        }
                    }
                    self.schedule()
                }
            }
            .store(in: &cancellables)
    }

    // Enqueue: Default-Library ist Pflicht (wird vom UI erzwungen)
    func enqueue(files: [URL], using lib: LibraryConfig) {
        guard store.apiKey(for: lib) != nil else {
            print("enqueue: missing API key for library config:", lib.id)
            for url in files {
                var it = UploadItem(
                    file: url,
                    libraryConfigId: lib.id.uuidString,
                    libraryId: lib.libraryId,
                    collectionId: nil,
                    status: .failed,
                    progress: 0,
                    speedMBps: 0,
                    etaSeconds: 0,
                    videoId: nil
                )
                it.errorMessage = "Missing API key. Please open Settings and set the Stream API key for this Library."
                items.append(it)
            }
            persistItems()
            return
        }

        for url in files {
            let it = UploadItem(
                file: url,
                libraryConfigId: lib.id.uuidString,
                libraryId: lib.libraryId,
                collectionId: nil,
                status: .pending,
                progress: 0,
                speedMBps: 0,
                etaSeconds: 0,
                videoId: nil
            )
            items.append(it)
        }

        acquireSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    // Scheduling: ältestes pending, pausierte blockieren nicht
    func schedule() {
        let activeCount = items.filter { $0.status == .uploading }.count
        guard activeCount < maxConcurrent else { return }

        guard let next = items
            .filter({ $0.status == .pending })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first
        else {
            releaseSleepAssertionIfNeeded()
            return
        }

        start(itemId: next.id)
    }

    private func start(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard items[idx].status == .pending else { return }

        let item = items[idx]

        guard let lib = store.libraries.first(where: { $0.id.uuidString == item.libraryConfigId }),
              let apiKey = store.apiKey(for: lib) else {
            items[idx].status = .failed
            schedule()
            return
        }

        items[idx].status = .uploading
        acquireSleepAssertionIfNeeded()

        // RESUME PATH: if we already have a videoId and TUS upload URL, do NOT create a new video
        if let resumeURL = items[idx].tusUploadURL,
           let existingVideoId = items[idx].videoId {

            let client = BunnyUploadClient()
            client.setResumeURL(resumeURL)

            self.activeClients[itemId] = client

            client.startTusUpload(
                file: item.file,
                libraryId: item.libraryId,
                videoId: existingVideoId,
                streamKey: apiKey,
                progress: { [weak self] prog, mbps, eta in
                    guard let self else { return }
                    self.updateMetrics(itemId: itemId, progress: prog, mbps: mbps, eta: eta)

                    if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                        self.items[idx].bytesUploaded = Int64(prog * Double(self.items[idx].totalBytes))
                    }
                },
                completion: { [weak self] success in
                    guard let self else { return }

                    if success {
                        self.markSuccess(itemId: itemId, videoId: existingVideoId)
                    } else {
                        if let idx = self.items.firstIndex(where: { $0.id == itemId }),
                           self.items[idx].status != .paused {
                            self.markFailed(itemId: itemId)
                        }
                    }

                    self.activeClients[itemId] = nil
                    self.releaseSleepAssertionIfNeeded()
                    self.schedule()
                }
            )

            return
        }

        let api = APIService(streamKey: apiKey)

        api.createVideo(
            libraryId: item.libraryId,
            title: item.file.lastPathComponent,
            collectionId: store.defaultCollection(for: lib) ?? item.collectionId
        ) { [weak self] vid in
            guard let self else { return }

            guard let videoId = vid else {
                DispatchQueue.main.async {
                    self.markFailed(itemId: itemId)
                    self.releaseSleepAssertionIfNeeded()
                    self.schedule()
                }
                return
            }

            let client = BunnyUploadClient()
            client.onURLUpdate = { [weak self] url in
                guard let self else { return }
                if let i = self.items.firstIndex(where: { $0.id == itemId }) {
                    DispatchQueue.main.async {
                        self.items[i].tusUploadURL = url
                    }
                }
            }

            if let storedURL = self.items[idx].tusUploadURL {
                client.setResumeURL(storedURL)
            }

            self.activeClients[itemId] = client

            // NEW UPLOAD PATH
            client.startTusUpload(
                file: item.file,
                libraryId: item.libraryId,
                videoId: videoId,
                streamKey: apiKey,
                progress: { [weak self] prog, mbps, eta in
                    guard let self else { return }
                    self.updateMetrics(itemId: itemId, progress: prog, mbps: mbps, eta: eta)

                    if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                        self.items[idx].bytesUploaded = Int64(prog * Double(self.items[idx].totalBytes))
                    }
                },
                completion: { [weak self] success in
                    guard let self else { return }

                    if success {
                        self.markSuccess(itemId: itemId, videoId: videoId)
                    } else {
                        if let idx = self.items.firstIndex(where: { $0.id == itemId }),
                           self.items[idx].status != .paused {
                            self.markFailed(itemId: itemId)
                        }
                    }

                    self.activeClients[itemId] = nil
                    self.releaseSleepAssertionIfNeeded()
                    self.schedule()
                }
            )

            DispatchQueue.main.async {
                self.activeClients[itemId] = client
                if let i = self.items.firstIndex(where: { $0.id == itemId }) {
                    self.items[i].videoId = videoId
                    self.items[i].completedAt = nil
                    self.items[i].tusUploadURL = client.uploadURL
                }
            }
        }
    }

    // Cancel / Remove mit Delete-Logik für Bunny
    func cancel(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = items[idx]

        // laufende Task beenden
        activeClients[itemId]?.pause()
        activeClients[itemId] = nil

        // Wenn noch keine videoId existiert → nur lokal entfernen
        guard let videoId = item.videoId else {
            items.removeAll { $0.id == itemId }
            releaseSleepAssertionIfNeeded()
            schedule()
            persistItems()
            return
        }

        // Erfolgreiche Uploads: nur aus der Liste, nicht bei Bunny löschen
        if item.status == .success {
            items.removeAll { $0.id == itemId }
            releaseSleepAssertionIfNeeded()
            schedule()
            persistItems()
            return
        }

        // Failed / Canceled / bestätigtes Löschen eines laufenden Uploads → bei Bunny löschen
        if let lib = store.libraries.first(where: { $0.id.uuidString == item.libraryConfigId }),
           let apiKey = store.apiKey(for: lib) {

            let api = APIService(streamKey: apiKey)
            api.deleteVideo(libraryId: item.libraryId, videoId: videoId) { _ in
                DispatchQueue.main.async {
                    self.items.removeAll { $0.id == itemId }
                    self.releaseSleepAssertionIfNeeded()
                    self.schedule()
                    self.persistItems()
                }
            }
        } else {
            // Fallback: nur lokal entfernen
            items.removeAll { $0.id == itemId }
            releaseSleepAssertionIfNeeded()
            schedule()
            persistItems()
        }
    }

    // MARK: - Per-item Pause / Resume

    func pause(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }

        activeClients[itemId]?.pause()
        activeClients[itemId] = nil

        if items[idx].status == .uploading {
            items[idx].status = .paused
            items[idx].lastResumeAttempt = Date()
        }

        releaseSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    func resume(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }

        if items[idx].status == .paused {
            items[idx].status = .pending
        }

        acquireSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    // MARK: - Global Controls

    func pauseAll() {
        let now = Date()
        for id in Array(activeClients.keys) {
            activeClients[id]?.pause()
            activeClients[id] = nil
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].status = .paused
                items[idx].lastResumeAttempt = now
            }
        }
        releaseSleepAssertionIfNeeded()
        persistItems()
    }

    func resumeAll() {
        let now = Date()
        for i in items.indices {
            if items[i].status == .paused {
                items[i].status = .pending
                items[i].lastResumeAttempt = now
            }
        }
        acquireSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    func clearAll() {
        for (_, client) in activeClients {
            client.pause()
        }
        activeClients.removeAll()
        items.removeAll()
        releaseSleepAssertionIfNeeded()
        persistItems()
    }

    // Remove a finished/failed item locally (no remote delete)
    func removeFromHistory(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = items[idx]
        guard item.status == .success || item.status == .failed || item.status == .canceled else {
            // fallback to full cancel for unexpected state
            cancel(itemId: itemId)
            return
        }
        items.removeAll { $0.id == itemId }
        persistItems()
    }

    // MARK: - Metrics + status helpers

    private func updateMetrics(itemId: UUID, progress: Double, mbps: Double, eta: TimeInterval) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.items[idx].progress = progress
            self.items[idx].speedMBps = mbps
            self.items[idx].etaSeconds = eta
        }
    }

    private func markSuccess(itemId: UUID, videoId: String) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.items[idx].status = .success
            self.items[idx].videoId = videoId
            self.items[idx].progress = 1.0
            self.items[idx].completedAt = Date()
            self.persistItems()
        }
    }

    private func markFailed(itemId: UUID) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.items[idx].status = .failed
            self.items[idx].completedAt = Date()
            self.persistItems()
        }
    }

    // MARK: - Sleep Control

    private func acquireSleepAssertionIfNeeded() {
        guard store.keepAwake, !sleepAssertionActive else { return }
        let reason = "Uploading videos to Bunny.net" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        if result == kIOReturnSuccess {
            sleepAssertionActive = true
        }
    }

    private func releaseSleepAssertionIfNeeded() {
        guard sleepAssertionActive else { return }

        let anyActive = items.contains { $0.status == .uploading || $0.status == .pending }
        if !anyActive {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionActive = false
        }
    }

    // MARK: - Persistence

    private func persistItems() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            print("Failed to persist uploads:", error)
        }
    }

    private func loadPersistedItems() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([UploadItem].self, from: data)
            self.items = decoded
        } catch {
            print("Failed to load persisted uploads:", error)
        }
    }
}
