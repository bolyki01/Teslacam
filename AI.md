# AI.md

## Overview
TeslaCam is a macOS app for browsing and exporting Tesla Sentry/Dashcam footage with synced multi-camera playback and HEVC export.

## Layout
- `TeslaCam/`: app source.
- `TeslaCam/Resources/`: scripts, bundled ffmpeg, and licences.
- `TeslaCamTests/` and `TeslaCamUITests/`: automated coverage.
- `README.md`: build, run, and usage notes.

## Commands
```bash
xcodebuild -project TeslaCam.xcodeproj -scheme TeslaCam -destination 'platform=macOS' build
xcodebuild -project TeslaCam.xcodeproj -scheme TeslaCam -destination 'platform=macOS' test
```
Open the app project with `open TeslaCam.xcodeproj` for interactive work.

## Guardrails
- Preserve Apple-Silicon/Metal/AVFoundation assumptions unless the spec changes.
- Do not replace bundled tooling or licence files casually.
- Keep export-path logging and video pipeline changes measurable; performance matters here.
