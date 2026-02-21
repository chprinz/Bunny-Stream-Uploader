//
//  BunnyUploadClient.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation
import CryptoKit

/// Bunny Stream TUS uploader (real TUS 1.0).
/// Flow:
/// 1) POST https://video.bunnycdn.com/tusupload  -> Location (upload URL)
/// 2) HEAD uploadURL -> Upload-Offset
/// 3) PATCH uploadURL with chunk bytes -> 204 and updated Upload-Offset
///
/// Auth headers required by Bunny Stream:
/// - AuthorizationSignature
/// - AuthorizationExpire
/// - VideoId
/// - LibraryId
/// - Tus-Resumable: 1.0.0
///
/// Notes:
/// - This uploader supports pause/resume within the app session.
/// - For resume after app restart, persist `uploadURL.absoluteString` and restore it into `setResumeURL(...)`.
final class BunnyUploadClient: NSObject {

    // MARK: - Public surface

    /// Callback fired once the TUS upload URL is known (used for persisting resume state)
    var onURLUpdate: ((URL) -> Void)?
    var onEvent: ((String) -> Void)?
    var onResumeResourceMissing: (() -> Void)?

    /// Current in-flight request task (useful for hard cancel)
    private(set) var task: URLSessionTask?

    /// Upload URL returned by the TUS create call (Location header).
    private(set) var uploadURL: URL?

    /// Set an already-known upload URL (e.g. if you later persist it for resume after app restart).
    func setResumeURL(_ url: URL?) {
        self.uploadURL = url
    }

    /// Pause the upload (does not delete the remote video).
    func pause() {
        isPaused = true
        task?.cancel()
        task = nil
        stopStallWatchdog()
    }

    /// Resume a previously paused upload. (Requires you to call `startTusUpload(...)` once before.)
    func resume() {
        guard !isFinished else { return }
        isPaused = false
        lastProgressAt = Date()
        lastProgressBytes = uploadedBytes
        markActivity()
        continueUploadLoop()
    }

    /// Start (or resume) a TUS upload.
    /// - Important: `videoId` must be the `guid` returned by Create Video.
    func startTusUpload(
        file: URL,
        libraryId: String,
        videoId: String,
        streamKey: String,
        progress: @escaping (Double, Double, TimeInterval) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        self.fileURL = file
        self.libraryId = libraryId
        self.videoId = videoId
        self.streamKey = streamKey
        self.progressCb = progress
        self.completionCb = completion
        
        // Auth-Header-Cache zurücksetzen (neuer Upload = neue Signatur)
        authSignature = nil
        authExpire = nil

        isPaused = false
        isFinished = false
        lastErrorWasCancel = false
        recoveryCancelInFlight = false

        // File size
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        totalBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        lastProgressAt = Date()
        lastProgressBytes = uploadedBytes
        smoothedBps = 0
        markActivity()
        startStallWatchdog()

        // If we already have an uploadURL (e.g. coming from persistence), just continue.
        if uploadURL != nil {
            continueUploadLoop()
            return
        }

        createTusUpload(attempt: 0)
    }

    // MARK: - Internals

    private let endpoint = URL(string: "https://video.bunnycdn.com/tusupload")!

    private lazy var session: URLSession = {
        // Default is fine. We keep it simple and robust with our own retry logic.
        URLSession(configuration: .default)
    }()

    private var fileURL: URL?
    private var libraryId: String?
    private var videoId: String?
    private var streamKey: String?

    private var totalBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0

    private var progressCb: ((Double, Double, TimeInterval) -> Void)?
    private var completionCb: ((Bool) -> Void)?

    private var isPaused = false
    private var isFinished = false

    private var lastErrorWasCancel = false

    private let workQ = DispatchQueue(label: "BunnyTusUploader.queue")

    // Smaller chunks recover more reliably on unstable links.
    private let chunkSize: Int = 1 * 1024 * 1024 // 1 MB

    // Simple retry schedule for transient network errors
    private let retryDelays: [TimeInterval] = [0, 1, 2, 5, 5, 10, 30]
    
    // TUS auth – pro Upload einmal erzeugt und für alle Requests wiederverwendet
    private var authSignature: String?
    private var authExpire: Int?
    
    private var lastProgressAt: Date = .now
    private var lastProgressBytes: Int64 = 0
    private var smoothedBps: Double = 0
    private var lastActivityAt: Date = .now
    private var recoveryCancelInFlight = false
    private var stallTimer: DispatchSourceTimer?
    private let stallCheckInterval: TimeInterval = 15
    private let stallTimeout: TimeInterval = 90

    // MARK: - TUS helpers

