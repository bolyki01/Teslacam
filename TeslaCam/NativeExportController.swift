import Foundation
import Combine
import AppKit
import AVFoundation
import CoreVideo
import CoreGraphics

final class NativeExportController: ObservableObject {
  @Published var log: String = ""
  @Published var lastError: String = ""
  @Published var currentJob: ExportJobSnapshot?
  @Published var exportHistory: [ExportJobSnapshot] = []
  @Published var isStatusPresented: Bool = false

  weak var debugLog: DebugLogSink?

  var isExporting: Bool {
    guard let currentJob else { return false }
    return !currentJob.isTerminal
  }

  private let fm = FileManager.default
  private var activeSession: MutableExportSession?
  private var cancelRequested = false
  private var activeOutputScopeURL: URL?
  private lazy var logFileURL: URL = {
    let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("TeslaCam", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("native-export.log")
  }()

  private enum ExportError: LocalizedError {
    case preparation(String)
    case encoding(String)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .preparation(let detail), .encoding(let detail):
        return detail
      case .cancelled:
        return "Export cancelled by user."
      }
    }
  }

  func preflightSummary(request: ExportRequest) -> ExportPreflightSummary {
    var blocking: [ExportIssue] = []
    var warnings: [ExportIssue] = []

    if request.sets.isEmpty {
      blocking.append(ExportIssue(message: "There are no clips in the selected export range.", isBlocking: true))
    }

    if request.totalDuration <= 0 {
      blocking.append(ExportIssue(message: "Selected trim range is empty.", isBlocking: true))
    }

    if request.partialClipCount > 0 {
      warnings.append(ExportIssue(message: "\(request.partialClipCount) selected clip span(s) are missing one or more cameras and will export with black placeholders.", isBlocking: false))
    }

    let visibleCameras = Set(request.sets.flatMap { $0.files.keys }).union(request.enabledCameras)
    let hiddenCameras = Camera.mixedOrder.filter { visibleCameras.contains($0) && !request.enabledCameras.contains($0) }
    if !hiddenCameras.isEmpty {
      warnings.append(ExportIssue(message: "Hidden cameras will export as black tiles: \(hiddenCameras.map(\.displayName).joined(separator: ", ")).", isBlocking: false))
    }

    let hasWriteAccess = verifyWriteAccess(to: request.outputURL)
    if !hasWriteAccess {
      blocking.append(ExportIssue(message: "The selected export location is not writable.", isBlocking: true))
    }

    return ExportPreflightSummary(
      blockingIssues: blocking,
      warnings: warnings,
      hasWriteAccess: hasWriteAccess,
      resolvedOutputURL: request.outputURL,
      requiresUserSavePanel: false
    )
  }

  func export(request: ExportRequest) {
    guard !isExporting else { return }
    beginOutputScope(for: request.outputURL)
    debug("start \(request.outputURL.lastPathComponent) preset=\(request.preset.rawValue)", category: "export")

    let preflight = preflightSummary(request: request)
    guard preflight.canExport else {
      lastError = preflight.blockingIssues.map(\.message).joined(separator: "\n")
      endOutputScope()
      return
    }

    let session = MutableExportSession(
      id: UUID(),
      request: request,
      phase: .preparing,
      progress: 0.02,
      phaseLabel: ExportJobPhase.preparing.displayName,
      startedAt: Date(),
      finishedAt: nil,
      outputURL: request.outputURL,
      logFileURL: logFileURL,
      tempRootURL: nil,
      failureCategory: nil,
      failureReason: nil,
      completedParts: 0,
      totalParts: request.totalParts,
      completedDuration: 0,
      totalDuration: request.totalDuration,
      isIndeterminate: false,
      isTerminal: false,
      canRevealOutput: false,
      canRevealWorkingFiles: false,
      canRetry: false,
      isCancelled: false
    )

    activeSession = session
    cancelRequested = false
    log = ""
    lastError = ""
    resetLogFile()
    appendLog("Log file: \(logFileURL.path)\n")
    appendLog("Export start: \(Date())\n")
    appendLog("Output: \(request.outputURL.path)\n")
    appendLog("Preset: \(request.preset.displayName)\n")
    appendLog("Range: \(request.selectedRangeText)\n")
    appendLog("Selected cameras: \(request.enabledCameras.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).joined(separator: ", "))\n")
    for warning in preflight.warnings {
      appendLog("Warning: \(warning.message)\n")
    }
    publishCurrentSession()
    isStatusPresented = true

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try self.performExport(request: request)
      } catch {
        self.runOnMain {
          self.finishFailure(error: error)
        }
      }
    }
  }

  func retry(_ snapshot: ExportJobSnapshot) {
    export(request: snapshot.request)
  }

  func dismissStatus() {
    isStatusPresented = false
    if currentJob?.isTerminal == true {
      currentJob = nil
      activeSession = nil
    }
  }

  func cancelExport() {
    cancelRequested = true
    appendLog("\nCancel requested.\n")
    debug("cancel requested", category: "export")
    updateSession {
      $0.phase = .cancelled
      $0.phaseLabel = "Cancelling export"
      $0.failureCategory = .cancelled
      $0.failureReason = "Export cancelled by user."
      $0.isCancelled = true
    }
  }

  func revealLog() {
    NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
  }

  func revealOutput(for snapshot: ExportJobSnapshot? = nil) {
    let url = (snapshot ?? currentJob)?.outputURL
    guard let url else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func revealWorkingFiles(for snapshot: ExportJobSnapshot? = nil) {
    guard let url = (snapshot ?? currentJob)?.workingDirectoryURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func performExport(request: ExportRequest) throws {
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("teslacam_export_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let logRoot = tempRoot.appendingPathComponent("logs", isDirectory: true)
    try fm.createDirectory(at: logRoot, withIntermediateDirectories: true)

    runOnMain {
      self.updateSession {
        $0.tempRootURL = tempRoot
        $0.canRevealWorkingFiles = true
        $0.phase = .preparing
        $0.phaseLabel = "Preparing clips"
        $0.progress = 0.05
        $0.isIndeterminate = false
      }
    }

    let frameProvider = TimelineFrameProvider(
      sets: request.sets,
      trimStartDate: request.trimStartDate,
      trimEndDate: request.trimEndDate
    )
    let layout = try TimelineFrameLayout.build(
      sets: request.sets,
      enabledCameras: request.enabledCameras,
      useSixCam: request.useSixCam
    )
    appendLog("Canvas: \(Int(layout.canvasSize.width))x\(Int(layout.canvasSize.height))\n")
    debug("layout cameras=\(layout.cameraOrder.map(\.rawValue).joined(separator: ",")) canvas=\(Int(layout.canvasSize.width))x\(Int(layout.canvasSize.height))", category: "export")

    let writer = try NativeMovieWriter(outputURL: request.outputURL, size: layout.canvasSize, preset: request.preset)
    try writer.start()

    runOnMain {
      self.updateSession {
        $0.phase = .renderingParts
        $0.phaseLabel = "Rendering timeline"
        $0.progress = 0.10
      }
    }

    let composer = TimelineFrameComposer(layout: layout, enabledCameras: request.enabledCameras)
    let fps: Double = 30
    let frameCount = max(1, Int((frameProvider.totalDuration * fps).rounded(.up)))

    for frameIndex in 0..<frameCount {
      if cancelRequested {
        throw ExportError.cancelled
      }

      let renderSeconds = Double(frameIndex) / fps
      let context = frameProvider.context(for: renderSeconds)

      if frameIndex == 0 || frameIndex % Int(max(1, fps / 2)) == 0 {
        let completedParts = min(
          request.totalParts,
          max(frameProvider.completedSetCount(at: renderSeconds), (context.clipIndex.map { $0 + 1 } ?? 0))
        )
        runOnMain {
          self.updateSession {
            $0.completedParts = completedParts
            $0.completedDuration = min(renderSeconds, request.totalDuration)
            $0.phase = .renderingParts
            $0.phaseLabel = "Rendering timeline"
            $0.progress = self.renderProgress(completed: renderSeconds, total: request.totalDuration)
          }
        }
      }

      let buffer = try composer.makeFrameBuffer(at: context.localSeconds, set: context.set)
      try writer.append(buffer: buffer, at: CMTime(seconds: renderSeconds, preferredTimescale: 600))
    }

    runOnMain {
      self.updateSession {
        $0.phase = .finishing
        $0.phaseLabel = "Finalizing movie"
        $0.completedParts = request.totalParts
        $0.completedDuration = request.totalDuration
        $0.progress = 0.98
      }
    }

    try writer.finishWriting()

    runOnMain {
      self.updateSession {
        $0.phase = .completed
        $0.phaseLabel = "Export complete"
        $0.progress = 1.0
        $0.finishedAt = Date()
        $0.completedParts = request.totalParts
        $0.completedDuration = request.totalDuration
        $0.isTerminal = true
        $0.canRevealOutput = true
        $0.canRetry = true
        $0.isIndeterminate = false
      }
      self.appendLog("\nDone: \(request.outputURL.path)\n")
      self.debug("completed \(request.outputURL.lastPathComponent)", category: "export")
      self.endOutputScope()
      self.publishCurrentSession()
      self.isStatusPresented = true
    }
  }

  private func finishFailure(error: Error) {
    let category: ExportFailureCategory
    if let exportError = error as? ExportError {
      switch exportError {
      case .preparation:
        category = .preparation
      case .encoding:
        category = .partRender
      case .cancelled:
        category = .cancelled
      }
    } else {
      category = .unknown
    }

    let message = error.localizedDescription
    if category == .cancelled {
      appendLog("Export cancelled: \(message)\n")
    } else {
      appendLog("Export failed: \(message)\n")
    }
    debug(category == .cancelled ? "cancelled \(message)" : "failed \(message)", category: "export")
    cleanupPartialOutput(at: activeSession?.outputURL)
    updateSession {
      $0.phase = category == .cancelled ? .cancelled : .failed
      $0.phaseLabel = category == .cancelled ? "Export cancelled" : "Export failed"
      $0.finishedAt = Date()
      $0.failureCategory = category
      $0.failureReason = message
      $0.isTerminal = true
      $0.canRetry = true
      $0.canRevealWorkingFiles = true
      $0.isIndeterminate = false
      $0.isCancelled = category == .cancelled
    }
    lastError = category == .cancelled ? "" : message
    endOutputScope()
    publishCurrentSession()
    isStatusPresented = true
  }

  private func updateSession(_ update: (inout MutableExportSession) -> Void) {
    guard var session = activeSession else { return }
    let previousPhase = session.phase
    update(&session)
    activeSession = session
    if session.phase != previousPhase {
      debug("phase \(previousPhase.rawValue) -> \(session.phase.rawValue)", category: "export")
    }
    publishCurrentSession()
  }

  private func publishCurrentSession() {
    guard let session = activeSession else {
      currentJob = nil
      return
    }
    let snapshot = session.snapshot(fileManager: fm)
    currentJob = snapshot
    if snapshot.isTerminal {
      exportHistory.removeAll { $0.id == snapshot.id }
      exportHistory.insert(snapshot, at: 0)
    }
  }

  private func beginOutputScope(for outputURL: URL) {
    endOutputScope()
    if outputURL.startAccessingSecurityScopedResource() {
      activeOutputScopeURL = outputURL
      return
    }
    let parent = outputURL.deletingLastPathComponent()
    if parent.startAccessingSecurityScopedResource() {
      activeOutputScopeURL = parent
    }
  }

  private func verifyWriteAccess(to outputURL: URL) -> Bool {
    let targetDirectory = outputURL.deletingLastPathComponent()
    guard fm.fileExists(atPath: targetDirectory.path) else { return false }

    let scopeURL: URL?
    if outputURL.startAccessingSecurityScopedResource() {
      scopeURL = outputURL
    } else if targetDirectory.startAccessingSecurityScopedResource() {
      scopeURL = targetDirectory
    } else {
      scopeURL = nil
    }

    defer {
      scopeURL?.stopAccessingSecurityScopedResource()
    }

    let probeURL = targetDirectory.appendingPathComponent(".teslacam-write-test-\(UUID().uuidString)")
    let created = fm.createFile(atPath: probeURL.path, contents: Data())
    if created {
      try? fm.removeItem(at: probeURL)
    }
    return created
  }

  private func endOutputScope() {
    activeOutputScopeURL?.stopAccessingSecurityScopedResource()
    activeOutputScopeURL = nil
  }

  private func appendLog(_ text: String) {
    let maxLen = 60000
    log.append(text)
    if log.count > maxLen {
      log = String(log.suffix(maxLen))
    }
    appendLogToFile(text)
  }

  private func resetLogFile() {
    if fm.fileExists(atPath: logFileURL.path) {
      try? fm.removeItem(at: logFileURL)
    }
    fm.createFile(atPath: logFileURL.path, contents: nil)
  }

  private func appendLogToFile(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logFileURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      fm.createFile(atPath: logFileURL.path, contents: data)
    }
  }

  private func renderProgress(completed: Double, total: Double) -> Double {
    guard total > 0 else { return 0.10 }
    let clamped = min(max(completed / total, 0), 1)
    return 0.10 + (0.80 * clamped)
  }

  private func cleanupPartialOutput(at url: URL?) {
    guard let url, fm.fileExists(atPath: url.path) else { return }
    try? fm.removeItem(at: url)
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      let runLoop = CFRunLoopGetMain()
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
      CFRunLoopWakeUp(runLoop)
    }
  }

  private func debug(_ message: String, category: String) {
    debugLog?.record(message, category: category)
  }
}

