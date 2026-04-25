import Foundation
import Combine
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

final class AppState: ObservableObject {
  private enum StorageKey {
    static let lastSourceBookmarks = "TeslaCam.lastSourceBookmarks"
  }

  private enum DebugEnvironment {
    static let source = "TESLACAM_DEBUG_SOURCE"
    static let exportDirectory = "TESLACAM_DEBUG_EXPORT_DIR"
    static let uiTestMode = "TESLACAM_UI_TEST_MODE"
  }

  let debugLog = DebugLogSink()
  let playbackUI = PlaybackUIState()

  @Published var rootURL: URL?
  @Published var sourceURLs: [URL] = []
  @Published var clipSets: [ClipSet] = []
  @Published var isIndexing: Bool = false
  @Published var indexStatus: String = ""
  @Published var scanStage: ScanStage = .scanningNestedFolders
  @Published var scanDiscoveredClipCount: Int = 0
  @Published var minDate: Date?
  @Published var maxDate: Date?
  @Published var selectedStart: Date = Date()
  @Published var selectedEnd: Date = Date()
  @Published var trimStartSeconds: Double = 0
  @Published var trimEndSeconds: Double = 0
  @Published var isDraggingTrim: Bool = false
  @Published var currentIndex: Int = 0
  @Published var totalDuration: Double = 0
  @Published var timelineGapRanges: [TimelineGapRange] = []
  @Published var errorMessage: String = ""
  @Published var showError: Bool = false
  @Published var camerasDetected: [Camera] = []
  @Published var exportPreset: ExportPreset = .maxQualityHEVC
  @Published var duplicatePolicy: DuplicateClipPolicy = .mergeByTime
  @Published var selectedExportCameras: Set<Camera> = Set(Camera.allCases)
  @Published var healthSummary: ExportHealthSummary?
  @Published var layoutProfile: CameraLayoutProfile = .mixedUnknown
  @Published var duplicateSummary = DuplicateResolutionSummary(
    duplicateFileCount: 0,
    duplicateTimestampCount: 0,
    overlapMinuteCount: 0
  )
  @Published var isDuplicateResolverPresented: Bool = false
  @Published var duplicateResolverMessage: String = ""
  @Published var showDuplicateResolverForConflicts: Bool = false

  let playback = MultiCamPlaybackController()
  let exporter: NativeExportController

  private var timelineCoverage = TimelineCoverageMap(sets: [])
  private var observers: Set<AnyCancellable> = []
  private var currentSegmentStartSeconds: Double = 0
  private var currentSegmentClipIndex: Int?
  private var isUserSeeking = false
  private var wasPlayingBeforeSeek = false
  private var telemetryTimeline: TelemetryTimeline?
  private var telemetryURL: URL?
  private var activeSecurityScopedURLs: [URL] = []

