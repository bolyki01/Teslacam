# Teslacam

Teslacam now ships two paths:

- the existing macOS SwiftUI app for browsing and exporting footage
- a new cross-platform Python CLI for Windows, macOS, and Linux

The CLI is designed for maximum output fidelity. It composes Tesla multi-camera clips into a single MP4 using H.265/HEVC. Default mode is **x265 lossless**, which still uses a compressed codec but preserves decoded pixels from the composed timeline instead of applying lossy recompression. If the native composite canvas becomes very large, the CLI keeps it.

## What changed

- new interactive CLI: `teslacam-cli`
- cross-platform launcher scripts: `teslacam-cli`, `teslacam-cli.bat`, `teslacam.sh`
- exact time trimming to the second for first/last overlapping clip sets
- native-resolution-first layout sizing; no forced downscale of camera tiles
- default output: HEVC/H.265 MP4 with `hvc1` tag for broad player compatibility, including VLC
- zero third-party Python package dependencies
- existing macOS app and export scripts remain in place

## Requirements

- Python 3.9+
- `ffmpeg` and `ffprobe`
- `ffmpeg` must include `libx265` for lossless or CRF 6 HEVC export

On macOS, the repo can also use the bundled `TeslaCam/Resources/ffmpeg_bin/ffmpeg` and `ffprobe` if present and executable.

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
6. output MP4 path
7. optional work directory retention

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

## Output modes

- `lossless` — default. H.265/HEVC MP4 using `libx265` lossless mode. Largest files. Best fidelity.
- `quality` — H.265/HEVC MP4 using `libx265 -crf 6`. Still very high quality, smaller files.

## Layout behavior

- `auto` chooses 6-camera if pillar clips are present, otherwise 4-camera
- missing cameras render as black placeholders
- tile sizes come from probed source clips and are padded rather than forcibly downscaled
- composite canvas is derived from per-row and per-column maxima, not a fixed low-resolution canvas

## Time parsing accepted by CLI

- `DD/MM/YYYY-HH:MM:SS`
- `YYYY-MM-DD HH:MM:SS`
- `YYYY-MM-DD_HH-MM-SS`
- `YYYY-MM-DDTHH:MM:SS`

## Tests

Unit tests:

```sh
python3 -m unittest tests.test_scanner tests.test_layouts
```

Integration smoke test with ffmpeg:

```sh
python3 -m unittest tests.test_integration
```

## Notes

- `TeslaCam/Resources/LICENSES.md` and `TeslaCam/Resources/ffmpeg_bin/` are support assets.
- `_legacy/` stays non-canonical.
- root `teslacam_legacy_macos.sh` keeps the previous mac-only shell flow as fallback.
- the new CLI does not depend on Homebrew, pip packages, or a GUI.