private struct TimelineFrameContext {
  let clipIndex: Int?
  let set: ClipSet?
  let localSeconds: Double
}

private struct TimelineFrameProvider {
  let sets: [ClipSet]
  let trimStartDate: Date
  let trimEndDate: Date
  let totalDuration: Double

  private let coverage: TimelineCoverageMap

  init(sets: [ClipSet], trimStartDate: Date, trimEndDate: Date) {
    self.sets = sets.sorted { lhs, rhs in
      if lhs.date == rhs.date {
        return lhs.timestamp < rhs.timestamp
      }
      return lhs.date < rhs.date
    }
    self.trimStartDate = trimStartDate
    self.trimEndDate = max(trimEndDate, trimStartDate.addingTimeInterval(1.0 / 30.0))
    self.totalDuration = max(1.0 / 30.0, self.trimEndDate.timeIntervalSince(trimStartDate))
    self.coverage = TimelineCoverageMap(sets: self.sets)
  }

  func context(for renderSeconds: Double) -> TimelineFrameContext {
    guard !sets.isEmpty else {
      return TimelineFrameContext(clipIndex: nil, set: nil, localSeconds: 0)
    }

    let clamped = max(0, min(renderSeconds, totalDuration))
    let renderDate = trimStartDate.addingTimeInterval(clamped)
    let coverageSeconds = coverage.globalSeconds(for: renderDate)

    if let activeIndex = coverage.activeClipIndex(at: coverageSeconds) {
      let set = sets[activeIndex]
      return TimelineFrameContext(
        clipIndex: activeIndex,
        set: set,
        localSeconds: max(0, renderDate.timeIntervalSince(set.date))
      )
    }

    return TimelineFrameContext(clipIndex: nil, set: nil, localSeconds: 0)
  }

