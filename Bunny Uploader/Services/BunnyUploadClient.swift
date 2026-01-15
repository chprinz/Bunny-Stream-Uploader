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
    }

    /// Resume a previously paused upload. (Requires you to call `startTusUpload(...)` once before.)
    func resume() {
        guard !isFinished else { return }
        isPaused = false
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

        // File size
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        totalBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        startedAt = Date()

        // If we already have an uploadURL (e.g. coming from persistence), just continue.
        if uploadURL != nil {
            continueUploadLoop()
            return
        }

        createTusUpload()
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

    private var startedAt: Date = .now
    private var progressCb: ((Double, Double, TimeInterval) -> Void)?
    private var completionCb: ((Bool) -> Void)?

    private var isPaused = false
    private var isFinished = false

    private var lastErrorWasCancel = false

    private let workQ = DispatchQueue(label: "BunnyTusUploader.queue")

    // Chunk size tuned for unstable / 4G networks
    private let chunkSize: Int = 4 * 1024 * 1024 // 4 MB

    // Simple retry schedule for transient network errors
    private let retryDelays: [TimeInterval] = [0, 1, 2, 5, 5, 10, 30]
    
    // TUS auth – pro Upload einmal erzeugt und für alle Requests wiederverwendet
    private var authSignature: String?
    private var authExpire: Int?

    // MARK: - TUS helpers

    private func makeAuthHeaders(streamKey: String, libraryId: String, videoId: String) -> (sig: String, exp: Int) {

        // bereits erzeugt? wiederverwenden
        if let sig = authSignature, let exp = authExpire {
            return (sig, exp)
        }

        // Expire after 6 hours
        let exp = Int(Date().addingTimeInterval(6 * 3600).timeIntervalSince1970)

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

    private func createTusUpload() {
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

            if self.handleCancelableError(err) { return }

            guard let http = resp as? HTTPURLResponse else {
                self.retryOrFail(stage: "create", attempt: 0) { self.createTusUpload() }
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

            print("TUS create unexpected status:", http.statusCode)
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
            if self.handleCancelableError(err) {
                // Route not ready yet → retry after short delay
                self.workQ.asyncAfter(deadline: .now() + 1.0) {
                    self.probeRoute(action)
                }
                return
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

            if self.handleCancelableError(err) { return }

            guard let http = resp as? HTTPURLResponse else {
                self.retryOrFail(stage: "head", attempt: attempt) { self.fetchOffsetAndUpload(attempt: attempt + 1) }
                return
            }

            // TUS HEAD should be 200 or 204
            if !(http.statusCode == 200 || http.statusCode == 204) {
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

                // Bunny may temporarily lock uploads and respond with 423 after a network hiccup.
                // In that case, wait briefly and re-sync via HEAD instead of failing the upload.
                if http.statusCode == 423 {
                    print("TUS PATCH locked (423), retrying via HEAD…")
                    self.workQ.asyncAfter(deadline: .now() + 1.0) {
                        if self.isPaused || self.isFinished { return }
                        self.fetchOffsetAndUpload(attempt: 0)
                    }
                    return
                }

                print("TUS PATCH unexpected status:", http.statusCode)
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
        let prog = Double(bytesSent) / Double(total)

        let elapsed = Date().timeIntervalSince(startedAt)
        let bps = elapsed > 0 ? Double(bytesSent) / elapsed : 0
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
                if isPaused { return true }
                finish(false)
                return true

            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut:
                // Treat transient network errors as a pause, not a failure
                print("TUS network error (\(ns.code)), pausing upload")
                isPaused = true
                task = nil
                return true

            default:
                break
            }
        }
        return false
    }

    private func retryOrFail(stage: String, attempt: Int, _ action: @escaping () -> Void) {
        if isPaused || isFinished { return }

        if attempt >= retryDelays.count {
            print("TUS retry exhausted at stage:", stage)
            finish(false)
            return
        }

        let delay = retryDelays[attempt]
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

        DispatchQueue.main.async {
            self.completionCb?(ok)
        }
    }
}
