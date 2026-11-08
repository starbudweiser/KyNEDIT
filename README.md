# kYNEDIT

A personal, simplified, high-performance macOS media browser and transcoder: Kyno-style browsing, tagging and subclips, EditReady-style fast transcoding, and export to DaVinci Resolve, Final Cut Pro and Premiere Pro.

## About

kYNEDIT is made by Starbudweiser & Claude Code (Anthropic). MIT License, © 2026 Starbudweiser. Provided as is, without warranty. Inspired by Kyno (Lesspain Software) and EditReady (Divergent Media), not affiliated with either. See "About kYNEDIT" in the app menu.

## Features

- Folder browser with incremental indexing (SQLite, full-text search), thumbnails, grid and list views.
- Ratings, colour labels, keywords, notes, markers and subclips, all stored in a local catalogue (source files are never modified).
- Fast transcoding to ProRes / HEVC / H.264 with a hardware-aware scheduler (media engines, thermal state, storage type, measured benchmark), optional LUT.
- RAW: Blackmagic RAW and RED R3D (CPU and Metal GPU decode) through the manufacturers' SDKs, which are not part of this repository.
- Exchange files for DaVinci Resolve and Final Cut Pro (FCPXML 1.11) and Premiere Pro (xmeml; import not yet tested).
- Automatic updates from GitHub releases (Developer ID signature checked, never during an export). Languages: French, English, Spanish, Italian.

## Build

```bash
./build.sh [version]     # builds, signs and installs ~/Applications/Applications Personnelles/kYNEDIT.app
./release.sh <version>   # builds, notarises, tags and publishes a GitHub release
```

RAW support needs the SDKs placed in `vendor/` (git-ignored): `BlackmagicRawAPI.framework` and `R3DSDK`. Without them the app builds and RAW files are listed but not decoded.