  func completedSetCount(at renderSeconds: Double) -> Int {
    let clamped = max(0, min(renderSeconds, totalDuration))
    let renderDate = trimStartDate.addingTimeInterval(clamped)
    let coverageSeconds = coverage.globalSeconds(for: renderDate)
    return coverage.completedClipCount(at: coverageSeconds)
  }
}

private struct TimelineFrameLayout {
  let cameraOrder: [Camera]
  let canvasSize: CGSize
  let tileSize: CGSize
  let boundsByCamera: [Camera: CGRect]

  static func build(
    sets: [ClipSet],
    enabledCameras: Set<Camera>,
    useSixCam: Bool
  ) throws -> TimelineFrameLayout {
    let present = Set(sets.flatMap { $0.files.keys })
    let visible = present.union(enabledCameras)

    let hasClassicSides = !visible.intersection([.left_repeater, .right_repeater]).isEmpty
    let hasSixCamSides = !visible.intersection([.left, .right, .left_pillar, .right_pillar]).isEmpty

    let baseOrder: [Camera]
    if hasClassicSides && !hasSixCamSides {
      baseOrder = Camera.hw3ClassicOrder
    } else if hasSixCamSides && !hasClassicSides {
      baseOrder = Camera.hw4SixCamOrder
    } else if hasClassicSides || hasSixCamSides {
      baseOrder = Camera.mixedOrder
    } else {
      baseOrder = useSixCam ? Camera.hw4SixCamOrder : Camera.hw3ClassicOrder
    }

    var cameraOrder = baseOrder.filter { visible.contains($0) }
    if cameraOrder.isEmpty {
      cameraOrder = baseOrder
    }

    let probe = TimelineFrameSizeProbe(sets: sets)
    let tileSize = probe.tileSize(for: cameraOrder)

    if baseOrder == Camera.hw4SixCamOrder {
      let grid: [Camera: (row: Int, col: Int)] = [
        .front: (0, 1),
        .left: (1, 0),
        .back: (1, 1),
        .right: (1, 2),
        .left_pillar: (2, 0),
        .right_pillar: (2, 2)
      ]
      var bounds: [Camera: CGRect] = [:]
      for camera in cameraOrder {
        guard let position = grid[camera] else { continue }
        bounds[camera] = CGRect(
          x: CGFloat(position.col) * tileSize.width,
          y: CGFloat(2 - position.row) * tileSize.height,
          width: tileSize.width,
          height: tileSize.height
        )
      }
      return TimelineFrameLayout(
        cameraOrder: cameraOrder,
        canvasSize: CGSize(width: tileSize.width * 3, height: tileSize.height * 3),
        tileSize: tileSize,
        boundsByCamera: bounds
      )
    }

    let columns: Int
    switch cameraOrder.count {
    case 0...1:
      columns = 1
    case 2...4:
      columns = 2
    case 5...6:
      columns = 3
    default:
      columns = 4
    }
    let rows = max(1, Int(ceil(Double(max(cameraOrder.count, 1)) / Double(columns))))
    let canvasSize = CGSize(width: tileSize.width * CGFloat(columns), height: tileSize.height * CGFloat(rows))

    var bounds: [Camera: CGRect] = [:]
    for (index, camera) in cameraOrder.enumerated() {
      let col = index % columns
      let row = index / columns
      bounds[camera] = CGRect(
        x: CGFloat(col) * tileSize.width,
        y: CGFloat(rows - 1 - row) * tileSize.height,
        width: tileSize.width,
        height: tileSize.height
      )
    }

    return TimelineFrameLayout(
      cameraOrder: cameraOrder,
      canvasSize: canvasSize,
      tileSize: tileSize,
      boundsByCamera: bounds
    )
  }
}

