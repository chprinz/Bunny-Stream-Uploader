//
//  UploadListView.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import SwiftUI

struct UploadListView: View {
    let selectedLibraryId: UUID?
    @EnvironmentObject private var uploads: UploadManager
    @State private var showDeleteAlert = false
    @State private var pendingDeleteItem: UploadItem? = nil
    @State private var showHistory = false

    private let recentSuccessWindow: TimeInterval = 2.5

    private var activeItems: [UploadItem] {
        uploads.items.filter { item in
            if let libId = selectedLibraryId {
                let isRecentSuccess = item.status == .success &&
                    (item.completedAt ?? item.createdAt) > Date().addingTimeInterval(-recentSuccessWindow)

                return item.libraryConfigId == libId.uuidString &&
                    (item.status != .success && item.status != .failed || isRecentSuccess)
            } else {
                return false
            }
        }
    }

    private var historyItems: [UploadItem] {
        uploads.items.filter { item in
            if let libId = selectedLibraryId {
                let isRecentSuccess = item.status == .success &&
                    (item.completedAt ?? item.createdAt) > Date().addingTimeInterval(-recentSuccessWindow)
                return item.libraryConfigId == libId.uuidString &&
                       (item.status == .success || item.status == .failed) &&
                       !isRecentSuccess
            } else {
                return false
            }
        }
        .sorted { (lhs, rhs) in
            let lDate = lhs.completedAt ?? lhs.createdAt
            let rDate = rhs.completedAt ?? rhs.createdAt
            return lDate > rDate
        }
    }

    private var historySections: [(date: Date, title: String, items: [UploadItem])] {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let groups = Dictionary(grouping: historyItems) { item -> Date in
            let date = item.completedAt ?? item.createdAt
            return cal.startOfDay(for: date)
        }

        return groups
            .map { key, value in
                (date: key,
                 title: formatter.string(from: key),
                 items: value.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) })
            }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !activeItems.isEmpty {
                    HStack {
                        Text("Active uploads")
                            .font(.headline)
                        Spacer()
                    }
                }
                ForEach(activeItems) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.file.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)

                                    if item.status == .success {
                                        Text(completionLine(for: item))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(statusLine(for: item))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Spacer()

                                if item.status == .success {
                                    statusPill(for: item)
                                } else {
                                    HStack(spacing: 8) {
                                        if item.status == .uploading {
                                            controlButton(
                                                systemName: "pause.fill",
                                                action: { uploads.pause(itemId: item.id) },
                                                hint: "Pause upload"
                                            )
                                        } else if item.status == .paused {
                                            controlButton(
                                                systemName: "play.fill",
                                                action: { uploads.resume(itemId: item.id) },
                                                hint: "Resume upload"
                                            )
                                        }

                                        controlButton(
                                            systemName: "xmark",
                                            action: {
                                                if item.status == .uploading {
                                                    pendingDeleteItem = item
                                                    showDeleteAlert = true
                                                } else {
                                                    uploads.cancel(itemId: item.id)
                                                }
                                            },
                                            hint: item.status == .success ? "Remove from list" : "Cancel / delete"
                                        )
                                        .disabled(item.videoId == nil && item.status != .success)
                                        .opacity(item.videoId == nil && item.status != .success ? 0.3 : 1.0)
                                    }
                                }
                            }

                            if item.status == .success {
                                if let vid = item.videoId {
                                    Text("Video ID: \(vid)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            } else {
                                ProgressView(value: item.progress)
                                    .progressViewStyle(.linear)
                                    .frame(height: 8)
                                    .tint(Color("AccentColor").opacity(0.85))
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
                }

                // HISTORY TOGGLE
                Button {
                    withAnimation { showHistory.toggle() }
                } label: {
                    HStack {
                        Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                        Text("History (\(historyItems.count))")
                            .font(.headline)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 20)

                // HISTORY SECTION
                if showHistory {
                    ForEach(historySections, id: \.date) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            ForEach(section.items) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.file.lastPathComponent)
                                            .font(.subheadline)
                                            .lineLimit(1)

                                        Spacer()

                                        statusPill(for: item)
                                    }

                                    if let vid = item.videoId, item.status == .success {
                                        Text("Video ID: \(vid)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .textSelection(.enabled)
                                    }

                                    Text(completionLine(for: item))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.primary.opacity(0.025))
                                )
                                .contextMenu {
                                    Button("Edit settings…") { }
                                        .disabled(true)
                                }
                                .padding(.trailing, 6) // avoid scrollbar overlap
                            }
                        }
                    }

                    // CLEAR HISTORY BUTTON
                    Button(role: .destructive) {
                        for item in historyItems {
                            uploads.removeFromHistory(itemId: item.id)
                        }
                    } label: {
                        Text("Clear history")
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 16)
        .alert("Upload is still running. Delete the video?",
               isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let target = pendingDeleteItem {
                    uploads.cancel(itemId: target.id)
                }
            }
        }
    }

    private func statusText(_ s: UploadStatus) -> String {
        switch s {
        case .pending: return "Waiting…"
        case .uploading: return "Uploading…"
        case .paused: return "Paused"
        case .success: return "Finished"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private func statusLine(for item: UploadItem) -> String {
        switch item.status {
        case .uploading:
            return "\(Int(item.progress * 100))% · \(String(format: "%.1f", item.speedMBps)) MB/s · ETA \(item.etaFormatted)"
        default:
            return statusText(item.status)
        }
    }

    // MARK: - UI helpers

    private func controlButton(systemName: String, action: @escaping () -> Void, hint: String) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("AccentColor"))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06))
                .overlay(
                    Capsule()
                        .stroke(Color("AccentColor").opacity(0.5), lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(hint)
    }

    private func statusPill(for item: UploadItem) -> some View {
        let text = item.status == .success ? "Finished" : "Failed"
        let color = item.status == .success ? Color.green.opacity(0.2) : Color.red.opacity(0.2)
        let textColor = item.status == .success ? Color.green : Color.red

        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color)
            .foregroundColor(textColor)
            .clipShape(Capsule())
    }

    private func completionLine(for item: UploadItem) -> String {
        let date = item.completedAt ?? item.createdAt
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        let timestamp = formatter.string(from: date)
        return "\(item.status == .success ? "Finished" : "Failed") \(timestamp)"
    }
}
