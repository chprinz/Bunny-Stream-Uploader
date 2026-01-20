# Bunny Uploader

A simple macOS app for uploading videos to Bunny Stream — with pause/resume, library sync, renaming, and custom thumbnails.

## Quick start

### Option A: Download the app (recommended)
Get the latest build from the Releases page:
https://github.com/chprinz/Bunny-Stream-Uploader/releases/

1) Download the **.zip** from the latest release.
2) Unzip it, then drag **Bunny Uploader.app** into **Applications**.
3) Open the app.

#### macOS security note (first launch)
Because this app is distributed outside the Mac App Store, macOS might block it the first time.

Try this first:
- In Finder, right-click **Bunny Uploader.app** → **Open** → **Open**

If it’s still blocked:
- **System Settings → Privacy & Security** → scroll down → **Open Anyway**

### Option B: Build it yourself (for developers)
Scroll down to **Building & running**.

---

## What you need
- A Bunny Stream **AccessKey** for each library you want to use

On first launch you’ll add:
- **Library Name** (friendly label)
- **Library ID** (from Bunny Stream)
- **AccessKey** (Stream API key)

Your keys are stored locally in **Keychain**.

---

## Features
- Drag-and-drop uploads with TUS pause/resume
- Auto-resume on reconnect, and resume after relaunch (upload URL is persisted)
- Library sync (pulls remote videos, dates, thumbnails, status)
- Edit titles, upload thumbnails, copy embed URL
- Delete locally or from Bunny

---

## Upload reliability & resume
- Each upload stores its TUS upload URL and progress in:
  `~/Library/Application Support/BunnyUploader/uploads.json`
  so the app can continue an interrupted transfer without recreating the video.
- A Settings toggle enables auto-resume: paused uploads are moved back to pending on app launch or when the network reconnects; you can still resume/pause items individually.
- Global controls let you pause/resume everything in one click; cancellations clean up the remote video when possible, while leaving successfully uploaded items untouched.

---

## Requirements (building from source)
- macOS 13+ (tested on macOS 15)
- Xcode 15+
- Bunny Stream AccessKey for each library you want to use

## Setup (building from source)
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

## Building & running (notes)
- Debug logging is guarded by `#if DEBUG` in `Services/APIService.swift`.
- Release build: **Product → Archive**, then export the app (Organizer → Distribute App).