private struct TimelineFrameSizeProbe {
  let sets: [ClipSet]

  func tileSize(for cameras: [Camera]) -> CGSize {
    var maxWidth: CGFloat = 1
    var maxHeight: CGFloat = 1
    var foundVideo = false

    for set in sets {
      for camera in cameras {
        if let naturalSize = set.naturalSize(for: camera), naturalSize.width > 0, naturalSize.height > 0 {
          maxWidth = max(maxWidth, naturalSize.width)
          maxHeight = max(maxHeight, naturalSize.height)
          foundVideo = true
          continue
        }

        guard let url = set.file(for: camera) else { continue }
        let asset = AVURLAsset(
          url: url,
          options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let size = AssetVideoTrackLoader.presentationSize(for: asset) else { continue }
        maxWidth = max(maxWidth, size.width)
        maxHeight = max(maxHeight, size.height)
        foundVideo = true
      }
    }

    if !foundVideo {
      return CGSize(width: 320, height: 240)
    }

    let fallbackWidth = max(maxWidth, 1280)
    let fallbackHeight = max(maxHeight, 960)
    return CGSize(width: fallbackWidth, height: fallbackHeight)
  }
}

private enum AssetVideoTrackLoader {
  static nonisolated func presentationSize(for asset: AVURLAsset) -> CGSize? {
    let semaphore = DispatchSemaphore(value: 0)
    var loadedSize: CGSize?

    Task.detached(priority: .userInitiated) {
      defer { semaphore.signal() }
      do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
          loadedSize = nil
          return
        }
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        let transformed = try await naturalSize.applying(preferredTransform)
        loadedSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
      } catch {
        loadedSize = nil
      }
    }

