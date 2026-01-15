//
//  TusUploadClient.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation

final class TusUploadClient: NSObject, URLSessionTaskDelegate {

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    // Damit UploadManager canceln kann:
    var task: URLSessionUploadTask?

    private var startedAt: Date = .now
    private var totalBytes: Int64 = 0

    private var progressCb: ((Double, Double, TimeInterval) -> Void)?
    private var completionCb: ((Bool) -> Void)?

    func startUploadWithTask(
        file: URL,
        libraryId: String,
        videoId: String,
        signature: String,
        expire: Int,
        progress: @escaping (Double, Double, TimeInterval) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        self.progressCb = progress
        self.completionCb = completion
        self.startedAt = Date()

        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        self.totalBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        guard let url = URL(string: "https://video.bunnycdn.com/tusupload") else {
            completion(false)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(signature, forHTTPHeaderField: "AuthorizationSignature")
        req.setValue("\(expire)", forHTTPHeaderField: "AuthorizationExpire")
        req.setValue(libraryId, forHTTPHeaderField: "LibraryId")
        req.setValue(videoId, forHTTPHeaderField: "VideoId")
        req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")

        let t = session.uploadTask(with: req, fromFile: file) { [weak self] _, resp, err in
            guard let self else { return }
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { self.completionCb?(ok) }
        }

        self.task = t
        t.resume()
    }

    // Fortschritt / Speed / ETA
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {

        let total = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : totalBytes
        guard total > 0 else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        let bps = elapsed > 0 ? Double(totalBytesSent) / elapsed : 0
        let mbps = bps / 1_000_000.0

        let remaining = Double(total - totalBytesSent)
        let eta = bps > 0 ? remaining / bps : 0

        let prog = Double(totalBytesSent) / Double(total)

        DispatchQueue.main.async {
            self.progressCb?(prog, mbps, eta)
        }
    }
}
