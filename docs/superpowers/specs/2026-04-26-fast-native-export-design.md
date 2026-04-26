# Fast Native Export — Full-Resolution Hardware-Accelerated Grid Composite

**Date:** 2026-04-26
**Branch:** `claude/friendly-banzai-e8dd1c`
**Status:** Approved for implementation
**Scope:** macOS native app export pipeline. CLI export is unaffected.

## Problem

The shipping macOS export path in `TeslaCam/NativeExportController.swift` is built around `AVAssetImageGenerator.image(at:)` — a thumbnail API — being called once per output frame, per camera. For a 6-camera HW4 grid at 30 fps, this is roughly 10,800 thumbnail-style decodes per minute of output, all serialized through a single thread that synchronously waits on a `DispatchSemaphore` per call. Each request triggers a fresh seek-and-decode rather than sequential frame reads, which is the dominant cost.

Compounding factors in the same code path:

- `image(for:seconds:)` retries up to three times per frame per camera with offset candidate times (`NativeExportController.swift:906-917`).
- Frame composition allocates a fresh `CVPixelBuffer` per frame (no pool) and draws into it via `CGContext` on the CPU in BGRA, then encodes — forcing YUV→RGB→YUV through the pipeline.
- The writer's append loop busy-waits with `Thread.sleep(forTimeInterval: 0.005)` instead of `requestMediaDataWhenReady`.

The user-visible effect is exports taking many minutes for footage the playback path can render in real time.

## Goals

- **Cut export wall-clock by ≥ 10×** on Apple Silicon. Concrete acceptance: 60 s of HW4 6-camera footage exports in under 30 s on M-series.
- **Zero downscaling.** Every camera tile renders at its source's natural pixel dimensions. Canvas equals the sum of per-tile max-natural sizes across cameras (existing rule, preserved).
- **Same deliverable.** Single grid-composited video file. No format change.
- **Same presets.** Max HEVC, Fast HEVC, ProRes-422-HQ. Bitrate and keyframe settings preserved unchanged from `Models.swift:154` (`nativeCompressionProperties`).
- **Same UX.** Cancel, retry, progress, log, history — all unchanged externally.

## Non-goals

- Changing the export deliverable.
- Restructuring `AppState` or `ContentView` (separate plan; see backlog).
- Adding new export presets.
- Touching the Python CLI export path.

## Approach

Replace the per-frame `AVAssetImageGenerator` loop with an `AVMutableComposition` + `AVAssetReaderVideoCompositionOutput` + `AVAssetWriter` pipeline. AVFoundation handles pipelined hardware decode → GPU composite → hardware encode end-to-end.

### Components

#### 1. `CompositionBuilder` (new internal type)

**Input:** `ExportRequest`.
**Output:** `(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, canvasSize: CGSize, frameRate: CMTimeScale)`.

One composition video track per enabled camera. For each `ClipSet` containing that camera, the source clip is inserted at its absolute-time offset within the trim window:

```
timelineOffset = max(.zero, set.date − trimStartDate)               // where to drop the clip in the camera track
headTrim       = max(.zero, trimStartDate − set.date)               // skipped from clip start
tailTrim       = max(.zero, set.endDate − trimEndDate)              // skipped from clip end
sourceStart    = headTrim
sourceDuration = max(.zero, set.duration − headTrim − tailTrim)
guard sourceDuration > .zero else { skip clip }                     // clip lies outside trim window
track.insertTimeRange(CMTimeRange(start: sourceStart, duration: sourceDuration),
                      of: srcAssetTrack, at: timelineOffset)
```

Gaps in coverage become natural gaps in the track — the compositor draws black, matching today's behavior.

The `AVMutableVideoComposition` has:

