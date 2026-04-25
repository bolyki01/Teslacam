https://github.com/magrathean-uk/Teslacam

# Teslacam Improvement Plan

## Purpose

This file is for a strong implementation agent. Improve Teslacam while preserving the repo's main contract:

- the native macOS app is the shipping export path
- the Python CLI stays portable and dependency-light
- app and CLI behavior must stay aligned for duplicate handling, timeline math, and export semantics
- `_legacy/` stays reference only
- bundled license and vendor assets are not casual edit targets

## Current State

### Product and architecture

- One repo ships two real surfaces:
  - native macOS app
  - cross-platform Python CLI
- The native app owns the shipping export experience.
- The CLI remains useful for scripted workflows and cross-platform use.
- Native tests, native UI tests, Python unit tests, and Python integration tests already exist.

### What is already good

- The runbook and repo rules are clear.
- The native app already has real test coverage, not just smoke tests.
- The Python CLI is small and readable.
- Duplicate policy is already a first-class concept in both app and CLI.
- Export logging and retry concepts already exist in the native path.
- Security-scoped access and debug launch modes are already considered in the app.

### Main pain points visible in code

- `TeslaCam/AppState.swift` is carrying too much app behavior.
- `TeslaCam/ContentView.swift` is very large and owns too much UI flow.
- `TeslaCam/NativeExportController.swift` is a major reliability hotspot.
- `TeslaCam/Indexer.swift` and `teslacam_cli/scanner.py` implement very similar domain logic in two languages.
- `teslacam_cli/cli.py` is clean but already large enough that more flags and behaviors will get messy fast.

## Key Opportunities

### 1. Define one canonical domain contract shared by app and CLI

Target files:

- `TeslaCam/Indexer.swift`
- `teslacam_cli/scanner.py`
- `teslacam_cli/layouts.py`
- export request and duplicate-policy models

Desired shape:

- Write a single repo-local spec for:
  - clip timestamp parsing
  - camera normalization
  - duplicate resolution
  - output naming
  - timeline range selection
  - layout selection
- Back it with golden fixtures that both the Swift and Python paths must pass.
- Keep language-specific implementations, but stop letting behavior drift.

Why first:

- This is the highest leverage improvement because the repo intentionally ships two implementations of related logic.

### 2. Split native app state and UI into feature-owned pieces

Target files:

- `TeslaCam/AppState.swift`
- `TeslaCam/ContentView.swift`
- `TeslaCam/Main.swift`

Desired shape:

- Break state into focused stores or controllers:
  - source ingestion
  - timeline
  - playback
  - export
  - settings
  - duplicate resolution
- Break the loaded UI into smaller feature views with narrow inputs.
- Keep `AppState` as orchestration glue, not as the whole app.

### 3. Harden the native export pipeline for long-running work

Target files:

- `TeslaCam/NativeExportController.swift`
- `TeslaCam/Exporter.swift`
- `TeslaCam/PlaybackController.swift`

Desired shape:

- Make failure categories explicit and actionable.
- Persist enough structured job metadata to support retry, reveal, and post-mortem triage.
- Add stricter disk-space and write-access preflight checks.
- Make temp-workdir cleanup crash-safe.
- Ensure cancel, retry, and reveal flows stay consistent.

Why first:

- Native export is the shipping path. It should get the best reliability investment.

### 4. Improve indexing and playback performance without changing behavior

Focus areas:

- large source folders
- repeated rescans
- metadata probe caching
- timeline gap calculation
- playback and export resource contention

Concrete work:

- Add a fixture-driven benchmark for clip indexing.
- Add incremental rescan support keyed by file metadata.
- Separate playback-critical state from long-running scan state.
- Review whether `AVAsset` probing and export staging can share caches safely.

### 5. Tighten UX around onboarding, conflicts, and trust in the export

Focus areas:

- onboarding for first folder choice
- duplicate resolver clarity
- export preflight warnings
- current range understanding
- accessibility

Concrete work:

- Make the duplicate resolver tell the user exactly what changes between policies.
- Surface gap, partial-camera, and hidden-camera warnings earlier.
- Add better keyboard flows and VoiceOver labels in the native app.
- Make export history and log access more obvious after failure or cancel.

