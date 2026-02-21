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
#if canImport(AppKit)
import AppKit
#endif

final class UploadManager: ObservableObject {

    @Published var items: [UploadItem] = []
    @Published private(set) var isNetworkConnected: Bool = true
    @AppStorage("autoResumeUploads") private var autoResumeUploads: Bool = true
    @AppStorage("maxConcurrentUploads") private var maxConcurrentUploads: Int = 1

    private let store: LibraryStore
    private let network = NetworkMonitor()
    private var cancellables = Set<AnyCancellable>()
    private let telemetryStaleAfter: TimeInterval = 5
    private let noProgressHintAfter: TimeInterval = 120
    private let diagnostics = DiagnosticsLogStore()

    // Keep in a practical range for desktop usage.
    private var maxConcurrent: Int {
        min(max(maxConcurrentUploads, 1), 6)
    }

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
        self.isNetworkConnected = network.isConnected
        loadPersistedItems()

        // Auto-resume persisted unfinished uploads (if enabled)
        if autoResumeUploads && network.isConnected {
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
                self.isNetworkConnected = connected

                if !connected {
                    self.diagnostics.log("Network disconnected. Pausing \(self.activeClients.count) active upload(s).")
                    let now = Date()
                    for itemId in Array(self.activeClients.keys) {
                        if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                            self.activeClients[itemId]?.pause()
                            self.activeClients[itemId] = nil
                            self.items[idx].status = .paused
                            self.items[idx].lastResumeAttempt = now
                            self.items[idx].speedMBps = 0
                            self.items[idx].etaSeconds = 0
                            self.items[idx].lastProgressAt = nil
                        }
                    }
                    self.releaseSleepAssertionIfNeeded()
                    return
                }

                if connected && self.autoResumeUploads {
                    self.diagnostics.log("Network connected. Auto-resume is enabled.")
                    for i in self.items.indices {
                        if self.items[i].status == .paused {
                            if self.items[i].lastResumeAttempt != nil {
                                self.items[i].status = .pending
                            }
                        }
                    }
                }

