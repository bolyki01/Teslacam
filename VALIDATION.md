# Validation

## Native macOS app

- onboarding-first launch
- true-time timeline gaps
- gap preview state
- aligned unified playback and export controls
- unique export naming when exporting into a directory with an existing file
- Debug-build settings debug log visibility
- HW4 scanner support for `left`, `right`, `left_pillar`, and `right_pillar`
- native HW4 centered 3x3 composite export
- Apple Silicon macOS 26 app target

## CLI

- camera token normalization
- clip grouping by Tesla timestamp
- duplicate policy and output conflict handling
- 4-camera layout sizing
- HW4 centered 3x3 layout sizing
- missing-dimension fallback logic
- corrupt clip placeholder fallback
- end-to-end compose path

## Debugging references

- see [DEBUGGING.md](./DEBUGGING.md) for clean launch, gap checks, export diagnostics, and HW4 fixture validation
- see [RELEASE_CHECKLIST.md](./RELEASE_CHECKLIST.md) for ship gating