### 6. Package and release both surfaces intentionally

Focus areas:

- notarized mac app
- deterministic vendor asset checks
- CLI install and release artifacts
- license compliance

Concrete work:

- Add a native release lane that validates signing, entitlements, and bundled assets.
- Add a CLI packaging lane for PyPI or a managed artifact channel only if release scope needs it.
- Keep the app and CLI docs aligned whenever behavior changes.

## Prioritized Roadmap

### Phase 0: Domain contracts and fixtures

- Create a shared fixture set for:
  - classic 4-camera layouts
  - HW4 6-camera layouts
  - duplicate files
  - overlapping clips
  - sparse / malformed folder trees
- Use the same fixtures in Swift and Python tests.
- Add a machine-readable export manifest for dry-run comparison.

### Phase 1: Native app decomposition

- Split `AppState` into narrower feature stores.
- Split `ContentView` into onboarding, indexing, loaded, duplicate-resolution, and export-status surfaces.
- Keep the current behavior stable while reducing file size and cross-feature coupling.

### Phase 2: Export reliability

- Refactor `NativeExportController` into:
  - preflight
  - job setup
  - render loop
  - completion
  - failure handling
- Add structured log events instead of one large ad hoc log stream.
- Add explicit low-disk and bad-output-path tests.

### Phase 3: CLI parity and ergonomics

- Add `--dry-run-json`.
- Add fixture-backed parity tests against the Swift domain rules.
- Keep the CLI fast to install and easy to run on Linux and Windows.
- Do not let the CLI regain ownership of shipping mac export behavior.

### Phase 4: Release hardening

- Add native release preflight:
  - tests
  - signing
  - license asset presence
  - bundled ffmpeg asset checks
- Add one supported distribution story for the CLI.
- Add a concise release checklist shared by app and CLI docs.

## Testing Plan

### Keep

- Swift Testing coverage in `TeslaCamTests`
- UI smoke coverage in `TeslaCamUITests`
- Python unit tests under `tests/`
- Python integration test lane

### Add next

- Shared fixture parity tests between Swift and Python
- Native tests for export failure categories
- Native tests for duplicate resolver behavior
- Native performance tests for indexing and export preflight
- CLI tests for `--dry-run`, output conflict handling, and malformed input paths

## Performance Priorities

- Make large folder indexing scale predictably.
- Avoid repeated metadata probing for unchanged sources.
- Keep playback responsive during indexing and export setup.
- Measure memory growth during long exports.
- Avoid regressions in HW4 mixed-camera layouts.

## Security and Safety Priorities

- Keep security-scoped bookmark handling correct and minimal.
- Validate user-selected output paths before expensive work begins.
- Keep bundled third-party binaries and licenses auditable.
- Treat imported media trees as untrusted input and fail clearly on bad data.

## Design and UX Priorities

- Keep the app focused and utilitarian.
- Make the timeline and export consequences obvious.
- Explain gaps, partial sets, and duplicate policies in user language.
- Keep onboarding one step deep.
- Improve accessibility and keyboard support before adding decorative UI.

## Release and Operations

- Keep app and CLI docs aligned.
- Keep native export the only shipping mac path.
- Keep `_legacy/` out of active implementation work.
- Avoid release drift between code, runbook, and tests.

## Guardrails

- Do not reintroduce a CLI-only export assumption into the mac app.
- Do not let Swift and Python behavior diverge silently.
- Do not edit vendor license assets casually.
- Do not move active work into `_legacy/`.
- Do not add heavy Python dependencies unless there is a clear release need.

## Acceptance Signals

- The same fixture set produces the same duplicate counts and clip grouping in Swift and Python.
- `AppState.swift` and `ContentView.swift` are no longer the app's catch-all files.
- Native export failure states are structured, logged, and test-covered.
- UI tests still pass for onboarding and sample export flows.
- CLI dry runs and native preflight agree on the selected range and output behavior.

## Output Required At End

- A full zip containing the updated source code, this improvement plan, and all implementation changes.