                if connected {
                    self.diagnostics.log("Checking pending uploads after reconnect.")
                    self.schedule()
                }
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.decayStaleMetrics()
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
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
            var mutable = it
            mutable.totalBytes = fileSize
            items.append(mutable)
        }

        acquireSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    // Scheduling: ältestes pending, pausierte blockieren nicht
    func schedule() {
        guard network.isConnected else { return }

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
        if items[idx].totalBytes <= 0 {
            let attrs = try? FileManager.default.attributesOfItem(atPath: item.file.path)
            items[idx].totalBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let lib = store.libraries.first(where: { $0.id.uuidString == item.libraryConfigId }),
              let apiKey = store.apiKey(for: lib) else {
            items[idx].status = .failed
            schedule()
            return
        }

        items[idx].status = .uploading
        items[idx].lastProgressAt = Date()
        acquireSleepAssertionIfNeeded()

        // RESUME PATH: if we already have a videoId and TUS upload URL, do NOT create a new video
        if let resumeURL = items[idx].tusUploadURL,
           let existingVideoId = items[idx].videoId {

            let client = BunnyUploadClient()
            client.setResumeURL(resumeURL)
            client.onEvent = { [weak self] msg in
                self?.logTusEvent(fileName: item.file.lastPathComponent, raw: msg)
            }
            client.onResumeResourceMissing = { [weak self] in
                self?.invalidateResumeAndQueueFresh(itemId: itemId)
            }

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
                           self.items[idx].status != .paused,
                           self.items[idx].status != .pending {
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
            client.onEvent = { [weak self] msg in
                self?.logTusEvent(fileName: item.file.lastPathComponent, raw: msg)
            }
            client.onResumeResourceMissing = { [weak self] in
                self?.invalidateResumeAndQueueFresh(itemId: itemId)
            }
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
                           self.items[idx].status != .paused,
                           self.items[idx].status != .pending {
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
        diagnostics.log("Upload paused manually: \(items[idx].file.lastPathComponent)")

        activeClients[itemId]?.pause()
        activeClients[itemId] = nil

        if items[idx].status == .uploading {
            items[idx].status = .paused
            items[idx].lastResumeAttempt = Date()
            items[idx].speedMBps = 0
            items[idx].etaSeconds = 0
            items[idx].lastProgressAt = nil
        }

        releaseSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    func resume(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        diagnostics.log("Upload resumed manually: \(items[idx].file.lastPathComponent)")

        if items[idx].status == .paused {
            items[idx].status = .pending
            items[idx].lastResumeAttempt = Date()
            items[idx].speedMBps = 0
            items[idx].etaSeconds = 0
            items[idx].lastProgressAt = nil
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
                items[idx].speedMBps = 0
                items[idx].etaSeconds = 0
                items[idx].lastProgressAt = nil
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

    func retryFailed(itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard items[idx].status == .failed else { return }

        let filePath = items[idx].file.path
        if !FileManager.default.fileExists(atPath: filePath) {
            items[idx].errorMessage = "Local file is missing. Re-add the file to upload again."
            diagnostics.log("Retry skipped: local file is missing (\(items[idx].file.lastPathComponent)).")
            persistItems()
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        items[idx].totalBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? items[idx].totalBytes
        items[idx].errorMessage = nil
        items[idx].completedAt = nil
        items[idx].speedMBps = 0
        items[idx].etaSeconds = 0
        items[idx].lastProgressAt = nil
        items[idx].lastResumeAttempt = Date()
        items[idx].status = .pending
        diagnostics.log("Retrying failed upload: \(items[idx].file.lastPathComponent)")

        acquireSleepAssertionIfNeeded()
        schedule()
        persistItems()
    }

    private func invalidateResumeAndQueueFresh(itemId: UUID) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.diagnostics.log("Remote resumable session missing. Restarting as fresh upload: \(self.items[idx].file.lastPathComponent)")
            self.items[idx].videoId = nil
            self.items[idx].tusUploadURL = nil
            self.items[idx].bytesUploaded = 0
            self.items[idx].progress = 0
            self.items[idx].speedMBps = 0
            self.items[idx].etaSeconds = 0
            self.items[idx].lastProgressAt = nil
            self.items[idx].errorMessage = "Remote upload session expired. Starting a fresh upload."
            self.items[idx].status = .pending
            self.persistItems()
        }
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
            raw["dateUploaded"]
                ?? raw["dateCreated"]
                ?? raw["uploadedAt"]
                ?? raw["createdAt"]
                ?? raw["uploadDate"]
                ?? raw["uploaded"]
                ?? raw["created"]
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

    private func parseRemoteDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }

        func normalize(_ seconds: Double) -> Date? {
            guard seconds > 0 else { return nil }
            // Treat pre-2000 timestamps as invalid; Bunny Stream did not exist then.
            guard seconds > 946684800 else { return nil } // 2000-01-01
            return Date(timeIntervalSince1970: seconds)
        }

        if let d = raw as? Date {
            return normalize(d.timeIntervalSince1970)
        }

        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let isoWithFractional = ISO8601DateFormatter()
            isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoWithFractional.date(from: trimmed) {
                return normalize(d.timeIntervalSince1970)
            }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: trimmed) {
                return normalize(d.timeIntervalSince1970)
            }

            // Bunny sometimes omits timezone; assume UTC if absent
            let customFormats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                "yyyy-MM-dd'T'HH:mm:ss.SSS",
                "yyyy-MM-dd'T'HH:mm:ss"
            ]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for fmt in customFormats {
                df.dateFormat = fmt
                if let d = df.date(from: trimmed) {
                    return normalize(d.timeIntervalSince1970)
                }
            }

            if let ts = Double(trimmed) {
                // Handle seconds, milliseconds, or .NET ticks (100ns)
                if ts > 1e14 { return normalize(ts / 1e7) }
                if ts > 1e11 { return normalize(ts / 1000) }
                return normalize(ts)
            }
        }

        if let num = raw as? NSNumber {
            let ts = num.doubleValue
            if ts > 1e14 { return normalize(ts / 1e7) }
            if ts > 1e11 { return normalize(ts / 1000) }
            return normalize(ts)
        }

        return nil
    }

    private func mergeLibrary(lib: LibraryConfig, remoteVideos: [RemoteVideoSummary]) {
        let remoteMap = Dictionary(uniqueKeysWithValues: remoteVideos.map { ($0.videoId, $0) })
        let remoteIds = Set(remoteMap.keys)

        func sanitized(_ date: Date?) -> Date? {
            guard let d = date else { return nil }
            // Bunny Stream started long after 2000; treat older epochs as invalid placeholders.
            return d.timeIntervalSince1970 > 946684800 ? d : nil
        }

        for idx in items.indices {
            guard items[idx].libraryConfigId == lib.id.uuidString,
                  let vid = items[idx].videoId,
                  let remote = remoteMap[vid] else { continue }

            let remoteDate = remote.createdAt
                ?? sanitized(items[idx].completedAt)
                ?? sanitized(items[idx].createdAt)
                ?? Date()

            items[idx].remoteTitle = remote.title
            items[idx].remoteThumbnailPath = remote.thumbnail
            items[idx].remoteStatusCode = remote.statusCode
            items[idx].remoteEncodeProgress = remote.encodeProgress
            items[idx].remoteDurationSeconds = remote.durationSeconds
            items[idx].completedAt = remoteDate
            items[idx].createdAt = remoteDate
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

            let fallbackDate = remote.createdAt ?? Date()
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
            self.items[idx].lastProgressAt = Date()
        }
    }

    private func markSuccess(itemId: UUID, videoId: String) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.diagnostics.log("Upload completed: \(self.items[idx].file.lastPathComponent) (video \(videoId))")
            self.items[idx].status = .success
            self.items[idx].videoId = videoId
            self.items[idx].progress = 1.0
            self.items[idx].speedMBps = 0
            self.items[idx].etaSeconds = 0
            self.items[idx].lastProgressAt = nil
            self.items[idx].completedAt = Date()
            self.persistItems()
            self.pollProcessingReady(itemId: itemId, attempt: 0)
        }
    }

    private func markFailed(itemId: UUID) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.diagnostics.log("Upload failed: \(self.items[idx].file.lastPathComponent)")
            self.items[idx].status = .failed
            self.items[idx].speedMBps = 0
            self.items[idx].etaSeconds = 0
            self.items[idx].lastProgressAt = nil
            self.items[idx].completedAt = Date()
            self.persistItems()
        }
    }

    private func decayStaleMetrics() {
        let now = Date()
        var changed = false
        for i in items.indices {
            guard items[i].status == .uploading else { continue }
            guard let last = items[i].lastProgressAt else {
                if items[i].speedMBps != 0 || items[i].etaSeconds != 0 {
                    items[i].speedMBps = 0
                    items[i].etaSeconds = 0
                    changed = true
                }
                continue
            }
            if now.timeIntervalSince(last) >= telemetryStaleAfter {
                if items[i].speedMBps != 0 || items[i].etaSeconds != 0 {
                    items[i].speedMBps = 0
                    items[i].etaSeconds = 0
                    changed = true
                }
            }
        }
        if changed {
            objectWillChange.send()
        }
    }

    func noProgressHint(for item: UploadItem) -> String? {
        guard item.status == .uploading else { return nil }
        guard network.isConnected else { return nil }
        guard let last = item.lastProgressAt else { return nil }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed >= noProgressHintAfter else { return nil }
        let minutes = max(1, Int(elapsed / 60))
        return "No progress for \(minutes)m"
    }

    var diagnosticsLogPath: String {
        diagnostics.logURL.path
    }

    func clearDiagnosticsLog() {
        diagnostics.clear()
    }

    func copyRecentDiagnosticsLines(_ maxLines: Int = 200) -> Bool {
        let text = diagnostics.readRecentLines(maxLines)
        guard !text.isEmpty else { return false }
#if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
#else
        return false
#endif
    }

    private func logTusEvent(fileName: String, raw: String) {
        let message: String
        if raw.hasPrefix("network_transient_error") {
            message = "Temporary network issue while uploading \(fileName). Retrying."
        } else if raw.hasPrefix("retry_scheduled") {
            let delay = extractValue("delay", from: raw) ?? "?"
            let stage = extractValue("stage", from: raw) ?? "unknown"
            message = "Retry scheduled in \(delay) for \(fileName) (\(stage))."
        } else if raw.hasPrefix("retry_continuing") {
            let delay = extractValue("delay", from: raw) ?? "?"
            let stage = extractValue("stage", from: raw) ?? "unknown"
            message = "Still retrying \(fileName) every \(delay) (\(stage))."
        } else if raw.hasPrefix("stall_detected") {
            message = "Upload stalled for \(fileName). Re-syncing upload offset."
        } else if raw.hasPrefix("resume_resource_missing") {
            message = "Resumable session expired for \(fileName). Preparing fresh upload."
        } else if raw.hasPrefix("patch_locked_423") {
            message = "Upload temporarily locked for \(fileName). Re-syncing and continuing."
        } else if raw.hasPrefix("retry_exhausted") {
            let stage = extractValue("stage", from: raw) ?? "unknown"
            message = "Retries exhausted for \(fileName) (\(stage))."
        } else if raw.hasPrefix("patch_unexpected_status") || raw.hasPrefix("create_unexpected_status") {
            let status = extractValue("status", from: raw) ?? "unknown"
            message = "Unexpected server response (\(status)) while uploading \(fileName)."
        } else {
            message = "\(fileName): \(raw)"
        }
        diagnostics.log(message)
    }

    private func extractValue(_ key: String, from raw: String) -> String? {
        let token = "\(key)="
        guard let start = raw.range(of: token)?.upperBound else { return nil }
        let tail = raw[start...]
        if let end = tail.firstIndex(of: " ") {
            return String(tail[..<end])
        }
        return String(tail)
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

private final class DiagnosticsLogStore {
    let logURL: URL
    private let queue = DispatchQueue(label: "BunnyUploader.DiagnosticsLog")
    private let maxBytes = 2 * 1024 * 1024
    private let backups = 2

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("BunnyUploader", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        logURL = appDir.appendingPathComponent("upload.log")
    }

    func log(_ message: String) {
        queue.async {
            self.rotateIfNeeded()
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.logURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.logURL) {
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } catch {
                        try? handle.close()
                    }
                }
            } else {
                try? data.write(to: self.logURL, options: [.atomic])
            }
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
            for i in 1...backups {
                try? FileManager.default.removeItem(at: logURL.appendingPathExtension("\(i)"))
            }
        }
    }

    func readRecentLines(_ maxLines: Int) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard !lines.isEmpty else { return "" }
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxBytes else { return }

        for i in stride(from: backups, through: 1, by: -1) {
            let old = logURL.appendingPathExtension("\(i)")
            let next = logURL.appendingPathExtension("\(i + 1)")
            if i == backups {
                try? FileManager.default.removeItem(at: old)
            } else if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.removeItem(at: next)
                try? FileManager.default.moveItem(at: old, to: next)
            }
        }
        let firstBackup = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: firstBackup)
        if FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.moveItem(at: logURL, to: firstBackup)
        }
    }
}
