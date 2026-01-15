//
//  UploadDropArea.swift
//  Bunny Uploader
//
//  Created by Christian on 15.01.26.
//

import SwiftUI

import UniformTypeIdentifiers

struct UploadDropArea: View {
    @EnvironmentObject private var uploads: UploadManager
    var defaultLibrary: LibraryConfig?
    var defaultCollectionName: String?

    @State private var showNoLibraryAlert = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .frame(height: 140)

            VStack(spacing: 6) {
                Text("Drop files here or click to pick…")
                if let lib = defaultLibrary {
                    let collectionPart = defaultCollectionName.map { " · \($0)" } ?? ""
                    Text("Target: \(lib.name)\(collectionPart)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Please choose a default library first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .opacity(defaultLibrary == nil ? 0.6 : 1.0)
        .onTapGesture { openPickerOrWarn() }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let lib = defaultLibrary else {
                showNoLibraryAlert = true
                return false
            }

            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let fileURL = url else { return }
                        DispatchQueue.main.async {
                            uploads.enqueue(files: [fileURL], using: lib)
                        }
                    }
                }
            }
            return true
        }
        .alert("No library selected", isPresented: $showNoLibraryAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pick a default library above so uploads know where to go.")
        }
    }

    private func openPickerOrWarn() {
        guard let lib = defaultLibrary else { showNoLibraryAlert = true; return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.begin { resp in
            if resp == .OK {
                uploads.enqueue(files: panel.urls, using: lib)
            }
        }
    }

}
