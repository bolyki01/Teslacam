# Debugging

## Clean launch

- normal app launch now starts on onboarding
- debug source injection is Debug-build only
- use `TESLACAM_DEBUG_SOURCE=/absolute/path/to/TeslaCam` to inject a source directly
- use `TESLACAM_UI_TEST_MODE=blank` for empty onboarding
- use `TESLACAM_UI_TEST_MODE=sample` for a fake sample timeline

## Timeline and gap checks

- load a source with known holes
- confirm the timeline keeps true clock spacing
- scrub into a visible gap and confirm preview shows no-recording state
- compare the shown time against the actual folder timestamps

## Export checks

- native export writes progress and phase details to the app log file
- use the in-app `Show Log` action after a failed or cancelled export
- compare requested trim range, selected cameras, layout canvas size, duplicate policy, and final phase
- confirm existing-output exports choose a unique filename instead of clobbering the first file

## Reliability checks

- inspect debug events for:
  - indexing start and completion
  - detected camera set and layout profile
  - duplicate summary and chosen duplicate policy
  - derived gap count
  - seek begin, live segment loads, and exact seek end
  - clip load vs gap load
  - telemetry load success vs fallback
  - export request and export phase changes
- use the Settings window in Debug builds to inspect the recent in-app debug event list

## HW4 fixture validation

- create synthetic files with names:
  - `front`
  - `back` or `rear`
  - `left`
  - `right`
  - `left_pillar`
  - `right_pillar`
- confirm the scanner groups them into one timestamped set
- confirm the native app and CLI both choose HW4 layout
- confirm HW4 export uses the centered 3x3 composite

## CLI checks

- verify `teslacam-cli --duplicate-policy` accepts `merge-by-time`, `keep-all`, and `prefer-newest`
- verify `--output-conflict` accepts `unique`, `overwrite`, and `error`
- verify passing an output directory produces a timestamped MP4 inside that directory
- verify corrupt or unreadable camera clips render as black tiles, not a hard failure