    private func makeAuthHeaders(streamKey: String, libraryId: String, videoId: String) -> (sig: String, exp: Int) {

        // bereits erzeugt? wiederverwenden
        if let sig = authSignature, let exp = authExpire {
            return (sig, exp)
        }

        // Expire after 24 hours (aligned with Bunny examples for large uploads)
        let exp = Int(Date().addingTimeInterval(24 * 3600).timeIntervalSince1970)

        // WICHTIG: exakte Reihenfolge für Bunny!
        let payload = "\(libraryId)\(streamKey)\(exp)\(videoId)"

        let hash = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        authSignature = hash
        authExpire = exp
        return (hash, exp)
    }

    private func tusCommonHeaders(_ req: inout URLRequest, libraryId: String, videoId: String, streamKey: String) {
        let auth = makeAuthHeaders(streamKey: streamKey, libraryId: libraryId, videoId: videoId)
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(auth.sig, forHTTPHeaderField: "AuthorizationSignature")
        req.setValue(String(auth.exp), forHTTPHeaderField: "AuthorizationExpire")
        req.setValue(videoId, forHTTPHeaderField: "VideoId")
        req.setValue(libraryId, forHTTPHeaderField: "LibraryId")
    }

    private func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private func createTusUpload(attempt: Int) {
        if isPaused || isFinished { return }
        guard let fileURL, let libraryId, let videoId, let streamKey else {
            finish(false)
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        tusCommonHeaders(&req, libraryId: libraryId, videoId: videoId, streamKey: streamKey)

        // Required by TUS create
        req.setValue(String(totalBytes), forHTTPHeaderField: "Upload-Length")

        // Optional metadata (safe to keep minimal)
        // Format: key base64(value),key base64(value)
        let filename = fileURL.lastPathComponent
        let meta = "filename \(base64(filename))"
        req.setValue(meta, forHTTPHeaderField: "Upload-Metadata")

        task = session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            self.markActivity()

            if self.handleCancelableError(err) { return }

            guard let http = resp as? HTTPURLResponse else {
                self.retryOrFail(stage: "create", attempt: attempt) { self.createTusUpload(attempt: attempt + 1) }
                return
            }

            // Bunny returns 201 + Location
            if http.statusCode == 201, let loc = http.value(forHTTPHeaderField: "Location") {
                if let url = URL(string: loc), url.scheme != nil {
                    self.uploadURL = url
                } else {
                    let absolute = "https://video.bunnycdn.com\(loc)"
                    self.uploadURL = URL(string: absolute)
                }

                if let u = self.uploadURL {
                    self.onURLUpdate?(u)
                }

                self.continueUploadLoop()
                return
            }

            // If 204/200 is returned unexpectedly, we still try to read Location and proceed
            if let loc = http.value(forHTTPHeaderField: "Location"),
               let url = URL(string: loc) {
                self.uploadURL = url
                self.onURLUpdate?(url)
                self.continueUploadLoop()
                return
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                self.invalidateAuthHeaders()
                self.retryOrFail(stage: "create_auth_\(http.statusCode)", attempt: attempt) { self.createTusUpload(attempt: attempt + 1) }
                return
            }

            self.logEvent("create_unexpected_status status=\(http.statusCode)")
            self.finish(false)
        }
        task?.resume()
    }

    private func continueUploadLoop() {
        workQ.async { [weak self] in
            guard let self else { return }
            if self.isPaused || self.isFinished { return }
            // Ensure the network route is alive before resuming
            self.probeRoute {
                self.fetchOffsetAndUpload(attempt: 0)
            }
        }
    }

