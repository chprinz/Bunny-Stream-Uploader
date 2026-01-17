//
//  UploadModels.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import Foundation

enum UploadStatus: String, Codable {
    case pending, uploading, paused, success, failed, canceled

    // User-facing status buckets
    var uiLabel: String {
        switch self {
        case .uploading, .pending: return "Uploading"
        case .paused: return "Paused"
        case .success: return "Ready"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }
}

struct UploadItem: Identifiable, Codable {
    var id: UUID = UUID()
    var file: URL
    var createdAt: Date = Date()

    // Ziel pro Upload (hier NICHT optional, weil Default-Library Pflicht ist)
    var libraryConfigId: String
    var libraryId: String
    var collectionId: String? = nil

    // Status/Telemetrie
    var status: UploadStatus = .pending
    var progress: Double = 0
    var speedMBps: Double = 0
    var etaSeconds: TimeInterval = 0

    // Ergebnis
    var videoId: String? = nil
    var errorMessage: String? = nil
    var completedAt: Date? = nil
    var remoteTitle: String? = nil
    var remoteDescription: String? = nil
    var remoteThumbnailPath: String? = nil
    var remoteStatusCode: Int? = nil
    var remoteEncodeProgress: Double? = nil
    var processingReadyNotified: Bool = false

    // TUS Resume Support
    var tusUploadURL: URL? = nil
    var bytesUploaded: Int64 = 0
    var totalBytes: Int64 = 0
    var lastResumeAttempt: Date? = nil
    
    init(
        file: URL,
        libraryConfigId: String,
        libraryId: String,
        collectionId: String?,
        status: UploadStatus,
        progress: Double,
        speedMBps: Double,
        etaSeconds: TimeInterval,
        videoId: String?,
        completedAt: Date? = nil
    ) {
        self.id = UUID()
        self.file = file
        self.createdAt = Date()

        self.libraryConfigId = libraryConfigId
        self.libraryId = libraryId
        self.collectionId = collectionId

        self.status = status
        self.progress = progress
        self.speedMBps = speedMBps
        self.etaSeconds = etaSeconds

        self.videoId = videoId
        self.errorMessage = nil
        self.completedAt = completedAt
        self.remoteTitle = nil
        self.remoteDescription = nil
        self.remoteThumbnailPath = nil
        self.remoteStatusCode = nil
        self.remoteEncodeProgress = nil
        self.processingReadyNotified = false
        self.tusUploadURL = nil
        self.bytesUploaded = 0
        self.totalBytes = 0
        self.lastResumeAttempt = nil
    }
    
    // Custom decoder to migrate legacy UUID fields to String
    enum CodingKeys: String, CodingKey {
        case id, file, createdAt
        case libraryConfigId, libraryId, collectionId
        case libraryConfigUUID, libraryUUID
        case status, progress, speedMBps, etaSeconds
        case videoId, errorMessage
        case completedAt
        case remoteTitle, remoteDescription, remoteThumbnailPath
        case remoteStatusCode, remoteEncodeProgress, processingReadyNotified
        case tusUploadURL, bytesUploaded, totalBytes, lastResumeAttempt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let url = try? c.decode(URL.self, forKey: .file) {
            self.file = url
        } else if let s = try? c.decode(String.self, forKey: .file),
                  let url = URL(string: s) {
            self.file = url
        } else {
            self.file = URL(fileURLWithPath: "/dev/null")
        }
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()

        func decodeStringOrUUIDString(_ key: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let u = try? c.decode(UUID.self, forKey: key) { return u.uuidString }
            return nil
        }

        self.libraryConfigId =
            decodeStringOrUUIDString(.libraryConfigId)
            ?? decodeStringOrUUIDString(.libraryConfigUUID)
            ?? ""

        self.libraryId =
            decodeStringOrUUIDString(.libraryId)
            ?? decodeStringOrUUIDString(.libraryUUID)
            ?? ""

        self.collectionId = try c.decodeIfPresent(String.self, forKey: .collectionId)

        self.status = try c.decodeIfPresent(UploadStatus.self, forKey: .status) ?? .pending
        self.progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        self.speedMBps = try c.decodeIfPresent(Double.self, forKey: .speedMBps) ?? 0
        self.etaSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .etaSeconds) ?? 0

        self.videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.remoteTitle = try c.decodeIfPresent(String.self, forKey: .remoteTitle)
        self.remoteDescription = try c.decodeIfPresent(String.self, forKey: .remoteDescription)
        self.remoteThumbnailPath = try c.decodeIfPresent(String.self, forKey: .remoteThumbnailPath)
        self.remoteStatusCode = try c.decodeIfPresent(Int.self, forKey: .remoteStatusCode)
        self.remoteEncodeProgress = try c.decodeIfPresent(Double.self, forKey: .remoteEncodeProgress)
        self.processingReadyNotified = try c.decodeIfPresent(Bool.self, forKey: .processingReadyNotified) ?? false

        self.tusUploadURL = try c.decodeIfPresent(URL.self, forKey: .tusUploadURL)
        self.bytesUploaded = try c.decodeIfPresent(Int64.self, forKey: .bytesUploaded) ?? 0
        self.totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        self.lastResumeAttempt = try c.decodeIfPresent(Date.self, forKey: .lastResumeAttempt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(id, forKey: .id)
        try c.encode(file, forKey: .file)
        try c.encode(createdAt, forKey: .createdAt)

        try c.encode(libraryConfigId, forKey: .libraryConfigId)
        try c.encode(libraryId, forKey: .libraryId)
        try c.encodeIfPresent(collectionId, forKey: .collectionId)

        try c.encode(status, forKey: .status)
        try c.encode(progress, forKey: .progress)
        try c.encode(speedMBps, forKey: .speedMBps)
        try c.encode(etaSeconds, forKey: .etaSeconds)

        try c.encodeIfPresent(videoId, forKey: .videoId)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(remoteTitle, forKey: .remoteTitle)
        try c.encodeIfPresent(remoteDescription, forKey: .remoteDescription)
        try c.encodeIfPresent(remoteThumbnailPath, forKey: .remoteThumbnailPath)
        try c.encodeIfPresent(remoteStatusCode, forKey: .remoteStatusCode)
        try c.encodeIfPresent(remoteEncodeProgress, forKey: .remoteEncodeProgress)
        try c.encode(processingReadyNotified, forKey: .processingReadyNotified)

        try c.encodeIfPresent(tusUploadURL, forKey: .tusUploadURL)
        try c.encode(bytesUploaded, forKey: .bytesUploaded)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encodeIfPresent(lastResumeAttempt, forKey: .lastResumeAttempt)
    }

    // make ETA readable
    var etaFormatted: String {
        if etaSeconds <= 0 { return "—" }
        let s = Int(etaSeconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    var displayTitle: String {
        remoteTitle?.isEmpty == false ? (remoteTitle ?? "") : file.lastPathComponent
    }
}
