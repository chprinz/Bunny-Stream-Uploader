//
//  UploadManager.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation
import Combine
import SwiftUI
import UserNotifications
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

    private struct RemoteVideoSummary {
        let videoId: String
        let title: String?
        let thumbnail: String?
        let encodeProgress: Double?
        let statusCode: Int?
        let createdAt: Date?
        let durationSeconds: TimeInterval?
    }

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

    // Delete a finished video from Bunny and remove locally
    func deleteFromBunny(itemId: UUID, completion: @escaping (Bool) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else {
            completion(false)
            return
        }
        let item = items[idx]

        guard let videoId = item.videoId else {
            items.removeAll { $0.id == itemId }
            persistItems()
            completion(true)
            return
        }

        guard let lib = store.libraries.first(where: { $0.id.uuidString == item.libraryConfigId }),
              let apiKey = store.apiKey(for: lib) else {
            completion(false)
            return
        }

        let api = APIService(streamKey: apiKey)
        api.deleteVideo(libraryId: item.libraryId, videoId: videoId) { [weak self] ok in
            DispatchQueue.main.async {
                if ok {
                    self?.items.removeAll { $0.id == itemId }
                    self?.persistItems()
                }
                completion(ok)
            }
        }
    }

    // Refresh metadata from Bunny
    func refreshVideoDetails(itemId: UUID, completion: @escaping (UploadItem?) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else {
            completion(nil); return
        }
        let item = items[idx]
        guard let videoId = item.videoId else { completion(nil); return }
        guard let api = apiService(for: item) else { completion(nil); return }

        api.fetchVideoDetails(libraryId: item.libraryId, videoId: videoId) { [weak self] status, json in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Remove locally if Bunny reports not found
            if status == 404 {
                DispatchQueue.main.async {
                    self.items.removeAll { $0.id == itemId }
                    self.persistItems()
                    completion(nil)
                }
                return
            }

            guard let json else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let title = json["title"] as? String
            let desc = json["description"] as? String
            let thumb = (json["thumbnailFileName"] as? String)
                ?? (json["thumbnailFilename"] as? String)
                ?? (json["thumbnail"] as? String)
                ?? (json["thumbnailUrl"] as? String)
                ?? (json["thumbnailURL"] as? String)
            let remoteStatus = json["status"] as? Int
            let encodeProgress: Double? = {
                if let p = json["encodeProgress"] as? Double { return p }
                if let p = json["encodeProgress"] as? Int { return Double(p) }
                return nil
            }()
            let durationSeconds: TimeInterval? = {
                if let v = json["length"] as? Double { return v }
                if let v = json["length"] as? Int { return Double(v) }
                if let v = json["duration"] as? Double { return v }
                if let v = json["duration"] as? Int { return Double(v) }
                if let v = json["videoDuration"] as? Double { return v }
                if let v = json["videoDuration"] as? Int { return Double(v) }
                return nil
            }()

            DispatchQueue.main.async {
                if let i = self.items.firstIndex(where: { $0.id == itemId }) {
                    self.items[i].remoteTitle = title
                    self.items[i].remoteDescription = desc
                    self.items[i].remoteThumbnailPath = thumb
                    self.items[i].remoteStatusCode = remoteStatus
                    self.items[i].remoteEncodeProgress = encodeProgress
                    self.items[i].remoteDurationSeconds = durationSeconds
                    if let prog = encodeProgress, prog >= 100, !self.items[i].processingReadyNotified {
                        self.items[i].processingReadyNotified = true
                        self.persistItems()
                        self.sendReadyNotification(for: self.items[i])
                    } else {
                        self.persistItems()
                    }
                    completion(self.items[i])
                } else {
                    completion(nil)
                }
            }
        }
    }

    // Update title/description on Bunny
    func updateMetadata(
        itemId: UUID,
        title: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else {
            completion(false); return
        }
        let item = items[idx]
        guard let videoId = item.videoId else { completion(false); return }
        guard let api = apiService(for: item) else { completion(false); return }

        api.updateVideoDetails(libraryId: item.libraryId, videoId: videoId, title: title, description: nil) { [weak self] ok in
            guard let self else {
                DispatchQueue.main.async { completion(ok) }
                return
            }

            if ok {
                // Fetch fresh state to reflect Bunny's final value
                self.refreshVideoDetails(itemId: itemId) { _ in
                    DispatchQueue.main.async { completion(true) }
                }
            } else {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // Upload custom thumbnail to Bunny
    func uploadThumbnail(
        itemId: UUID,
        data: Data,
        mimeType: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else {
            completion(false); return
        }
        let item = items[idx]
        guard let videoId = item.videoId else { completion(false); return }
        guard let api = apiService(for: item) else { completion(false); return }

        api.uploadThumbnail(libraryId: item.libraryId, videoId: videoId, data: data, mimeType: mimeType) { [weak self] ok in
            DispatchQueue.main.async {
                if ok, let i = self?.items.firstIndex(where: { $0.id == itemId }) {
                    self?.items[i].remoteThumbnailPath = nil
                    self?.persistItems()
                }
                completion(ok)
            }
        }
    }

    // MARK: - Library sync (remote → local history)

    func syncLibrary(_ lib: LibraryConfig, completion: (() -> Void)? = nil) {
        guard let apiKey = store.apiKey(for: lib) else {
            completion?()
            return
        }

        let api = APIService(streamKey: apiKey)
        let perPage = 100
        var collected: [[String: Any]] = []

        func fetch(page: Int) {
            api.fetchLibraryVideos(libraryId: lib.libraryId, page: page, perPage: perPage) { [weak self] status, json in
                guard let self else { return }
                guard status < 300, let json else {
                    DispatchQueue.main.async { completion?() }
                    return
                }

                let items = (json["items"] as? [[String: Any]]) ?? []
                collected.append(contentsOf: items)

                let totalItems = json["totalItems"] as? Int ?? collected.count
                let itemsPerPage = json["itemsPerPage"] as? Int ?? perPage
                let currentPage = json["currentPage"] as? Int ?? page
                let totalPages = Int(ceil(Double(totalItems) / Double(max(itemsPerPage, 1))))

                if currentPage < totalPages {
                    fetch(page: currentPage + 1)
                } else {
                    let parsed = collected.compactMap(self.parseRemoteVideo)
                    DispatchQueue.main.async {
                        self.mergeLibrary(lib: lib, remoteVideos: parsed)
                        self.persistItems()
                        completion?()
                    }
                }
            }
        }

        fetch(page: 1)
    }

    private func parseRemoteVideo(_ raw: [String: Any]) -> RemoteVideoSummary? {
        guard let guid = raw["guid"] as? String else { return nil }
        let title = raw["title"] as? String
        let thumb = (raw["thumbnailFileName"] as? String)
            ?? (raw["thumbnailFilename"] as? String)
            ?? (raw["thumbnail"] as? String)
            ?? (raw["thumbnailUrl"] as? String)
            ?? (raw["thumbnailURL"] as? String)
        let encodeProgress: Double? = {
            if let p = raw["encodeProgress"] as? Double { return p }
            if let p = raw["encodeProgress"] as? Int { return Double(p) }
            if let p = raw["processingPercentage"] as? Double { return p }
            if let p = raw["processingPercentage"] as? Int { return Double(p) }
            return nil
        }()
        let statusCode = raw["status"] as? Int
        let createdAt = parseRemoteDate(
            (raw["dateUploaded"] as? String)
            ?? (raw["dateCreated"] as? String)
        )
        let durationSeconds: TimeInterval? = {
            if let v = raw["length"] as? Double { return v }
            if let v = raw["length"] as? Int { return Double(v) }
            if let v = raw["duration"] as? Double { return v }
            if let v = raw["duration"] as? Int { return Double(v) }
            if let v = raw["videoDuration"] as? Double { return v }
            if let v = raw["videoDuration"] as? Int { return Double(v) }
            return nil
        }()

        return RemoteVideoSummary(
            videoId: guid,
            title: title,
            thumbnail: thumb,
            encodeProgress: encodeProgress,
            statusCode: statusCode,
            createdAt: createdAt,
            durationSeconds: durationSeconds
        )
    }

    private func parseRemoteDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let d = isoWithFractional.date(from: raw) {
            return d
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) {
            return d
        }

        if let ts = TimeInterval(raw) {
            return Date(timeIntervalSince1970: ts)
        }

        return nil
    }

    private func mergeLibrary(lib: LibraryConfig, remoteVideos: [RemoteVideoSummary]) {
        let remoteMap = Dictionary(uniqueKeysWithValues: remoteVideos.map { ($0.videoId, $0) })
        let remoteIds = Set(remoteMap.keys)

        for idx in items.indices {
            guard items[idx].libraryConfigId == lib.id.uuidString,
                  let vid = items[idx].videoId,
                  let remote = remoteMap[vid] else { continue }

            items[idx].remoteTitle = remote.title
            items[idx].remoteThumbnailPath = remote.thumbnail
            items[idx].remoteStatusCode = remote.statusCode
            items[idx].remoteEncodeProgress = remote.encodeProgress
            items[idx].remoteDurationSeconds = remote.durationSeconds
            if let date = remote.createdAt {
                items[idx].completedAt = date
                items[idx].createdAt = date
            }
            if items[idx].status == .success {
                items[idx].progress = 1.0
            }
        }

        // Remove finished items that no longer exist remotely
        items.removeAll { item in
            guard item.libraryConfigId == lib.id.uuidString else { return false }
            if item.status == .uploading || item.status == .pending || item.status == .paused { return false }
            guard let vid = item.videoId else { return false }
            return !remoteIds.contains(vid)
        }

        // Add any videos that exist on Bunny but not locally yet
        for remote in remoteVideos {
            let exists = items.contains {
                $0.videoId == remote.videoId && $0.libraryConfigId == lib.id.uuidString
            }
            if exists { continue }

            let fallbackDate = remote.createdAt ?? Date(timeIntervalSince1970: 0)
            var newItem = UploadItem(
                file: URL(fileURLWithPath: "/bunny/\(remote.videoId)"),
                libraryConfigId: lib.id.uuidString,
                libraryId: lib.libraryId,
                collectionId: nil,
                status: .success,
                progress: 1.0,
                speedMBps: 0,
                etaSeconds: 0,
                videoId: remote.videoId,
                completedAt: remote.createdAt ?? fallbackDate
            )
            newItem.remoteTitle = remote.title
            newItem.remoteThumbnailPath = remote.thumbnail
            newItem.remoteStatusCode = remote.statusCode
            newItem.remoteEncodeProgress = remote.encodeProgress
            newItem.remoteDurationSeconds = remote.durationSeconds
            newItem.createdAt = remote.createdAt ?? fallbackDate
            items.append(newItem)
        }
    }


    private func apiService(for item: UploadItem) -> APIService? {
        guard let lib = store.libraries.first(where: { $0.id.uuidString == item.libraryConfigId }),
              let apiKey = store.apiKey(for: lib) else { return nil }
        return APIService(streamKey: apiKey)
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
            self.pollProcessingReady(itemId: itemId, attempt: 0)
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

    private func sendReadyNotification(for item: UploadItem) {
        let content = UNMutableNotificationContent()
        content.title = "Video ready"
        content.body = item.displayTitle
        content.sound = .default

        let req = UNNotificationRequest(identifier: "ready-\(item.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func pollProcessingReady(itemId: UUID, attempt: Int) {
        guard attempt < 30 else { return } // stop after ~30 attempts
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = items[idx]
        guard item.status == .success else { return }

        refreshVideoDetails(itemId: itemId) { [weak self] updated in
            guard let self else { return }
            if let up = updated,
               let prog = up.remoteEncodeProgress,
               prog >= 100,
               !up.processingReadyNotified {
                if let i = self.items.firstIndex(where: { $0.id == itemId }) {
                    self.items[i].processingReadyNotified = true
                    self.persistItems()
                    self.sendReadyNotification(for: self.items[i])
                }
                return
            }
            // schedule next poll
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                self.pollProcessingReady(itemId: itemId, attempt: attempt + 1)
            }
        }
    }
}