    // Quick connectivity probe: HEAD the upload URL to ensure the route is alive.
    private func probeRoute(_ action: @escaping () -> Void) {
        guard let uploadURL else { action(); return }
        guard let libraryId, let videoId, let streamKey else { action(); return }

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "HEAD"
        tusCommonHeaders(&req, libraryId: libraryId, videoId: videoId, streamKey: streamKey)

        // Perform a very short HEAD probe (no retries)
        session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            self.markActivity()
            if let err {
                if self.handleCancelableError(err) {
                    self.workQ.asyncAfter(deadline: .now() + 1.0) {
                        self.probeRoute(action)
                    }
                    return
                }
                // transient route issue → probe again
                self.workQ.asyncAfter(deadline: .now() + 1.0) {
                    self.probeRoute(action)
                }
                return
            }

            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    self.invalidateAuthHeaders()
                    action()
                    return
                }
                if !(http.statusCode == 200 || http.statusCode == 204) {
                    self.workQ.asyncAfter(deadline: .now() + 1.0) {
                        self.probeRoute(action)
                    }
                    return
                }
            }

            // Route ok → continue with real action
            action()
        }.resume()
    }

    private func fetchOffsetAndUpload(attempt: Int) {
        if isPaused || isFinished { return }
        guard let uploadURL else {
            finish(false)
            return
        }
        guard let libraryId, let videoId, let streamKey else {
            finish(false)
            return
        }

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "HEAD"
        tusCommonHeaders(&req, libraryId: libraryId, videoId: videoId, streamKey: streamKey)

        task = session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            self.markActivity()

            if self.handleCancelableError(err) { return }

            guard let http = resp as? HTTPURLResponse else {
                self.retryOrFail(stage: "head", attempt: attempt) { self.fetchOffsetAndUpload(attempt: attempt + 1) }
                return
            }

            // TUS HEAD should be 200 or 204
            if !(http.statusCode == 200 || http.statusCode == 204) {
                if http.statusCode == 404 || http.statusCode == 410 {
                    self.logEvent("resume_resource_missing status=\(http.statusCode)")
                    self.onResumeResourceMissing?()
                    self.finish(false)
                    return
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    self.invalidateAuthHeaders()
                }
                self.retryOrFail(stage: "head_status_\(http.statusCode)", attempt: attempt) { self.fetchOffsetAndUpload(attempt: attempt + 1) }
                return
            }

            let offsetStr = http.value(forHTTPHeaderField: "Upload-Offset") ?? "0"
            let offset = Int64(offsetStr) ?? 0
            self.uploadedBytes = offset

            // done?
            if offset >= self.totalBytes {
                self.reportProgress(bytesSent: self.totalBytes)
                self.finish(true)
                return
            }

            self.patchChunk(fromOffset: offset, attempt: 0)
        }
        task?.resume()
    }

    private func patchChunk(fromOffset offset: Int64, attempt: Int) {
        if isPaused || isFinished { return }
        guard let uploadURL else { finish(false); return }
        guard let fileURL, let libraryId, let videoId, let streamKey else { finish(false); return }

        // Read chunk
        let remaining = Int64(max(0, totalBytes - offset))
        let thisChunk = Int(min(Int64(chunkSize), remaining))
        if thisChunk <= 0 {
            finish(true)
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            finish(false)
            return
        }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: thisChunk) ?? Data()
            try handle.close()

            if data.isEmpty {
                finish(false)
                return
            }

            var req = URLRequest(url: uploadURL)
            req.httpMethod = "PATCH"
            tusCommonHeaders(&req, libraryId: libraryId, videoId: videoId, streamKey: streamKey)

            req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

            task = session.uploadTask(with: req, from: data) { [weak self] _, resp, err in
                guard let self else { return }
                self.markActivity()

                if self.handleCancelableError(err) { return }

                guard let http = resp as? HTTPURLResponse else {
                    self.retryOrFail(stage: "patch", attempt: attempt) { self.patchChunk(fromOffset: offset, attempt: attempt + 1) }
                    return
                }

                // TUS PATCH expects 204
                if http.statusCode == 204 {
                    // New offset is provided by server
                    let newOffsetStr = http.value(forHTTPHeaderField: "Upload-Offset") ?? "\(offset + Int64(data.count))"
                    let newOffset = Int64(newOffsetStr) ?? (offset + Int64(data.count))
                    self.uploadedBytes = newOffset

                    self.reportProgress(bytesSent: newOffset)

                    // next chunk
                    self.workQ.async {
                        if self.isPaused || self.isFinished { return }
                        self.patchChunk(fromOffset: newOffset, attempt: 0)
                    }
                    return
                }

                // Some servers may respond 200 but still advance. Try to continue via HEAD.
                if http.statusCode == 200 {
                    self.workQ.async {
                        if self.isPaused || self.isFinished { return }
                        self.fetchOffsetAndUpload(attempt: 0)
                    }
                    return
                }

                if http.statusCode == 409 {
                    // Offset mismatch: server already advanced; re-sync before next PATCH.
                    self.workQ.async {
                        if self.isPaused || self.isFinished { return }
                        self.fetchOffsetAndUpload(attempt: 0)
                    }
                    return
                }

                // Bunny may temporarily lock uploads and respond with 423 after a network hiccup.
                // In that case, wait briefly and re-sync via HEAD instead of failing the upload.
                if http.statusCode == 423 {
                    self.logEvent("patch_locked_423 resync_head=true")
                    self.workQ.asyncAfter(deadline: .now() + 1.0) {
                        if self.isPaused || self.isFinished { return }
                        self.fetchOffsetAndUpload(attempt: 0)
                    }
                    return
                }

                if http.statusCode == 401 || http.statusCode == 403 {
                    self.invalidateAuthHeaders()
                    self.retryOrFail(stage: "patch_auth_\(http.statusCode)", attempt: attempt) {
                        self.fetchOffsetAndUpload(attempt: 0)
                    }
                    return
                }

                if http.statusCode == 404 || http.statusCode == 410 {
                    self.logEvent("resume_resource_missing status=\(http.statusCode)")
                    self.onResumeResourceMissing?()
                    self.finish(false)
                    return
                }

                self.logEvent("patch_unexpected_status status=\(http.statusCode) attempt=\(attempt)")
                self.retryOrFail(stage: "patch_status_\(http.statusCode)", attempt: attempt) {
                    self.patchChunk(fromOffset: offset, attempt: attempt + 1)
                }
            }
            task?.resume()

        } catch {
            finish(false)
        }
    }

    // MARK: - Progress / speed / ETA

    private func reportProgress(bytesSent: Int64) {
        let total = max(totalBytes, 1)
        let prog = min(max(Double(bytesSent) / Double(total), 0), 1)

        let now = Date()
        let deltaTime = now.timeIntervalSince(lastProgressAt)
        let deltaBytes = max(0, bytesSent - lastProgressBytes)
        if deltaTime > 0.05 && deltaBytes > 0 {
            let instantBps = Double(deltaBytes) / deltaTime
            smoothedBps = smoothedBps <= 0 ? instantBps : (0.25 * instantBps + 0.75 * smoothedBps)
            lastProgressAt = now
            lastProgressBytes = bytesSent
            markActivity()
        }
        let bps = max(0, smoothedBps)
        let mbps = bps / 1_000_000.0

        let remaining = Double(totalBytes - bytesSent)
        let eta = bps > 0 ? remaining / bps : 0

        DispatchQueue.main.async {
            self.progressCb?(prog, mbps, eta)
        }
    }

    // MARK: - Cancel handling / Retry / finish

    private func handleCancelableError(_ err: Error?) -> Bool {
        guard let err else { return false }
        let ns = err as NSError

        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled:
                lastErrorWasCancel = true
                if recoveryCancelInFlight {
                    recoveryCancelInFlight = false
                    return true
                }
                if isPaused { return true }
                finish(false)
                return true

            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut:
                // Let stage-specific retry logic decide recovery path.
                logEvent("network_transient_error code=\(ns.code)")
                return false

            default:
                break
            }
        }
        return false
    }

    private func retryOrFail(stage: String, attempt: Int, _ action: @escaping () -> Void) {
        if isPaused || isFinished { return }

        if attempt >= retryDelays.count {
            if isRecoverableStage(stage) {
                let delay = retryDelays.last ?? 30
                logEvent("retry_continuing stage=\(stage) delay=\(Int(delay))s")
                workQ.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if self.isPaused || self.isFinished { return }
                    action()
                }
                return
            }
            logEvent("retry_exhausted stage=\(stage)")
            finish(false)
            return
        }

        let delay = retryDelays[attempt]
        if attempt > 0 || stage.contains("status_") || stage.contains("auth") {
            logEvent("retry_scheduled stage=\(stage) attempt=\(attempt) delay=\(Int(delay))s")
        }
        workQ.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.isPaused || self.isFinished { return }
            action()
        }
    }

    private func finish(_ ok: Bool) {
        if isFinished { return }
        isFinished = true
        task = nil
        stopStallWatchdog()

        DispatchQueue.main.async {
            self.completionCb?(ok)
        }
    }

    private func invalidateAuthHeaders() {
        authSignature = nil
        authExpire = nil
    }

    private func markActivity() {
        workQ.async {
            self.lastActivityAt = Date()
        }
    }

    private func startStallWatchdog() {
        workQ.async {
            self.stopStallWatchdogLocked()
            let t = DispatchSource.makeTimerSource(queue: self.workQ)
            t.schedule(deadline: .now() + self.stallCheckInterval, repeating: self.stallCheckInterval)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if self.isPaused || self.isFinished { return }
                let idle = Date().timeIntervalSince(self.lastActivityAt)
                guard idle >= self.stallTimeout else { return }
                guard self.task != nil else { return }
                self.logEvent("stall_detected idle=\(Int(idle))s force_resync=true")
                self.recoveryCancelInFlight = true
                self.task?.cancel()
                self.task = nil
                self.lastActivityAt = Date()
                self.fetchOffsetAndUpload(attempt: 0)
            }
            self.stallTimer = t
            t.resume()
        }
    }

    private func stopStallWatchdog() {
        workQ.async {
            self.stopStallWatchdogLocked()
        }
    }

    private func stopStallWatchdogLocked() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func isRecoverableStage(_ stage: String) -> Bool {
        if stage.contains("auth") { return false }
        if let range = stage.range(of: "status_") {
            let codeStr = String(stage[range.upperBound...])
            if let code = Int(codeStr) {
                if code >= 500 { return true }
                if code == 409 || code == 423 || code == 429 { return true }
                if code >= 400 { return false }
                return true
            }
        }
        return stage == "create" || stage == "head" || stage == "patch"
    }

    private func logEvent(_ message: String) {
        print("TUS \(message)")
        onEvent?(message)
    }
}
