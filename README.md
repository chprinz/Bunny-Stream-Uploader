# Bunny Uploader

A macOS SwiftUI app for uploading videos to Bunny Stream with persistent pause/resume, library sync, title edit, and thumbnail upload.

## Requirements
- macOS 13+ (tested on 14)
- Xcode 15+
- Bunny Stream AccessKey for each library you want to use

## Setup
1) Clone the repo and open `Bunny Uploader.xcodeproj` in Xcode.
2) Build & run. On first launch, add a Library in Settings with:
   - Name (friendly label)
   - Library ID (from Bunny Stream)
   - AccessKey (Stream API key) — stored in Keychain, not in the repo
3) Optional: set a pull zone host for thumbnails and a default collection.

### Optional env vars
Set these before launch if you prefer environment-based config:
- `BUNNY_PULLZONE`, `BUNNY_PULL_ZONE`, or `BUNNY_PULLZONE_<LIBRARYID>` for CDN host
- `BUNNY_TOKEN_<LIBRARYID>` for signed thumbnail token

## Features
- Drag-and-drop uploads with TUS pause/resume, auto-resume on reconnect, and resume after relaunch (upload URL is persisted)
- Per-item and global pause/resume controls, plus pause-on-disconnect with optional auto-retry when back online
- Library sync (pulls remote videos, dates, thumbnails, status)
- Edit titles, upload thumbnails, copy embed URL
- Delete locally or from Bunny
- Keeps system awake during active uploads (toggle in Settings)

## Upload reliability & resume
- Each upload stores its TUS upload URL and progress in `~/Library/Application Support/BunnyUploader/uploads.json` so the app can continue an interrupted transfer without recreating the video.
- A Settings toggle enables auto-resume: paused uploads are moved back to pending on app launch or when the network reconnects; you can still resume/pause items individually.
- Global controls let you pause/resume everything in one click; cancellations clean up the remote video when possible, while leaving successfully uploaded items untouched.

## Building & running
- Debug logging is guarded by `#if DEBUG` in `Services/APIService.swift`.
- Release build: Product > Archive, then export signed/notarized if distributing binaries.

## Distribution options
- **Source**: Publish this repo to GitHub; others build in Xcode.
- **Binary**: Archive a Release build, sign with your Developer ID, notarize, and zip/DMG the app. Attach to a GitHub Release with a short first-run note about adding a library and AccessKey.
- **Auto-updates (optional)**: Integrate Sparkle if you want update feeds; not included here.

## Contributing
Issues and PRs welcome. Keep API keys out of code; use Keychain/env. Avoid committing DerivedData, build products, and local upload history.

## License
MIT — see `LICENSE`.