    semaphore.wait()
    return loadedSize
  }
}

private final class ExportImageResultBox: @unchecked Sendable {
  nonisolated(unsafe) var image: CGImage?
}

private actor ExportPreviewImageGeneratorBox {
  private let generator: AVAssetImageGenerator

  init(asset: AVAsset, tolerance: CMTime) {
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
  }

  func image(at time: CMTime) async -> CGImage? {
    try? await generator.image(at: time).image
  }
}

private final class TimelineFrameComposer {
  let layout: TimelineFrameLayout
  let enabledCameras: Set<Camera>
  private var generators: [URL: ExportPreviewImageGeneratorBox] = [:]
  private var lastImages: [URL: CGImage] = [:]

  init(layout: TimelineFrameLayout, enabledCameras: Set<Camera>) {
    self.layout = layout
    self.enabledCameras = enabledCameras
  }

  func makeFrameBuffer(at localSeconds: Double, set: ClipSet?) throws -> CVPixelBuffer {
    let width = Int(layout.canvasSize.width.rounded(.up))
    let height = Int(layout.canvasSize.height.rounded(.up))
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      throw NSError(domain: "TeslaCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate frame buffer."])
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
      throw NSError(domain: "TeslaCam", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to access frame buffer."])
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw NSError(domain: "TeslaCam", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create color space."])
    }
    guard let context = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
      throw NSError(domain: "TeslaCam", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create drawing context."])
    }

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: layout.canvasSize))

    guard let set else {
      return buffer
    }

    for camera in layout.cameraOrder {
      guard enabledCameras.contains(camera),
            let rect = layout.boundsByCamera[camera],
            let url = set.file(for: camera) else {
        continue
      }
      if let duration = set.duration(for: camera), localSeconds > duration + (1.0 / 30.0) {
        continue
      }
      guard let image = image(for: url, seconds: localSeconds) else { continue }
      let fitted = AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height), insideRect: rect)
      context.draw(image, in: fitted)
    }

    return buffer
  }

  private func image(for url: URL, seconds: Double) -> CGImage? {
    let generator = generators[url] ?? {
      let asset = AVURLAsset(url: url)
      // Tesla clips can fail exact-frame decode; allow nearest-frame lookup.
      let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
      let generator = ExportPreviewImageGeneratorBox(asset: asset, tolerance: tolerance)
      generators[url] = generator
      return generator
    }()

    let attempts: [Double] = [
      max(0, seconds),
      max(0, seconds - 0.10),
      max(0, seconds - 0.25)
    ]

    for candidate in attempts {
      if let image = waitForImage(from: generator, at: CMTime(seconds: candidate, preferredTimescale: 600)) {
        lastImages[url] = image
        return image
      }
    }

    return lastImages[url]
  }

  private func waitForImage(from generator: ExportPreviewImageGeneratorBox, at time: CMTime) -> CGImage? {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = ExportImageResultBox()
    Task.detached(priority: .userInitiated) {
      resultBox.image = await generator.image(at: time)
      semaphore.signal()
    }
    semaphore.wait()
    return resultBox.image
  }
}

