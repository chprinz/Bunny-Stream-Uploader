//
//  UploadListView.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct UploadListView: View {
    let selectedLibraryId: UUID?
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var uploads: UploadManager
    @State private var showDeleteAlert = false
    @State private var pendingDeleteItem: UploadItem? = nil
    @State private var showHistory = false
    @State private var showRemoteDeleteAlert = false
    @State private var pendingRemoteDeleteItem: UploadItem? = nil
    @State private var editingItemId: UUID? = nil
    @State private var editTitle: String = ""
    @State private var isLoadingDetails = false
    @State private var isSavingDetails = false
    @State private var isUploadingThumbnail = false
    @State private var lastEditError: String? = nil
    @State private var lastDetailsError: String? = nil
    @State private var lastFetchedTitle: String? = nil
    @State private var hoveredThumbId: UUID? = nil
    @State private var hoveredTitleId: UUID? = nil
    @State private var isSyncingLibrary = false
    @State private var scrollAnchorID = "top"

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
        .sorted { lhs, rhs in
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    Color.clear.frame(height: 0.1).id(scrollAnchorID)

                    if !activeItems.isEmpty {
                        HStack {
                            Text("Active uploads")
                                .font(.headline)
                            Spacer()
                        }
                    }

                    ForEach(activeItems) { item in
                        activeUploadRow(for: item)
                    }

                    Button {
                        withAnimation { showHistory.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                            Text("Library (\(historyItems.count))")
                                .font(.headline)
                            if isSyncingLibrary {
                                ProgressView().scaleEffect(0.65)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)

                    if showHistory {
                        ForEach(historySections, id: \.date) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)

                                ForEach(section.items) { item in
                                    historyRow(for: item)
                                }
                            }
                        }
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
            .alert("Delete from Bunny library?", isPresented: $showRemoteDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    pendingRemoteDeleteItem = nil
                }
                Button("Delete", role: .destructive) {
                    if let target = pendingRemoteDeleteItem {
                        uploads.deleteFromBunny(itemId: target.id) { _ in
                            pendingRemoteDeleteItem = nil
                        }
                    }
                }
            } message: {
                if let vid = pendingRemoteDeleteItem?.videoId {
                    Text("This will remove the video (\(vid)) from Bunny and from this list.")
                } else {
                    Text("This will remove the video from Bunny and from this list.")
                }
            }
            .onChange(of: showHistory) { newValue in
                if newValue { syncHistoryWithRemote() }
            }
            .onChange(of: selectedLibraryId) { _ in
                withAnimation { proxy.scrollTo(scrollAnchorID, anchor: .top) }
                syncHistoryWithRemote()
            }
            .onAppear {
                syncHistoryWithRemote()
            }
        }
    }

    // MARK: - Rows

    private func activeUploadRow(for item: UploadItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        Text(statusLine(for: item))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        statusPill(for: item)

                        if item.status != .success && item.status != .failed && item.status != .canceled {
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
                }

                if item.status == .success {
                    if let vid = item.videoId {
                        Text(vid)
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

    private func historyRow(for item: UploadItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnailView(for: item)

            VStack(alignment: .leading, spacing: 6) {
                if editingItemId == item.id {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Title", text: $editTitle)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                                .disabled(isSavingDetails)
                            if isLoadingDetails || isSavingDetails {
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Cancel") {
                                editingItemId = nil
                                lastEditError = nil
                                lastDetailsError = nil
                            }
                            Button("Save") {
                                saveEdits(for: item)
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isSavingDetails || editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let error = lastEditError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        if let warn = lastDetailsError {
                            Text(warn)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(item.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        if hoveredTitleId == item.id, item.videoId != nil {
                            Button {
                                startEditing(item)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Edit title")
                        }
                    }
                    .onHover { hovering in
                        hoveredTitleId = hovering ? item.id : (hoveredTitleId == item.id ? nil : hoveredTitleId)
                    }
                }

                if let vid = item.videoId {
                    Text(vid)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Text(completionLine(for: item))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                statusPill(for: item)

                Menu {
                    if let url = playURL(for: item) {
                        Button("Copy play URL") { copyPlayURL(url) }
                    }

                    Button(role: .destructive) {
                        pendingRemoteDeleteItem = item
                        showRemoteDeleteAlert = true
                    } label: {
                        Text("Delete from Bunny library")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(4)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .padding(.trailing, 6) // avoid scrollbar overlap
    }

    // MARK: - URL helpers

    private func playURL(for item: UploadItem) -> URL? {
        guard let vid = item.videoId else { return nil }
        return URL(string: "https://iframe.mediadelivery.net/embed/\(item.libraryId)/\(vid)")
    }

    private func copyPlayURL(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    private func library(for item: UploadItem) -> LibraryConfig? {
        store.libraries.first(where: { $0.id.uuidString == item.libraryConfigId })
    }

    private func thumbnailURL(for item: UploadItem) -> URL? {
        guard item.status == .success,
              let raw = item.remoteThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if let direct = URL(string: raw), direct.scheme != nil {
            return direct
        }

        guard let videoId = item.videoId else { return nil }
        guard let lib = library(for: item),
              let base = store.thumbnailBaseURL(for: lib) else { return nil }

        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else { return nil }

        var url = base
        let components = cleaned.split(separator: "/")
        if components.count > 1 {
            for comp in components {
                url.appendPathComponent(String(comp))
            }
            return url
        }

        url.appendPathComponent(videoId)
        url.appendPathComponent(cleaned)
        return url
    }

    // MARK: - Edit helpers

    private func startEditing(_ item: UploadItem) {
        editingItemId = item.id
        editTitle = item.remoteTitle ?? item.displayTitle
        lastFetchedTitle = editTitle
        lastEditError = nil
        lastDetailsError = nil
        loadDetails(for: item)
    }

    private func loadDetails(for item: UploadItem) {
        guard item.videoId != nil else { return }
        isLoadingDetails = true
        uploads.refreshVideoDetails(itemId: item.id) { updated in
            DispatchQueue.main.async {
                isLoadingDetails = false
                if let up = updated {
                    let newTitle = up.remoteTitle ?? up.displayTitle
                    if editTitle == lastFetchedTitle {
                        editTitle = newTitle
                    }
                    lastFetchedTitle = newTitle
                    lastDetailsError = nil
                } else {
                    lastDetailsError = "Could not refresh details from Bunny."
                }
            }
        }
    }

    private func saveEdits(for item: UploadItem) {
        guard item.videoId != nil else { return }
        isSavingDetails = true
        lastEditError = nil
        uploads.updateMetadata(itemId: item.id, title: editTitle) { ok in
            DispatchQueue.main.async {
                isSavingDetails = false
                if !ok {
                    lastEditError = "Could not save changes. Please retry."
                } else {
                    editingItemId = nil
                    lastFetchedTitle = editTitle
                }
            }
        }
    }

    private func pickThumbnail(for item: UploadItem) {
        guard item.videoId != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]

        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                lastEditError = "Could not read file."
                return
            }
            let mime = mimeType(for: url)
            isUploadingThumbnail = true
            lastEditError = nil
            uploads.uploadThumbnail(itemId: item.id, data: data, mimeType: mime) { ok in
                DispatchQueue.main.async {
                    isUploadingThumbnail = false
                    if !ok {
                        lastEditError = "Thumbnail upload failed."
                    } else {
                        loadDetails(for: item)
                    }
                }
            }
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }

    // MARK: - UI helpers

    @ViewBuilder
    private func thumbnailView(for item: UploadItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let content: some View = Group {
            if let url = thumbnailURL(for: item) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ZStack {
                            shape.fill(Color.primary.opacity(0.05))
                            ProgressView().scaleEffect(0.6)
                        }
                    case .failure:
                        shape
                            .fill(Color.primary.opacity(0.05))
                            .overlay(
                                Image(systemName: "video.slash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.6))
                            )
                    @unknown default:
                        shape.fill(Color.primary.opacity(0.05))
                    }
                }
            } else {
                shape
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.55))
                    )
            }
        }

        Button {
            pickThumbnail(for: item)
        } label: {
            ZStack {
                content
                    .frame(width: 96, height: 54)
                    .clipShape(shape)
                    .overlay(alignment: .bottomLeading) {
                        if let durationText = durationText(for: item.remoteDurationSeconds) {
                            Text(durationText)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(Color.black.opacity(0.55))
                                )
                                .padding(6)
                        }
                    }

                if hoveredThumbId == item.id && item.videoId != nil {
                    shape
                        .fill(Color.black.opacity(0.25))
                        .frame(width: 96, height: 54)
                        .overlay(
                            Label("Change", systemImage: "photo.on.rectangle")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        )
                        .clipShape(shape)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredThumbId = hovering ? item.id : (hoveredThumbId == item.id ? nil : hoveredThumbId)
        }
        .disabled(item.videoId == nil)
    }

    private func controlButton(systemName: String, action: @escaping () -> Void, hint: String) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.4), lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(hint)
    }

    private func statusText(_ s: UploadStatus) -> String { s.uiLabel }

    private func statusLine(for item: UploadItem) -> String {
        if item.status == .uploading {
            return "\(Int(item.progress * 100))% · \(String(format: "%.1f", item.speedMBps)) MB/s · ETA \(item.etaFormatted)"
        }
        if isProcessing(item) {
            let prog = item.remoteEncodeProgress.map { Int($0) } ?? 0
            return "Processing on Bunny… (\(prog)%)"
        }
        return statusText(item.status)
    }

    private func statusPill(for item: UploadItem) -> some View {
        let processing = isProcessing(item)
        let text: String = {
            if processing { return "Processing" }
            return item.status.uiLabel
        }()

        let palette: (Color, Color) = {
            if processing {
                return (Color.orange.opacity(0.18), Color.orange)
            }
            switch item.status {
            case .uploading, .pending:
                return (Color.blue.opacity(0.15), Color.blue)
            case .paused:
                return (Color.orange.opacity(0.18), Color.orange)
            case .success:
                return (Color.green.opacity(0.18), Color.green)
            case .failed:
                return (Color.red.opacity(0.18), Color.red)
            case .canceled:
                return (Color.gray.opacity(0.16), Color.gray)
            }
        }()

        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.0)
            .foregroundColor(palette.1)
            .clipShape(Capsule())
    }

    private func completionLine(for item: UploadItem) -> String {
        let date = item.completedAt ?? item.createdAt
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        let timestamp = formatter.string(from: date)
        let label = isProcessing(item) ? "Processing" : item.status.uiLabel
        return "\(label) \(timestamp)"
    }

    private func durationText(for seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(round(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func isProcessing(_ item: UploadItem) -> Bool {
        guard item.status == .success else { return false }
        if let prog = item.remoteEncodeProgress {
            return prog < 100
        }
        return false
    }

    private func syncHistoryWithRemote() {
        guard let libId = selectedLibraryId,
              let lib = store.libraries.first(where: { $0.id == libId }) else { return }

        isSyncingLibrary = true
        uploads.syncLibrary(lib) {
            DispatchQueue.main.async {
                isSyncingLibrary = false
            }
        }
    }
}