  init() {
    exporter = NativeExportController()
    exporter.debugLog = debugLog
    exporter.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &observers)
    playback.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &observers)
  }

  var currentSeconds: Double {
    get { playbackUI.currentSeconds }
    set { playbackUI.currentSeconds = newValue }
  }

  var overlayText: String {
    get { playbackUI.overlayText }
    set { playbackUI.overlayText = newValue }
  }

  var telemetryText: String {
    get { playbackUI.telemetryText }
    set { playbackUI.telemetryText = newValue }
  }

  func onAppear() {
    configurePlaybackCallbacks()
    debug("launch")
    guard clipSets.isEmpty, sourceURLs.isEmpty, !isIndexing else { return }
#if DEBUG
    if applyDebugLaunchModeIfNeeded() {
      return
    }
#endif
  }

  private func configurePlaybackCallbacks() {
    playback.onTimeUpdate = { [weak self] seconds in
      self?.updateCurrentSeconds(localSeconds: seconds)
    }
    playback.onFinished = { [weak self] in
      self?.advanceToNextTimelineSegment()
    }
  }

  var previewTimelineState: PreviewTimelineState {
    PreviewTimelineState(
      currentGlobalSeconds: currentSeconds,
      activeClipSetIndex: currentIndex,
      playing: playback.isPlaying
    )
  }

  var currentGapRange: TimelineGapRange? {
    timelineGapRanges.first { $0.contains(currentSeconds) }
  }

  var trimSelection: TimelineTrimSelection {
    TimelineTrimSelection(
      startSeconds: trimStartSeconds,
      endSeconds: trimEndSeconds,
      isDragging: isDraggingTrim
    )
  }

  /// On iPad this is a no-op; the view layer uses SwiftUI `.fileImporter`.
  @Published var isFileImporterPresented: Bool = false
  /// On iPad, set when the user needs to pick an export destination.
  @Published var isFileExporterPresented: Bool = false
  /// iPad export scratch URL for sharing.
  @Published var pendingExportScratchURL: URL?

  func chooseFolder() {
    guard !exporter.isExporting else { return }
    #if os(macOS)
    PlatformFileAccess.activateApp()
    PlatformFileAccess.chooseFolder(
      directoryURL: sourceURLs.first?.deletingLastPathComponent() ?? rootURL
    ) { [weak self] urls in
      self?.indexSources(urls)
    }
    #else
    isFileImporterPresented = true
    #endif
  }

  func indexFolder(_ url: URL) {
    indexSources([url])
  }

  func indexSources(_ urls: [URL]) {
    guard !exporter.isExporting else { return }
    let normalizedSources = normalizeSources(urls)
    guard !normalizedSources.isEmpty else { return }
    debug("index start: \(normalizedSources.map { $0.lastPathComponent }.joined(separator: ", "))", category: "index")

    activateSecurityScopedAccess(for: normalizedSources)

    isIndexing = true
    indexStatus = "Scanning..."
    scanStage = .scanningNestedFolders
    scanDiscoveredClipCount = 0
    clipSets = []
    camerasDetected = []
    healthSummary = nil
    duplicateSummary = DuplicateResolutionSummary(
      duplicateFileCount: 0,
      duplicateTimestampCount: 0,
      overlapMinuteCount: 0
    )
    layoutProfile = .mixedUnknown
    isDuplicateResolverPresented = false
    duplicateResolverMessage = ""

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let index = try ClipIndexer.index(inputURLs: normalizedSources, duplicatePolicy: self.duplicatePolicy) { scanned in
          DispatchQueue.main.async {
            self.scanStage = .scanningNestedFolders
            self.scanDiscoveredClipCount = scanned
            self.indexStatus = "Found \(scanned) clips"
          }
        }
        DispatchQueue.main.async {
          self.scanStage = .parsingTimestamps
          self.rootURL = normalizedSources.first
          self.sourceURLs = normalizedSources
          self.clipSets = index.sets
          self.minDate = index.minDate
          self.maxDate = index.maxDate
          self.currentIndex = 0
          self.layoutProfile = index.layoutProfile
          self.camerasDetected = self.orderCameras(Array(index.camerasFound), profile: index.layoutProfile)
          self.selectedExportCameras = Set(self.camerasDetected)
          self.healthSummary = self.buildHealthSummary(from: index.sets)
          self.duplicateSummary = index.duplicateSummary
          self.rememberLastSources(normalizedSources)
          self.scanStage = .mergingClips
          self.rebuildTimeline()
          self.setTrimRange(
            startSeconds: 0,
            endSeconds: self.totalDuration,
            snapToMinute: true
          )
          self.currentSeconds = 0
          self.seekToGlobalTime(0, exact: true)
          self.scanStage = .preparingTimeline
          self.isIndexing = false
          self.indexStatus = "Ready"
          self.presentDuplicateResolverIfNeeded(for: index)
          self.debug(
            "index ready: sets=\(index.sets.count) cameras=\(self.camerasDetected.map { $0.rawValue }.joined(separator: ",")) profile=\(index.layoutProfile.rawValue) gaps=\(self.timelineGapRanges.count)",
            category: "index"
          )
        }
      } catch {
        DispatchQueue.main.async {
          self.isIndexing = false
          self.errorMessage = "No clips found in the selected files/folders."
          self.showError = true
          self.debug("index failed: \(error.localizedDescription)", category: "index")
        }
      }
    }
  }

  func reloadSources() {
    guard !sourceURLs.isEmpty else { return }
    indexSources(sourceURLs)
  }

  func chooseDuplicatePolicy(_ policy: DuplicateClipPolicy) {
    isDuplicateResolverPresented = false
    duplicateResolverMessage = ""
    guard duplicatePolicy != policy else { return }
    duplicatePolicy = policy
    reloadSources()
  }

  func dismissDuplicateResolver() {
    isDuplicateResolverPresented = false
    duplicateResolverMessage = ""
  }

  func updateDuplicatePolicy(_ policy: DuplicateClipPolicy) {
    chooseDuplicatePolicy(policy)
  }

  func togglePlay() {
    if playback.isPlaying {
      playback.pause()
    } else {
      playback.play()
    }
  }

  func restart() {
    guard !clipSets.isEmpty else { return }
    currentIndex = 0
    seekToGlobalTime(0, exact: true)
  }

  func normalizeRange() {
    setTrimRange(startSeconds: trimStartSeconds, endSeconds: trimEndSeconds)
  }

  func setFullRange() {
    setTrimRange(startSeconds: 0, endSeconds: totalDuration, snapToMinute: true)
  }

  func setCurrentMinuteRange() {
    guard totalDuration > 0 else { return }
    let start = floor(currentSeconds / 60.0) * 60.0
    let end = min(totalDuration, start + 60.0)
    setTrimRange(startSeconds: start, endSeconds: end, snapToMinute: true)
  }

  func setRecentRange(minutes: Int) {
    guard totalDuration > 0 else { return }
    let window = Double(minutes * 60)
    let end = totalDuration
    let start = max(0, end - window)
    setTrimRange(startSeconds: start, endSeconds: end, snapToMinute: true)
  }

  func setTestExportRange(minutes: Int = 3) {
    guard totalDuration > 0 else { return }
    let halfWindow = Double(minutes * 60) / 2
    let center = currentSeconds
    var start = max(0, center - halfWindow)
    var end = min(totalDuration, center + halfWindow)
    if end - start < Double(minutes * 60) {
      if start == 0 {
        end = min(totalDuration, Double(minutes * 60))
      } else if end == totalDuration {
        start = max(0, totalDuration - Double(minutes * 60))
      }
    }
    setTrimRange(startSeconds: start, endSeconds: end, snapToMinute: true)
  }

  func toggleExportCamera(_ camera: Camera, isEnabled: Bool) {
    if isEnabled {
      selectedExportCameras.insert(camera)
    } else {
      selectedExportCameras.remove(camera)
      if selectedExportCameras.isEmpty, let first = camerasDetected.first {
        selectedExportCameras.insert(first)
      }
    }
  }

  func exportRange() {
    guard !clipSets.isEmpty, !exporter.isExporting else { return }
    normalizeRange()
    debug("export open save panel: \(selectedRangeDescription)", category: "export")

#if DEBUG
    if let debugOutputURL = debugOutputURL() {
      if let request = makeExportRequest(for: debugOutputURL),
         exporter.preflightSummary(request: request).canExport {
        exportRange(to: debugOutputURL)
        return
      }
    }
#endif

    #if os(macOS)
    PlatformFileAccess.presentSavePanel(
      nameFieldStringValue: defaultExportFilename(),
      allowedContentTypes: PlatformFileAccess.contentTypes(for: exportPreset),
      directoryURL: rootURL?.deletingLastPathComponent() ?? sourceURLs.first?.deletingLastPathComponent()
    ) { [weak self] url in
      self?.exportRange(to: url)
    }
    #else
    // On iPad, export to app scratch space, then offer share.
    let scratchDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("teslacam_export", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    let outputURL = scratchDir.appendingPathComponent(defaultExportFilename())
    exportRange(to: outputURL)
    #endif
  }

  func cancelExport() {
    debug("export cancel requested", category: "export")
    exporter.cancelExport()
  }

  func revealLastExport() {
    #if os(macOS)
    exporter.revealOutput(for: exporter.exportHistory.first)
    #else
    if let url = exporter.exportHistory.first?.outputURL {
      PlatformFileAccess.shareFile(url)
    }
    #endif
  }

  func dismissExportStatus() {
    exporter.dismissStatus()
  }

  func beginTrimDrag() {
    isDraggingTrim = true
  }

  func updateTrimRange(startSeconds: Double, endSeconds: Double, snapToMinute: Bool = false) {
    setTrimRange(startSeconds: startSeconds, endSeconds: endSeconds, snapToMinute: snapToMinute)
  }

  func endTrimDrag(startSeconds: Double, endSeconds: Double) {
    isDraggingTrim = false
    setTrimRange(startSeconds: startSeconds, endSeconds: endSeconds, snapToMinute: true)
  }

  func updateTrimStart(from date: Date) {
    setTrimRange(
      startSeconds: globalSeconds(for: date),
      endSeconds: trimEndSeconds
    )
  }

  func updateTrimEnd(from date: Date) {
    setTrimRange(
      startSeconds: trimStartSeconds,
      endSeconds: globalSeconds(for: date)
    )
  }

  func beginSeek() {
    guard !isUserSeeking else { return }
    wasPlayingBeforeSeek = playback.isPlaying
    playback.pause()
    isUserSeeking = true
    debug("seek begin at \(String(format: "%.2f", currentSeconds))s", category: "seek")
  }

  func endSeek() {
    guard isUserSeeking else { return }
    isUserSeeking = false
    seekToGlobalTime(currentSeconds, exact: true)
    if wasPlayingBeforeSeek { playback.play() }
    debug("seek end at \(String(format: "%.2f", currentSeconds))s", category: "seek")
  }

  func liveSeek(to seconds: Double) {
    guard isUserSeeking else { return }
    seekToGlobalTime(seconds, exact: false)
  }

  func ingestDroppedURLs(_ urls: [URL]) {
    guard !exporter.isExporting else { return }
    debug("drop ingest: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", category: "index")
    indexSources(urls)
  }

  var sourceSummary: String {
    guard !sourceURLs.isEmpty else { return "" }
    if sourceURLs.count == 1 {
      return sourceURLs[0].path
    }
    return "\(sourceURLs.count) inputs • \(sourceURLs[0].lastPathComponent) + \(sourceURLs.count - 1) more"
  }

  var canReloadSources: Bool {
    !sourceURLs.isEmpty && !isIndexing && !exporter.isExporting
  }

  var canExport: Bool {
    !clipSets.isEmpty && !exporter.isExporting
  }

  var scanDateRangeSummary: String {
    guard let minDate, let maxDate else { return "Detecting date range" }
    return "\(formatShortDate(minDate)) – \(formatShortDate(maxDate))"
  }

  var scanDurationSummary: String {
    durationString(seconds: totalDuration)
  }

  var selectedSetsForExport: [ClipSet] {
    let startDate = trimStartDate
    let endDate = trimEndDate
    return clipSets.filter { set in
      set.endDate > startDate && set.date < endDate
    }
  }

  var totalMergedFileCount: Int {
    clipSets.reduce(0) { $0 + $1.files.count }
  }

  var duplicateSummaryText: String {
    var parts: [String] = []
    if duplicateSummary.duplicateFileCount > 0 {
      parts.append("\(duplicateSummary.duplicateFileCount) duplicate file\(duplicateSummary.duplicateFileCount == 1 ? "" : "s")")
    }
    if duplicateSummary.duplicateTimestampCount > 0 {
      parts.append("\(duplicateSummary.duplicateTimestampCount) timestamp collision\(duplicateSummary.duplicateTimestampCount == 1 ? "" : "s")")
    }
    if duplicateSummary.overlapMinuteCount > 0 {
      parts.append("\(duplicateSummary.overlapMinuteCount) overlap\(duplicateSummary.overlapMinuteCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: " • ")
  }

  var selectedRangeDescription: String {
    guard !clipSets.isEmpty else { return "No clips selected" }
    return "\(formatDateTime(trimStartDate))  ->  \(formatDateTime(trimEndDate))"
  }

  var partialSelectedSetCount: Int {
    let enabled = activeExportCameras
    guard !enabled.isEmpty else { return 0 }
    return selectedSetsForExport.reduce(into: 0) { result, set in
      let available = Set(set.files.keys).intersection(enabled)
      if available.count < enabled.count {
        result += 1
      }
    }
  }

  var trimStartDate: Date {
    date(forGlobalSeconds: trimStartSeconds)
  }

  var trimEndDate: Date {
    date(forGlobalSeconds: trimEndSeconds)
  }

  var selectedTrimDuration: Double {
    max(0, trimEndSeconds - trimStartSeconds)
  }

  var exportWarningsPreview: [String] {
    var warnings: [String] = []
    if partialSelectedSetCount > 0 {
      warnings.append("\(partialSelectedSetCount) selected clip span(s) are missing one or more enabled cameras and will use black placeholders.")
    }
    let hidden = camerasDetected.filter { !activeExportCameras.contains($0) }
    if !hidden.isEmpty {
      warnings.append("Hidden cameras will export as black tiles: \(hidden.map(\.displayName).joined(separator: ", ")).")
    }
    return warnings
  }

  var activeExportCameras: Set<Camera> {
    let detected = Set(camerasDetected)
    let filtered = selectedExportCameras.intersection(detected)
    if !filtered.isEmpty {
      return filtered
    }
    return detected.isEmpty ? Set(Camera.allCases) : detected
  }

  func shutdownForTermination() {
    playback.stop()
    exporter.cancelExport()
    deactivateSecurityScopedAccess()
  }

  private func updateCurrentSeconds(localSeconds: Double) {
    guard !isUserSeeking else { return }
    let local = max(0, localSeconds)
    let global = min(totalDuration, currentSegmentStartSeconds + local)
    currentSeconds = global
    updateOverlayAndTelemetry(globalSeconds: global, clipIndex: currentSegmentClipIndex, localSeconds: local)
  }

  private func rebuildTimeline() {
    guard !clipSets.isEmpty else {
      timelineCoverage = TimelineCoverageMap(sets: [])
      totalDuration = 0
      timelineGapRanges = []
      currentSegmentStartSeconds = 0
      currentSegmentClipIndex = nil
      return
    }

    timelineCoverage = TimelineCoverageMap(sets: clipSets)
    totalDuration = timelineCoverage.totalDuration
    timelineGapRanges = timelineCoverage.gapRanges(minimumDuration: 5)
    debug("timeline rebuilt: duration=\(Int(totalDuration)) gaps=\(timelineGapRanges.count)", category: "timeline")
    currentSegmentStartSeconds = 0
    currentSegmentClipIndex = clipSets.isEmpty ? nil : 0
  }

  func rebuildTimelineForTesting() {
    rebuildTimeline()
  }

  private func setTrimRange(startSeconds: Double, endSeconds: Double, snapToMinute: Bool = false) {
    guard !clipSets.isEmpty else { return }
    let upperBound = max(totalDuration, 1 / 30)
    let clampedStart = max(0, min(startSeconds, upperBound))
    let clampedEnd = max(clampedStart, min(endSeconds, upperBound))

    var normalizedStart = clampedStart
    var normalizedEnd = max(clampedEnd, normalizedStart + (1 / 30))

    if snapToMinute {
      normalizedStart = snappedTrimBoundary(clampedStart, roundsUp: false)
      normalizedEnd = snappedTrimBoundary(clampedEnd, roundsUp: true)
      normalizedEnd = max(normalizedEnd, normalizedStart + 1)
      normalizedEnd = min(normalizedEnd, upperBound)
      if normalizedEnd <= normalizedStart {
        normalizedEnd = min(upperBound, normalizedStart + 1)
      }
    }

    trimStartSeconds = normalizedStart
    trimEndSeconds = normalizedEnd
    selectedStart = trimStartDate
    selectedEnd = trimEndDate
  }

  private func snappedTrimBoundary(_ seconds: Double, roundsUp: Bool) -> Double {
    let minute = 60.0
    let clamped = max(0, min(seconds, totalDuration))
    let rounded = roundsUp
      ? ceil(clamped / minute) * minute
      : floor(clamped / minute) * minute
    return max(0, min(rounded, totalDuration))
  }

  private func date(forGlobalSeconds seconds: Double) -> Date {
    timelineCoverage.date(forGlobalSeconds: seconds) ?? Date()
  }

  private func globalSeconds(for date: Date) -> Double {
    timelineCoverage.globalSeconds(for: date)
  }

  private func clipStartOffset(at index: Int) -> Double {
    timelineCoverage.clipStartOffset(at: index)
  }

  private func activeClipIndex(at globalSeconds: Double) -> Int? {
    timelineCoverage.activeClipIndex(at: globalSeconds)
  }

  private func nearestClipIndex(to globalSeconds: Double) -> Int {
    timelineCoverage.nearestClipIndex(to: globalSeconds)
  }

  private func timelineSegment(at globalSeconds: Double) -> TimelinePlaybackSegment {
    timelineCoverage.playbackSegment(at: globalSeconds)
  }

  private func advanceToNextTimelineSegment() {
    guard totalDuration > 0 else { return }
    let epsilon = 1.0 / 30.0
    let nextStart = currentSegmentStartSeconds + playback.currentDuration + epsilon
    guard nextStart < totalDuration else {
      currentSeconds = totalDuration
      updateOverlayAndTelemetry(
        globalSeconds: totalDuration,
        clipIndex: currentSegmentClipIndex,
        localSeconds: playback.currentDuration
      )
      return
    }
    seekToGlobalTime(nextStart, exact: true, autoplay: true)
  }

  private func seekToGlobalTime(_ time: Double, exact: Bool = true, autoplay: Bool = false) {
    guard !clipSets.isEmpty else { return }
    let upperBound = max(0, totalDuration - (1.0 / 30.0))
    let clamped = max(0, min(time, upperBound))
    let segment = timelineSegment(at: clamped)
    let segmentChanged = !segment.matchesLoadedSegment(
      clipIndex: currentSegmentClipIndex,
      startSeconds: currentSegmentStartSeconds,
      duration: playback.currentDuration
    )
    currentSegmentStartSeconds = segment.startSeconds
    currentSegmentClipIndex = segment.clipIndex
    let local = max(0, min(clamped - segment.startSeconds, segment.duration))

    if segmentChanged {
      if let clipIndex = segment.clipIndex {
        currentIndex = clipIndex
        playback.load(set: clipSets[clipIndex], startSeconds: local)
        if !exact {
          debug("seek live clip \(clipIndex) local=\(String(format: "%.2f", local))", category: "seek")
        } else {
          debug("seek exact clip \(clipIndex) local=\(String(format: "%.2f", local))", category: "seek")
        }
        if exact {
          loadTelemetry(for: clipSets[clipIndex])
        } else {
          clearTelemetry()
        }
      } else {
        currentIndex = nearestClipIndex(to: clamped)
        playback.loadGap(duration: segment.duration, startSeconds: local)
        debug("seek \(exact ? "exact" : "live") gap start=\(String(format: "%.2f", segment.startSeconds)) duration=\(String(format: "%.2f", segment.duration))", category: "seek")
        clearTelemetry()
      }
    } else {
      if let clipIndex = segment.clipIndex {
        currentIndex = clipIndex
        if exact, telemetryURL != clipSets[clipIndex].file(for: .front) ?? clipSets[clipIndex].file(for: .back) ?? clipSets[clipIndex].files.values.first {
          loadTelemetry(for: clipSets[clipIndex])
        }
      } else {
        currentIndex = nearestClipIndex(to: clamped)
        if exact {
          clearTelemetry()
        }
      }
      playback.seek(to: local, exact: exact)
    }

    currentSeconds = clamped
    updateOverlayAndTelemetry(globalSeconds: clamped, clipIndex: segment.clipIndex, localSeconds: local)

    if autoplay {
      playback.play()
    }
  }

  private func clearTelemetry() {
    telemetryTimeline = nil
    telemetryURL = nil
    telemetryText = ""
  }

  private func loadTelemetry(for set: ClipSet?) {
    let url = set?.file(for: .front) ?? set?.file(for: .back) ?? set?.files.values.first
    telemetryTimeline = nil
    telemetryURL = url
    telemetryText = ""
    guard let fileURL = url else { return }
    debug("telemetry load \(fileURL.lastPathComponent)", category: "telemetry")
    DispatchQueue.global(qos: .utility).async {
      let timeline = try? TelemetryParser.parseTimeline(url: fileURL)
      DispatchQueue.main.async {
        guard self.telemetryURL == fileURL else { return }
        self.telemetryTimeline = timeline
        self.debug(
          timeline == nil ? "telemetry unavailable for \(fileURL.lastPathComponent)" : "telemetry ready for \(fileURL.lastPathComponent)",
          category: "telemetry"
        )
        let local = max(0, self.currentSeconds - self.currentSegmentStartSeconds)
        self.updateOverlayAndTelemetry(
          globalSeconds: self.currentSeconds,
          clipIndex: self.currentSegmentClipIndex,
          localSeconds: local
        )
      }
    }
  }

  private func updateOverlayAndTelemetry(globalSeconds: Double, clipIndex: Int?, localSeconds: Double) {
    overlayText = TeslaCamFormatters.fullDateTime.string(from: date(forGlobalSeconds: globalSeconds))
    guard clipIndex != nil, let timeline = telemetryTimeline else {
      telemetryText = ""
      return
    }
    let safeLocal = max(0, localSeconds)
    let frame = timeline.closest(to: safeLocal * 1000.0)
    telemetryText = formatTelemetry(frame?.sei)
  }

  private func expectedCoverageCameras(for set: ClipSet) -> Set<Camera> {
    let present = Set(set.files.keys)
    let containsClassicSides = !present.intersection([.left_repeater, .right_repeater]).isEmpty
    let containsSixCamMarkers = !present.intersection([.left, .right, .left_pillar, .right_pillar]).isEmpty

    if containsClassicSides && !containsSixCamMarkers {
      return Set(Camera.hw3ClassicOrder)
    }
    if containsSixCamMarkers && !containsClassicSides {
      return Set(Camera.hw4SixCamOrder)
    }
    if containsClassicSides && containsSixCamMarkers {
      return present
    }

    switch layoutProfile {
    case .hw3FourCam:
      return Set(Camera.hw3ClassicOrder)
    case .hw4SixCam:
      return Set(Camera.hw4SixCamOrder)
    case .mixedUnknown:
      return present
    }
  }

  private func formatTelemetry(_ sei: SeiMetadata?) -> String {
    guard let s = sei else { return "" }
    let speedKmh = Double(s.vehicleSpeedMps) * 3.6
    let speed = String(format: "%.1f km/h", speedKmh)
    let pedal = String(format: "%.0f%%", max(0, Double(s.acceleratorPedalPosition)))
    let steering = String(format: "%.0f°", Double(s.steeringWheelAngle))
    let gear: String
    switch s.gearState {
    case .park: gear = "P"
    case .drive: gear = "D"
    case .reverse: gear = "R"
    case .neutral: gear = "N"
    }
    let ap: String
    switch s.autopilotState {
    case .none: ap = "Off"
    case .selfDriving: ap = "FSD"
    case .autosteer: ap = "Autosteer"
    case .tacc: ap = "TACC"
    }
    return "Speed: \(speed)  Pedal: \(pedal)  Steer: \(steering)  Gear: \(gear)  AP: \(ap)  Brake: \(s.brakeApplied ? "On" : "Off")"
  }

  private func orderCameras(_ cams: [Camera], profile: CameraLayoutProfile) -> [Camera] {
    let ordered = profile.orderedCameras.filter { cams.contains($0) }
    let leftovers = cams.filter { !ordered.contains($0) }
    return ordered + leftovers
  }

  private func normalizeSources(_ urls: [URL]) -> [URL] {
    let fm = FileManager.default
    var seen = Set<String>()
    var out: [URL] = []
    out.reserveCapacity(urls.count)
    for raw in urls {
      let u = raw.standardizedFileURL
      guard fm.fileExists(atPath: u.path) else { continue }
      let key = u.path
      if seen.contains(key) { continue }
      seen.insert(key)
      out.append(u)
    }
    return out
  }

  private func rememberLastSources(_ urls: [URL]) {
    let bookmarks = urls.compactMap { url -> Data? in
      try? url.bookmarkData(
        options: PlatformFileAccess.bookmarkCreationOptions,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    }
    UserDefaults.standard.set(bookmarks, forKey: StorageKey.lastSourceBookmarks)
  }

  @discardableResult
  private func restoreLastSourcesIfPossible() -> Bool {
    guard let bookmarks = UserDefaults.standard.array(forKey: StorageKey.lastSourceBookmarks) as? [Data],
          !bookmarks.isEmpty else {
      return false
    }

    var restored: [URL] = []
    var refreshedBookmarks: [Data] = []
    for bookmark in bookmarks {
      var stale = false
      guard let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: PlatformFileAccess.bookmarkResolutionOptions,
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ) else {
        continue
      }
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      restored.append(url)
      if stale,
         let refreshed = try? url.bookmarkData(
          options: PlatformFileAccess.bookmarkCreationOptions,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
         ) {
        refreshedBookmarks.append(refreshed)
      } else {
        refreshedBookmarks.append(bookmark)
      }
    }

    guard !restored.isEmpty else { return false }
    if !refreshedBookmarks.isEmpty {
      UserDefaults.standard.set(refreshedBookmarks, forKey: StorageKey.lastSourceBookmarks)
    }
    indexSources(restored)
    return true
  }

  private func activateSecurityScopedAccess(for urls: [URL]) {
    deactivateSecurityScopedAccess()
    activeSecurityScopedURLs = urls.filter { url in
      url.startAccessingSecurityScopedResource()
    }
  }

  private func deactivateSecurityScopedAccess() {
    for url in activeSecurityScopedURLs {
      url.stopAccessingSecurityScopedResource()
    }
    activeSecurityScopedURLs.removeAll()
  }

  private func defaultExportFilename() -> String {
    guard !clipSets.isEmpty else {
      return "teslacam_\(exportPreset.outputLabel).\(exportPreset.defaultExtension)"
    }
    let suffix = "\(overlayFilenameStamp(trimStartDate))_to_\(overlayFilenameStamp(trimEndDate))"
    return "teslacam_\(suffix)_\(exportPreset.outputLabel).\(exportPreset.defaultExtension)"
  }

  private func exportRange(to chosenURL: URL) {
    guard let request = makeExportRequest(for: chosenURL) else {
      errorMessage = "No clips found in the selected range."
      showError = true
      return
    }
    let preflight = exporter.preflightSummary(request: request)
    if !preflight.canExport {
      errorMessage = preflight.blockingIssues.map(\.message).joined(separator: "\n")
      showError = true
      return
    }
    debug("export request: preset=\(request.preset.rawValue) cameras=\(request.enabledCameras.map { $0.rawValue }.sorted().joined(separator: ",")) duration=\(String(format: "%.2f", request.totalDuration))", category: "export")
    exporter.export(request: request)
  }

  private func debug(_ message: String, category: String = "app") {
    debugLog.record(message, category: category)
  }

  private func buildOutputURL(from chosenURL: URL) -> URL {
    var outputURL = chosenURL
    if (try? chosenURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      outputURL = firstAvailableOutputURL(in: chosenURL, preferredFilename: defaultExportFilename())
    }

    let expectedExtension = exportPreset.defaultExtension
    if outputURL.pathExtension.lowercased() != expectedExtension {
      outputURL.deletePathExtension()
      outputURL.appendPathExtension(expectedExtension)
    }
    return uniqueAvailableOutputURL(for: outputURL)
  }

  func resolvedExportURL(forTesting chosenURL: URL) -> URL {
    buildOutputURL(from: chosenURL)
  }

  private func firstAvailableOutputURL(in directory: URL, preferredFilename: String) -> URL {
    uniqueAvailableOutputURL(for: directory.appendingPathComponent(preferredFilename))
  }

  private func uniqueAvailableOutputURL(for preferredURL: URL) -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: preferredURL.path) else {
      return preferredURL
    }

    let directory = preferredURL.deletingLastPathComponent()
    let baseName = preferredURL.deletingPathExtension().lastPathComponent
    let pathExtension = preferredURL.pathExtension

    for suffix in 2...999 {
      var candidate = directory.appendingPathComponent("\(baseName)-\(suffix)")
      if !pathExtension.isEmpty {
        candidate.appendPathExtension(pathExtension)
      }
      if !fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    var fallback = directory.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(8))")
    if !pathExtension.isEmpty {
      fallback.appendPathExtension(pathExtension)
    }
    return fallback
  }

  private func makeExportRequest(for chosenURL: URL) -> ExportRequest? {
    let sets = selectedSetsForExport
    guard !sets.isEmpty else { return nil }
    let enabled = activeExportCameras
    let useExpandedGrid = enabled.count > 4 || sets.contains { set in
      !Set(set.files.keys).intersection([.left, .right, .left_pillar, .right_pillar]).isEmpty
    }
    return ExportRequest(
      sets: sets,
      outputURL: buildOutputURL(from: chosenURL),
      useSixCam: useExpandedGrid,
      preset: exportPreset,
      enabledCameras: enabled,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      trimStartDate: trimStartDate,
      trimEndDate: trimEndDate,
      selectedRangeText: selectedRangeDescription,
      partialClipCount: partialSelectedSetCount
    )
  }

  private func buildHealthSummary(from sets: [ClipSet]) -> ExportHealthSummary {
    var gapCount = 0
    var partialSetCount = 0
    var four = 0
    var six = 0
    var missingCameraCounts: [Camera: Int] = [:]

    for (index, set) in sets.enumerated() {
      let expected = expectedCoverageCameras(for: set)
      let present = Set(set.files.keys)

      if expected == Set(Camera.hw3ClassicOrder) {
        four += 1
      } else if expected == Set(Camera.hw4SixCamOrder) {
        six += 1
      }

      if !expected.isEmpty {
        let missing = expected.subtracting(present)
        if !missing.isEmpty {
          partialSetCount += 1
          for camera in missing {
            missingCameraCounts[camera, default: 0] += 1
          }
        }
      }

      if let next = sets[safe: index + 1] {
        let delta = next.date.timeIntervalSince(set.endDate)
        if delta > 1 {
          gapCount += 1
        }
      }
    }

    let timelineMinutes: Int
    if let minStart = sets.map(\.date).min(), let maxEnd = sets.map(\.endDate).max() {
      timelineMinutes = max(1, Int((maxEnd.timeIntervalSince(minStart) / 60).rounded(.up)))
    } else {
      timelineMinutes = max(1, Int((sets.reduce(0) { $0 + $1.duration } / 60).rounded(.up)))
    }

    return ExportHealthSummary(
      totalMinutes: timelineMinutes,
      gapCount: gapCount,
      partialSetCount: partialSetCount,
      fourCameraSetCount: four,
      sixCameraSetCount: six,
      missingCameraCounts: missingCameraCounts
    )
  }

  private func presentDuplicateResolverIfNeeded(for index: ClipIndex) {
    presentDuplicateResolverIfNeeded(summary: index.duplicateSummary)
  }

  private func presentDuplicateResolverIfNeeded(summary: DuplicateResolutionSummary) {
    guard summary.hasConflicts else { return }
    guard duplicatePolicy == .mergeByTime || showDuplicateResolverForConflicts else { return }
    var parts: [String] = []
    if summary.duplicateTimestampCount > 0 {
      parts.append("\(summary.duplicateTimestampCount) timestamp collision(s)")
    }
    if summary.overlapMinuteCount > 0 {
      parts.append("\(summary.overlapMinuteCount) overlap(s)")
    }
    duplicateResolverMessage = parts.joined(separator: " • ")
    isDuplicateResolverPresented = true
  }

  #if DEBUG
  func presentDuplicateResolverIfNeededForTesting(summary: DuplicateResolutionSummary) {
    presentDuplicateResolverIfNeeded(summary: summary)
  }
  #endif

  #if DEBUG
  private func applyDebugLaunchModeIfNeeded() -> Bool {
    let environment = ProcessInfo.processInfo.environment

    if let mode = environment[DebugEnvironment.uiTestMode]?.lowercased() {
      switch mode {
      case "blank":
        return true
      case "sample":
        loadSampleTimeline()
        return true
      default:
        break
      }
    }

    guard let raw = environment[DebugEnvironment.source], !raw.isEmpty else {
      return false
    }

    let urls = raw
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)) }
    guard !urls.isEmpty else { return false }
    indexSources(urls)
    return true
  }

  private func debugOutputURL() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    guard environment[DebugEnvironment.uiTestMode] != nil else {
      return nil
    }
    let fileManager = FileManager.default
    let fallbackDirectory = fileManager.temporaryDirectory

    if let raw = environment[DebugEnvironment.exportDirectory], !raw.isEmpty {
      let candidate = URL(fileURLWithPath: raw, isDirectory: true)
      if ensureWritableDirectory(candidate, fileManager: fileManager) {
        return firstAvailableOutputURL(in: candidate, preferredFilename: defaultExportFilename())
      }
    }

    return firstAvailableOutputURL(in: fallbackDirectory, preferredFilename: defaultExportFilename())
  }

  private func ensureWritableDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
      return false
    }
    let probeURL = directory.appendingPathComponent(".teslacam-ui-test-\(UUID().uuidString)")
    let created = fileManager.createFile(atPath: probeURL.path, contents: Data())
    if created {
      try? fileManager.removeItem(at: probeURL)
    }
    return created
  }
  #endif

  #if os(macOS)
  private func presentOpenPanel(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
    PlatformFileAccess.presentOpenPanel(panel, completion: completion)
  }

  private func presentSavePanel(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        completion(url)
      }
      return
    }

    if panel.runModal() == .OK, let url = panel.url {
      completion(url)
    }
  }
  #endif

  private func loadSampleTimeline() {
    let base = Date()
    let sampleSets = [
      ClipSet(timestamp: "sample_1", date: base, duration: 10, files: [:]),
      ClipSet(timestamp: "sample_2", date: base.addingTimeInterval(60), duration: 10, files: [:]),
      ClipSet(timestamp: "sample_3", date: base.addingTimeInterval(120), duration: 10, files: [:])
    ]
    sourceURLs = []
    clipSets = sampleSets
    minDate = sampleSets.first?.date
    maxDate = sampleSets.last?.endDate
    layoutProfile = .hw4SixCam
    camerasDetected = [.front, .back, .left, .right, .left_pillar, .right_pillar]
    selectedExportCameras = Set(camerasDetected)
    exportPreset = .fastHEVC
    currentIndex = 0
    overlayText = formatDateTime(base)
    rebuildTimeline()
    setTrimRange(startSeconds: 0, endSeconds: totalDuration, snapToMinute: true)
  }

  private func durationString(seconds: Double) -> String {
    let totalMinutes = max(0, Int((seconds / 60).rounded()))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
      return "\(minutes)m total"
    }
    return "\(hours)h \(minutes)m total"
  }

  private func overlayFilenameStamp(_ date: Date) -> String {
    TeslaCamFormatters.fullDateTime
      .string(from: date)
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: " ", with: "_")
  }
}