private final class NativeMovieWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor

  init(outputURL: URL, size: CGSize, preset: ExportPreset) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    writer = try AVAssetWriter(outputURL: outputURL, fileType: preset.defaultExtension == "mov" ? .mov : .mp4)

    let codec: AVVideoCodecType
    let compression: [String: Any]
    switch preset {
    case .editFriendlyProRes:
      codec = .proRes422HQ
      compression = preset.nativeCompressionProperties(for: size)
    case .maxQualityHEVC:
      codec = .hevc
      compression = preset.nativeCompressionProperties(for: size)
    case .fastHEVC:
      codec = .hevc
      compression = preset.nativeCompressionProperties(for: size)
    }

    var settings: [String: Any] = [
      AVVideoCodecKey: codec.rawValue,
      AVVideoWidthKey: Int(size.width.rounded(.up)),
      AVVideoHeightKey: Int(size.height.rounded(.up))
    ]
    if !compression.isEmpty {
      settings[AVVideoCompressionPropertiesKey] = compression
    }

    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: Int(size.width.rounded(.up)),
        kCVPixelBufferHeightKey as String: Int(size.height.rounded(.up))
      ]
    )

    guard writer.canAdd(input) else {
      throw NSError(domain: "TeslaCam", code: 5, userInfo: [NSLocalizedDescriptionKey: "Writer cannot accept video input."])
    }
    writer.add(input)
  }

  func start() throws {
    guard writer.startWriting() else {
      throw NSError(domain: "TeslaCam", code: 6, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Failed to start writer."])
    }
    writer.startSession(atSourceTime: .zero)
  }

  func append(buffer: CVPixelBuffer, at time: CMTime) throws {
    while !input.isReadyForMoreMediaData {
      Thread.sleep(forTimeInterval: 0.005)
    }
    guard adaptor.append(buffer, withPresentationTime: time) else {
      throw NSError(domain: "TeslaCam", code: 7, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Failed to append frame."])
    }
  }

  func finishWriting() throws {
    input.markAsFinished()
    let group = DispatchGroup()
    group.enter()
    var finishError: Error?
    writer.finishWriting {
      finishError = self.writer.error
      group.leave()
    }
    group.wait()
    if let finishError {
      throw finishError
    }
  }
}
