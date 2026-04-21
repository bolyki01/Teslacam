# Teslacam

Teslacam now ships two paths:

- a native macOS app for browsing and exporting footage on Apple Silicon Macs running macOS 26
- a separate cross-platform Python CLI in the GitHub repo for Windows, macOS, and Linux

The macOS app now uses a native Swift export path. The CLI keeps the earlier portable ffmpeg-based workflow for power users and automation.

## What changed

- new interactive CLI: `teslacam-cli`
- cross-platform launcher scripts: `teslacam-cli`, `teslacam-cli.bat`, `teslacam.sh`
- exact time trimming to the second for first/last overlapping clip sets
- safer duplicate resolution and output conflict handling in the CLI
- native-resolution-first layout sizing; no forced downscale of camera tiles
- onboarding-first app launch; no automatic source restore on startup
- loaded timeline card now includes inline range, preset, duplicate, and camera export controls
- true-time timeline with visible recording gaps
- default output: HEVC/H.265 MP4 with `hvc1` tag for broad player compatibility, including VLC
- zero third-party Python package dependencies
- CLI stays separate from the Mac app bundle

## Requirements

- Python 3.9+
- `ffmpeg` and `ffprobe`
- `ffmpeg` must include `libx265` for lossless or CRF 6 HEVC export

On macOS, the CLI can also use bundled `TeslaCam/Resources/ffmpeg_bin/ffmpeg` and `ffprobe` if present and executable. The App Store app does not bundle those tools.

## Native app

- startup always begins on onboarding until the user chooses a source folder
- timeline spacing follows real recording time from first clip to last clip
- loaded timeline view surfaces quick range actions, export preset, duplicate handling, and per-camera export toggles
- uncovered spans are shown as visible gaps and preview as "no recording"
- HW4 sources with `left`, `right`, `left_pillar`, and `right_pillar` are detected automatically
- HW4 composite export uses a centered 3x3 layout
- native HEVC presets scale bitrate with output canvas size
- ProRes 422 HQ stays the highest-fidelity native export preset
- composite export is always rendered output; it is not stream-copy passthrough
- Debug builds show recent debug events for quick failure triage

## Quick start

Run directly from the repo root:

```sh
./teslacam-cli
```

or:

```sh
python3 teslacam.py
```

Windows:

```bat
teslacam-cli.bat
```

You can also install the CLI entry point:

```sh
pip install .
teslacam-cli
```

## Interactive flow

The interactive mode prompts for:

1. TeslaCam source folder
2. car/layout profile
3. exact start time
4. exact end time
5. output mode
6. output MP4 path or output directory
7. optional work directory retention

When duplicate clips are detected, the CLI reports the conflict counts up front and applies the selected duplicate policy consistently with the macOS app.

## Non-interactive examples

Lossless HEVC MP4, auto-detected layout:

```sh
python3 teslacam.py /path/to/TeslaCam \
  --start "2026-04-01 18:30:15" \
  --end "2026-04-01 18:42:40" \
  --output /path/to/output/teslacam_lossless.mp4
```

Force legacy 4-camera layout:

```sh
python3 teslacam.py /path/to/TeslaCam \
  --profile legacy4 \
  --start "01/04/2026-18:30:15" \
  --end "01/04/2026-18:42:40"
```

Force 6-camera layout with preserved intermediates:

```sh
python3 teslacam.py /path/to/TeslaCam \
  --profile sixcam \
  --keep-workdir \
  --workdir /path/to/work
```

Resolve duplicate clips by newest file and avoid overwriting an existing export:

```sh
python3 teslacam.py /path/to/TeslaCam \
  --duplicate-policy prefer-newest \
  --output-conflict unique \
  --output /path/to/output
```

## Output modes

- `lossless` — default. H.265/HEVC MP4 using `libx265` lossless mode. Largest files. Best fidelity.
- `quality` — H.265/HEVC MP4 using `libx265 -crf 6`. Still very high quality, smaller files.

## Layout behavior

- `auto` chooses 6-camera if HW4 `left` / `right` or pillar clips are present, otherwise 4-camera
- missing, unreadable, or corrupt cameras render as black placeholders instead of aborting the whole export
- HW4 composite layout uses a centered 3x3 canvas with intentional empty cells
- 4-camera layout uses per-row and per-column maxima from probed source clips
- HW4 3x3 layout uses a uniform tile size based on the largest detected source clip

## Time parsing accepted by CLI

- `DD/MM/YYYY-HH:MM:SS`
- `YYYY-MM-DD HH:MM:SS`
- `YYYY-MM-DD_HH-MM-SS`
- `YYYY-MM-DDTHH:MM:SS`

## Tests

Unit tests:

```sh
python3 -m unittest tests.test_scanner tests.test_layouts tests.test_timing tests.test_cli
```

Native app tests:

```sh
script/test_native.sh
```

## Canonical docs

- [Agent guide](./AGENTS.md)
- [Debugging guide](./DEBUGGING.md)
- [Release checklist](./RELEASE_CHECKLIST.md)

Integration smoke test with ffmpeg:

```sh
python3 -m unittest tests.test_integration
```

Combined Python verification:

```sh
python3 -m unittest tests.test_scanner tests.test_layouts tests.test_timing tests.test_cli tests.test_integration
```

## Notes

- `TeslaCam/Resources/LICENSES.md` and `TeslaCam/Resources/ffmpeg_bin/` are support assets for the CLI path.
- `TeslaCam/BrandAssets/AppIcon.svg` is the editable vector master for the macOS app icon.
- `_legacy/` stays non-canonical.
- root `teslacam_legacy_macos.sh` keeps the previous mac-only shell flow as fallback.
- If you build the macOS app side, source `/Users/bolyki/dev/source/build-env.sh` by default, or point `TESLACAM_BUILD_ENV` at a compatible local override.
- the CLI does not depend on Homebrew, pip packages, or a GUI.