- `renderSize = canvasSize` (from existing `TimelineFrameLayout`).
- `frameDuration = CMTime(value: 1, timescale: 30)` (matches today's 30 fps output).
- One `AVMutableVideoCompositionInstruction` spanning the whole timeline.
- One `AVMutableVideoCompositionLayerInstruction` per track. Each layer instruction sets a transform composed of:
  1. The source's `preferredTransform` (defensively, in case Tesla ever emits non-identity orientation).
  2. A pure translation `CGAffineTransform(translationX: tileX + xCenterInset, y: tileY + yCenterInset)` placing the source pixels at the tile origin, centered if the source is smaller than the tile (where `xCenterInset = max(0, (tileSize.width − sourceNaturalSize.width) / 2)` and likewise for y).

  Composition: `final = preferredTransform.concatenating(placement)`. **The placement transform contains only translation — `a == 1`, `d == 1`, `b == 0`, `c == 0`.** The combined `final` may include orientation flips inherited from `preferredTransform`, but no scale is ever introduced by us.

#### 2. `RenderPipeline` (new internal type)

Configures and drives:

- `AVAssetReader` with `AVAssetReaderVideoCompositionOutput` fed the composition's video tracks and the `videoComposition`. Output settings request `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (biplanar YUV — encoder-native).
- `AVAssetWriter` with one `AVAssetWriterInput` for video, settings sourced from the existing `nativeCompressionProperties` for the chosen preset.

The writer input runs `requestMediaDataWhenReady(on:)` on a private serial dispatch queue. Inside the closure: pull `reader.copyNextSampleBuffer()`, append to the writer; on `nil`, mark input finished. This replaces the busy-wait at `NativeExportController.swift:993-996`.

#### 3. `NativeMovieWriter` (existing type, modified)

- Public surface unchanged: `init(outputURL:size:preset:)`, `start()`, `finish()`.
- `append(buffer:at:)` deleted. Append happens inside the `RenderPipeline` closure.
- Pixel format aligned with biplanar YUV. The `AVAssetWriterInputPixelBufferAdaptor` is removed.

#### 4. `NativeExportController` (existing type, modified)

`performExport(request:)` keeps:

- Preflight (with one new check — see "Hardware encoder ceiling" below).
- Output security scope handling.
- Log file lifecycle.
- Phase machine, cancel flag, retry flow, history publishing.

Body changes to:

```
build composition via CompositionBuilder
update phase = .renderingParts
start RenderPipeline; block until completion or cancel
update phase = .finishing → .completed
publish
```

**Deleted code (no replacement):**

- `TimelineFrameProvider`
- `TimelineFrameComposer`
- `ExportPreviewImageGeneratorBox`
- `ExportImageResultBox`
- `AssetVideoTrackLoader.presentationSize` (size already cached on `ClipSet.naturalSizes` by the indexer).

**Kept unchanged:**

- `TimelineFrameLayout` (canvas geometry, fixture-tested, correct for HW3, HW4, mixed).
- `TimelineFrameSizeProbe` (per-tile size selection).

### Resolution invariants

Testable contracts the new code must hold:

1. `videoComposition.renderSize == canvasSize` always.
2. `writerInput.outputSettings[AVVideoWidthKey] == canvasSize.width` and likewise for height.
3. The placement transform produced by `CompositionBuilder` (before composition with the source's `preferredTransform`) has `a == 1`, `d == 1`, `b == 0`, `c == 0` — translation only, no scale.
4. Tile size = `max(naturalSizes)` across enabled cameras (unchanged from today's `TimelineFrameSizeProbe`).
5. HW4 6-cam → 3×3 grid; HW3 4-cam → 2×2; mixed → 4×2 fallback (unchanged).

These are enforced by unit tests, not just review.

### Hardware encoder ceiling

Apple Silicon HEVC hardware encoder caps near 8192 in either dimension (commonly cited as 8192×4320). The user constraint forbids downscaling. Under an HEVC preset, if `canvasSize.width > 8192` or `canvasSize.height > 8192`, we emit a **blocking preflight error**:

> "Composite canvas {W}×{H} exceeds the hardware HEVC encoder ceiling (8192 px per side). Reduce enabled cameras or switch to ProRes preset."

ProRes-422-HQ has a much higher software-encoder ceiling and is the escape hatch for very large canvases.

### Concurrency and UI

- All AVFoundation work runs on a private serial dispatch queue.
- `@Published` updates dispatch to main via `DispatchQueue.main.async`. The `runOnMain` `CFRunLoopPerformBlock` shim at `NativeExportController.swift:572-580` is removed.
- Progress publishes throttle to 2 Hz, computed from `CMSampleBufferGetPresentationTimeStamp(currentBuffer) / totalCompositionDuration`.

### Failure handling

| Source                                | Maps to                             |
|---------------------------------------|-------------------------------------|
| Reader error or corrupt source clip   | `.encoding(...)` → `.partRender`    |
| Writer error                          | `.encoding(...)` → `.partRender`    |
| Disk full mid-write                   | `.outputWrite`                      |
| Cancel mid-stream                     | reader.cancelReading + writer.cancelWriting + delete partial output → `.cancelled` |
| Canvas exceeds HEVC ceiling           | Blocking preflight; no run started  |

## Testing

### Unit tests (new)

- `CompositionBuilder` produces the expected `renderSize` for HW3 4-cam, HW4 6-cam, mixed, single-camera, 5-camera (4×2 fallback).
- `CompositionBuilder` produces one track per entry of `enabledCameras`.
- The placement transform (the part `CompositionBuilder` adds, isolated from any source `preferredTransform`) is a pure translation. Asserted via `placement.a == 1 && placement.d == 1 && placement.b == 0 && placement.c == 0`.
- Trim-window math: source range and timeline offset for clips that (a) start before trim, (b) end after trim, (c) are fully inside trim, (d) do not intersect trim.
- Preflight blocks when `canvasSize.width > 8192` or `canvasSize.height > 8192` under HEVC presets and allows the same canvas under ProRes.

### Integration test (new)

- Generate a tiny synthetic 6-camera HW4 fixture (3 frames each, written via `AVAssetWriter` in `setUp` or checked into `fixtures/`).
- Run a full export end-to-end.
- Assert: output exists, dimensions equal the expected canvas, exit code 0, runtime under 5 s.

### Performance gate (new)

- A generated 60 s HW4 6-camera fixture exports in under 30 s on the macOS CI runner. Fails the build if regressed beyond a 20 % budget.

### Existing tests

- All current `TeslaCamTests` and `TeslaCamUITests` must continue to pass without modification. The export controller's public surface is unchanged.

## Phasing

Single phase. The change is contained to the export render path. No API changes ripple outward to `AppState`, `ContentView`, or the Python CLI.

## Risks and open questions

- **Memory at large canvases.** `AVAssetReaderVideoCompositionOutput` holds working buffers per source track. For HW4 mixed-resolution canvases near the ceiling, peak memory may exceed several GB. Mitigation: set `output.alwaysCopiesSampleData = false` and verify on the largest fixture.
- **ProRes file sizes** at 6K+ are heavy. The existing `estimatedRequiredDiskBytes` preflight covers this but the constants may need to be revisited if observed output-bitrate moves.
- **Color spaces.** Tesla footage is typically Rec.709 limited-range YUV. Pipeline keeps biplanar YUV end-to-end with no `CGColorSpace` round-trip. Verify the writer's `AVVideoColorPropertiesKey` matches source so no color shift is introduced; default-unset preserves source.

## Out-of-scope backlog

Noticed during analysis but deliberately excluded from this plan:

- `PreviewFrameCache.copyPreviewImage` (`MetalRenderer.swift:115-131`) uses the same `AVAssetImageGenerator` anti-pattern with a 1.0 s tolerance — playback frames can be ~1 s off-time. Should be replaced with `AVPlayerItemVideoOutput`-driven decode per camera.
- `MultiCamPlaybackController` is a 30 Hz `Timer` advancing a clock without a real decoder driving it — drifts under load.
- `AppState.swift` (39 KB) and `ContentView.swift` (45 KB) god-files. Already flagged in `improvement.md`.
- `appendStructuredLogEvent` opens and closes the log file per line; should batch.
- `verifyWriteAccess` and `beginOutputScope` may both call `startAccessingSecurityScopedResource` on the same URL without paired stops — scope-ref leak risk.
- BGRA32 pixel-format detour in the current writer — fixed incidentally by this plan; keeping the bullet honest.
