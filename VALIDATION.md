# Validation

Validated in Linux container.

## Automated tests

Passed:

```sh
python3 -m unittest tests.test_scanner tests.test_layouts tests.test_integration -v
```

Coverage from these tests:

- camera token normalization
- clip grouping by Tesla timestamp
- 4-up layout sizing logic
- missing-dimension fallback logic
- end-to-end compose to HEVC/H.265 MP4 with ffmpeg/ffprobe

## Manual smoke validation

Also verified manually:

- 6-camera layout compose path
- partial-range trim across two consecutive clip sets
- final output codec: `hevc`
- final output container: MP4
- final output duration matched requested trimmed range

## Notes

- Windows and macOS wrapper scripts were added but not executed in this Linux container.
- The CLI itself is pure Python plus ffmpeg/ffprobe and does not depend on OS-specific Python packages.
- The existing macOS SwiftUI app remains in the repo unchanged; the new CLI is the portable export path.
