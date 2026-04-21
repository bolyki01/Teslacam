import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject var state: AppState
  @State private var isDropTarget = false

  var body: some View {
    ZStack {
      TeslaCamSceneBackground()

      Group {
        if state.isIndexing {
          IndexingScreen(state: state)
        } else if state.clipSets.isEmpty {
          OnboardingScreen(state: state)
        } else {
          loadedScreen
        }
      }
      .disabled(state.exporter.isExporting)

      if let job = state.exporter.currentJob, state.exporter.isExporting || state.exporter.isStatusPresented {
        ExportOverlayCard(state: state, job: job)
      }
    }
    .frame(minWidth: 1100, minHeight: 760)
    .environment(\.colorScheme, .dark)
    .onAppear { state.onAppear() }
    .alert("Error", isPresented: $state.showError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(state.errorMessage)
    }
    .sheet(isPresented: $state.isDuplicateResolverPresented) {
      DuplicateResolverSheet(state: state)
    }
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleFileDrop(providers:))
  }

  private var loadedScreen: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        LoadedStatusBar(state: state)

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 12) {
            PreviewPanelCard(
              state: state,
              playbackUI: state.playbackUI,
              maxAvailableHeight: loadedPreviewMaxHeight(for: proxy.size.height)
            )

            TimelineExportCard(
              state: state,
              playbackUI: state.playbackUI,
              timelineMarkers: timelineMarkers,
              isSingleDayTimeline: isSingleDayTimeline
            )
          }
          .frame(maxWidth: loadedContentMaxWidth, alignment: .top)
          .padding(TeslaCamTheme.Metrics.contentPadding)
          .frame(maxWidth: .infinity, alignment: .top)
        }
      }
    }
    .accessibilityIdentifier("loaded-screen")
  }

  private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
    guard !state.exporter.isExporting else { return false }
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileProviders.isEmpty else { return false }

    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []

    for provider in fileProviders {
      group.enter()
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
        defer { group.leave() }
        guard let data,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              url.isFileURL else { return }
        lock.lock()
        urls.append(url)
        lock.unlock()
      }
    }

    group.notify(queue: .main) {
      guard !urls.isEmpty else { return }
      state.ingestDroppedURLs(urls)
    }
    return true
  }

  private var timelineMarkers: [Date] {
    guard let min = state.minDate, let max = state.maxDate else { return [] }
    let interval = max.timeIntervalSince(min)
    guard interval > 0 else { return [] }
    return [0.2, 0.4, 0.6, 0.8].map { fraction in
      min.addingTimeInterval(interval * fraction)
    }
  }

  private var isSingleDayTimeline: Bool {
    guard let min = state.minDate, let max = state.maxDate else { return true }
    return Calendar.current.isDate(min, inSameDayAs: max)
  }

  private var loadedContentMaxWidth: CGFloat {
    switch state.camerasDetected.count {
    case 0...4:
      return 820
    case 5...6:
      return 1080
    default:
      return 1320
    }
  }

  private func loadedPreviewMaxHeight(for totalHeight: CGFloat) -> CGFloat {
    let reserved: CGFloat = 430
    return max(320, totalHeight - reserved)
  }
}

private struct OnboardingScreen: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack {
      Spacer()

      VStack(spacing: TeslaCamTheme.Spacing.section) {
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surfaceElevated)
          .frame(width: 68, height: 68)
          .overlay(
            Image(systemName: "archivebox")
              .font(.system(size: 26, weight: .medium))
              .foregroundColor(TeslaCamTheme.Colors.textPrimary)
          )

        VStack(spacing: 12) {
          Text("Drop Tesla folder.\nGet timeline.")
            .font(TeslaCamTheme.Typography.heroTitle)
            .multilineTextAlignment(.center)
            .foregroundColor(TeslaCamTheme.Colors.textPrimary)

          Text("TeslaCam scans nested folders, keeps true clock time, shows real gaps, and exports one native timeline.")
            .font(TeslaCamTheme.Typography.panelSubtitle)
            .multilineTextAlignment(.center)
            .foregroundColor(TeslaCamTheme.Colors.textSecondary)
            .frame(maxWidth: 500)
        }

        Button("Choose Folder") { state.chooseFolder() }
          .buttonStyle(PrimaryButtonStyle(fixedWidth: 340))
          .disabled(state.exporter.isExporting)
          .accessibilityIdentifier("choose-folder")
      }

      Spacer()
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .accessibilityIdentifier("onboarding-screen")
  }
}

private struct IndexingScreen: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack {
      Spacer()

      VStack(spacing: TeslaCamTheme.Spacing.section) {
        VStack(spacing: 10) {
          Text("Building Your Timeline")
            .font(TeslaCamTheme.Typography.panelTitle)
            .foregroundColor(TeslaCamTheme.Colors.textPrimary)
          Text("Organizing clips automatically")
            .font(TeslaCamTheme.Typography.body)
            .foregroundColor(TeslaCamTheme.Colors.textTertiary)
        }

        ProgressView()
          .progressViewStyle(.linear)
          .tint(TeslaCamTheme.Colors.accent)
          .frame(width: TeslaCamTheme.Layout.narrowPanelWidth)

        VStack(alignment: .leading, spacing: 12) {
          ForEach(ScanStage.allCases) { stage in
            StageRow(
              title: stage.title,
              completed: stage.rawValue < state.scanStage.rawValue,
              active: stage == state.scanStage
            )
          }
        }
        .frame(width: TeslaCamTheme.Layout.narrowPanelWidth, alignment: .leading)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
          StatCard(title: "Sources", value: "\(max(1, state.sourceURLs.count))")
          StatCard(title: "Clips", value: "\(state.scanDiscoveredClipCount)")
          StatCard(title: "Date Range", value: state.scanDateRangeSummary)
          StatCard(
            title: "Duration",
            value: state.totalDuration > 0 ? state.scanDurationSummary : (state.indexStatus.isEmpty ? "Scanning" : state.indexStatus)
          )
        }
        .frame(width: TeslaCamTheme.Layout.narrowPanelWidth)

        VStack(alignment: .leading, spacing: 12) {
          Text("TIMELINE PREVIEW")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(TeslaCamTheme.Colors.textTertiary)

          RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
            .fill(TeslaCamTheme.Colors.surface)
            .frame(height: 44)
            .overlay(TimelinePreviewBars(active: true).padding(.horizontal, 18))
        }
        .frame(width: TeslaCamTheme.Layout.narrowPanelWidth)
      }

      Spacer()
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .accessibilityIdentifier("indexing-screen")
  }
}

private struct LoadedStatusBar: View {
  @ObservedObject var state: AppState

  var body: some View {
    ZStack {
      HStack {
        Button("Choose Folder") {
          state.chooseFolder()
        }
        .buttonStyle(QuickActionButtonStyle())
        .accessibilityIdentifier("choose-folder-loaded")

        Spacer()
      }

      Text("TeslaCam")
        .font(TeslaCamTheme.Typography.sectionTitle)
        .foregroundColor(TeslaCamTheme.Colors.textSecondary)
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .frame(height: TeslaCamTheme.Layout.toolbarHeight)
    .background(TeslaCamTheme.Colors.chromeBar)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(TeslaCamTheme.Colors.stroke)
        .frame(height: 1)
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.white.opacity(0.03))
        .frame(height: 1)
    }
  }
}

private struct PreviewPanelCard: View {
  @ObservedObject var state: AppState
  @ObservedObject var playbackUI: PlaybackUIState
  let maxAvailableHeight: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let height = previewHeight(for: proxy.size.width)

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surface)
          .overlay(
            MetalPlayerView(playback: state.playback, cameraOrder: state.camerasDetected)
              .clipShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous))
          )

        VStack(alignment: .leading, spacing: 6) {
          Text(overlayDate)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(TeslaCamTheme.Colors.textPrimary)
          Text(overlayTime)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(TeslaCamTheme.Colors.textSecondary)
        }
        .padding(14)
        .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: 12)
        .padding(16)

        HStack(spacing: 8) {
          ForEach(state.camerasDetected, id: \.self) { camera in
            Text(camera.displayName)
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(TeslaCamTheme.Colors.textSecondary)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topTrailing)

        if !playbackUI.telemetryText.isEmpty {
          Text(playbackUI.telemetryText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(TeslaCamTheme.Colors.textSecondary)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: 12)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }

        if state.currentGapRange != nil {
          Text("No recording in this span")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(TeslaCamTheme.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(width: proxy.size.width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 1)
      )
    }
    .frame(maxWidth: .infinity)
    .frame(height: maxAvailableHeight)
  }

  private var overlayDate: String {
    let parts = playbackUI.overlayText.split(separator: " ")
    if let first = parts.first {
      return String(first)
    }
    return "Loaded"
  }

  private var overlayTime: String {
    let parts = playbackUI.overlayText.split(separator: " ")
    if parts.count >= 2 {
      return String(parts[1])
    }
    return "00:00:00"
  }

  private var previewHeightFactor: CGFloat {
    switch state.camerasDetected.count {
    case 0...4:
      return 0.75
    case 5...6:
      return 0.66
    default:
      return 0.58
    }
  }

  private func previewHeight(for width: CGFloat) -> CGFloat {
    min(maxAvailableHeight, max(320, width * previewHeightFactor))
  }
}

private struct TimelineExportCard: View {
  @ObservedObject var state: AppState
  @ObservedObject var playbackUI: PlaybackUIState
  let timelineMarkers: [Date]
  let isSingleDayTimeline: Bool

  var body: some View {
    let minDate = state.minDate ?? Date()
    let maxDate = state.maxDate ?? Date()

    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        Text("Timeline")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(TeslaCamTheme.Colors.textSecondary)

        Spacer(minLength: 12)

        Button {
          state.togglePlay()
        } label: {
          Image(systemName: state.playback.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(IconButtonStyle(prominent: true))
        .accessibilityLabel(state.playback.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("toggle-playback")

        Text(playbackSummaryText)
          .font(TeslaCamTheme.Typography.monoDetail)
          .foregroundColor(TeslaCamTheme.Colors.textSecondary)

        Spacer()

        Text(trimRangeSummary)
          .font(TeslaCamTheme.Typography.monoDetail)
          .foregroundColor(TeslaCamTheme.Colors.textTertiary)
          .lineLimit(1)
      }

      TimelineSelectionTrack(
        currentSeconds: playbackSecondsBinding,
        selectedStartSeconds: $state.trimStartSeconds,
        selectedEndSeconds: $state.trimEndSeconds,
        gapRanges: state.timelineGapRanges,
        totalDuration: max(state.totalDuration, 1),
        onSeekStart: { state.beginSeek() },
        onSeekChange: { state.liveSeek(to: $0) },
        onSeekEnd: { state.endSeek() },
        onDragStart: { state.beginTrimDrag() },
        onDragChange: { start, end in state.updateTrimRange(startSeconds: start, endSeconds: end) },
        onDragEnd: { start, end in state.endTrimDrag(startSeconds: start, endSeconds: end) }
      )
      .frame(height: 76)

      HStack(spacing: 18) {
        Text(tickLabel(for: state.minDate))
        ForEach(timelineMarkers, id: \.self) { marker in
          Text(tickLabel(for: marker))
            .frame(maxWidth: .infinity)
        }
        Text(tickLabel(for: state.maxDate))
      }
      .font(TeslaCamTheme.Typography.monoDetail)
      .foregroundColor(TeslaCamTheme.Colors.textTertiary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ExportStatBadge(title: "Selected", value: formatHMS(state.selectedTrimDuration))
          ExportStatBadge(title: "Spans", value: "\(state.selectedSetsForExport.count)")
          ExportStatBadge(title: "Cameras", value: "\(state.activeExportCameras.count)/\(max(state.camerasDetected.count, 1))")
          ExportStatBadge(title: "Preset", value: state.exportPreset.displayName)
        }
      }

      HStack(alignment: .top, spacing: 12) {
        RangeControlCard(title: "From") {
          DatePicker(
            "",
            selection: Binding(
              get: { state.selectedStart },
              set: { state.updateTrimStart(from: $0) }
            ),
            in: minDate...maxDate,
            displayedComponents: [.date, .hourAndMinute]
          )
          .labelsHidden()
          .datePickerStyle(.field)
        }

        RangeControlCard(title: "Export Preset") {
          Picker("", selection: $state.exportPreset) {
            ForEach(ExportPreset.allCases) { preset in
              Text(preset.displayName).tag(preset)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }

        RangeControlCard(title: "To") {
          DatePicker(
            "",
            selection: Binding(
              get: { state.selectedEnd },
              set: { state.updateTrimEnd(from: $0) }
            ),
            in: minDate...maxDate,
            displayedComponents: [.date, .hourAndMinute]
          )
          .labelsHidden()
          .datePickerStyle(.field)
        }
      }
      .frame(minHeight: TeslaCamTheme.Metrics.controlHeight)

      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Quick Range")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(TeslaCamTheme.Colors.textTertiary)

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              Button("Whole Timeline") { state.setFullRange() }
                .buttonStyle(QuickActionButtonStyle())
              Button("Current Minute") { state.setCurrentMinuteRange() }
                .buttonStyle(QuickActionButtonStyle())
              Button("Last 5m") { state.setRecentRange(minutes: 5) }
                .buttonStyle(QuickActionButtonStyle())
              Button("Last 15m") { state.setRecentRange(minutes: 15) }
                .buttonStyle(QuickActionButtonStyle())
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: TeslaCamTheme.Metrics.controlHeight, alignment: .topLeading)
        .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)

        RangeControlCard(title: "Duplicate Handling") {
          Picker(
            "",
            selection: Binding(
              get: { state.duplicatePolicy },
              set: { state.updateDuplicatePolicy($0) }
            )
          ) {
            ForEach(DuplicateClipPolicy.allCases) { policy in
              Text(policy.displayName).tag(policy)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }

        ExportActionCard(state: state)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 8) {
          Text("Cameras")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(TeslaCamTheme.Colors.textTertiary)

          if state.camerasDetected.isEmpty {
            Text("No cameras detected yet")
              .font(.system(size: 11))
              .foregroundColor(TeslaCamTheme.Colors.textSecondary)
          }
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(state.camerasDetected, id: \.self) { camera in
              ExportCameraChip(
                title: camera.displayName,
                enabled: state.activeExportCameras.contains(camera)
              ) {
                let isEnabled = state.activeExportCameras.contains(camera)
                state.toggleExportCamera(camera, isEnabled: !isEnabled)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !state.duplicateSummaryText.isEmpty {
        ExportInfoBanner(
          title: "Duplicates",
          message: state.duplicateSummaryText,
          systemImage: "square.on.square"
        )
      }

      if let healthSummary = state.healthSummary {
        ExportInfoBanner(
          title: "Coverage",
          message: coverageSummary(for: healthSummary),
          systemImage: "waveform.path.ecg"
        )
      }

      ForEach(state.exportWarningsPreview, id: \.self) { warning in
        ExportInfoBanner(
          title: "Export warning",
          message: warning,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
    .padding(TeslaCamTheme.Metrics.cardPadding)
    .teslaCamCard()
  }

  private var playbackSecondsBinding: Binding<Double> {
    Binding(
      get: { playbackUI.currentSeconds },
      set: { playbackUI.currentSeconds = $0 }
    )
  }

  private var playbackSummaryText: String {
    "\(formatHMS(playbackUI.currentSeconds)) / \(formatHMS(state.totalDuration))"
  }

  private var trimRangeSummary: String {
    formattedTimelineDate(state.selectedStart) + " - " + formattedTimelineDate(state.selectedEnd)
  }

  private func tickLabel(for date: Date?) -> String {
    guard let date else { return "" }
    if isSingleDayTimeline {
      return TeslaCamFormatters.timelineSameDay.string(from: date)
    }
    let span = (state.maxDate ?? date).timeIntervalSince(state.minDate ?? date)
    if span <= 172_800 {
      return TeslaCamFormatters.timelineTwoDay.string(from: date)
    }
    return TeslaCamFormatters.timelineMultiDay.string(from: date)
  }

  private func formattedTimelineDate(_ date: Date) -> String {
    TeslaCamFormatters.selectedRange.string(from: date)
  }

  private func coverageSummary(for summary: ExportHealthSummary) -> String {
    var parts = [
      "\(summary.totalMinutes)m timeline",
      "\(summary.gapCount) gap\(summary.gapCount == 1 ? "" : "s")",
      "\(summary.partialSetCount) partial span\(summary.partialSetCount == 1 ? "" : "s")"
    ]

    if summary.hasMixedCoverage {
      parts.append("mixed 4- and 6-camera coverage")
    }

    if !summary.missingCoverageSummary.isEmpty {
      parts.append(summary.missingCoverageSummary)
    }

    return parts.joined(separator: " • ")
  }
}

private struct ExportStatBadge: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textTertiary)
      Text(value)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: 12)
  }
}

private struct ExportActionCard: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Export")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textTertiary)

      Text(state.selectedRangeDescription)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(TeslaCamTheme.Colors.textSecondary)
        .lineLimit(2)

      Button("Export Video") { state.exportRange() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(state.clipSets.isEmpty || state.exporter.isExporting)
        .accessibilityLabel("Export Video")
        .accessibilityIdentifier("export-video")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(minHeight: TeslaCamTheme.Metrics.controlHeight, alignment: .topLeading)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)
  }
}

private struct ExportCameraChip: View {
  let title: String
  let enabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 12, weight: .semibold))
        Text(title)
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundColor(enabled ? TeslaCamTheme.Colors.textPrimary : TeslaCamTheme.Colors.textSecondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(enabled ? TeslaCamTheme.Colors.surfaceElevated : TeslaCamTheme.Colors.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .stroke(enabled ? TeslaCamTheme.Colors.accent.opacity(0.7) : TeslaCamTheme.Colors.stroke, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(enabled ? "Included" : "Excluded")
  }
}

private struct ExportInfoBanner: View {
  let title: String
  let message: String
  let systemImage: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textSecondary)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(TeslaCamTheme.Colors.textTertiary)
        Text(message)
          .font(.system(size: 12))
          .foregroundColor(TeslaCamTheme.Colors.textSecondary)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: 12)
  }
}

private struct RangeControlCard<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textTertiary)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: TeslaCamTheme.Metrics.controlHeight, alignment: .leading)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)
  }
}

private struct ExportOverlayCard: View {
  @ObservedObject var state: AppState
  let job: ExportJobSnapshot

  var body: some View {
    ZStack {
      TeslaCamTheme.Colors.overlayScrim
        .ignoresSafeArea()

      VStack(spacing: 22) {
        Text(title)
          .font(TeslaCamTheme.Typography.panelTitle)
          .foregroundColor(TeslaCamTheme.Colors.textPrimary)
          .accessibilityIdentifier("export-overlay-title")

        Text(job.phaseLabel)
          .font(TeslaCamTheme.Typography.panelSubtitle.weight(.medium))
          .foregroundColor(TeslaCamTheme.Colors.textSecondary)

        ProgressView(value: max(0, min(job.progress, 1)))
          .tint(TeslaCamTheme.Colors.accent)
          .scaleEffect(x: 1, y: 2.6, anchor: .center)
          .frame(maxWidth: TeslaCamTheme.Layout.overlayContentWidth)
          .opacity(job.isTerminal ? 0.75 : 1)

        HStack {
          Text(detail)
            .font(TeslaCamTheme.Typography.body)
            .foregroundColor(TeslaCamTheme.Colors.textSecondary)
            .lineLimit(2)

          Spacer()

          Text(job.progressPercentText)
            .font(TeslaCamTheme.Typography.numericBody)
            .foregroundColor(TeslaCamTheme.Colors.textPrimary)
        }
        .frame(maxWidth: TeslaCamTheme.Layout.overlayContentWidth)

        if job.isTerminal {
          VStack(spacing: 10) {
            if job.phase == .completed {
              Button("Reveal File") {
                state.exporter.revealOutput(for: job)
              }
              .buttonStyle(PrimaryButtonStyle(fixedWidth: 220))
              .accessibilityLabel("Reveal File")
            } else {
              Button("Show Log") {
                state.exporter.revealLog()
              }
              .buttonStyle(PrimaryButtonStyle(fixedWidth: 220))
              .accessibilityLabel("Show Log")
            }

            Button("Done") {
              state.dismissExportStatus()
            }
            .buttonStyle(QuickActionButtonStyle())
            .accessibilityLabel("Done")
            .accessibilityIdentifier("dismiss-export-status")
          }
        } else {
          Button("Cancel Export") {
            state.cancelExport()
          }
          .buttonStyle(PrimaryButtonStyle(fixedWidth: 220))
          .accessibilityLabel("Cancel Export")
        }
      }
      .padding(32)
      .frame(maxWidth: TeslaCamTheme.Layout.overlayCardWidth)
      .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: 22)
      .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    }
    .allowsHitTesting(true)
    .accessibilityIdentifier("export-overlay")
    .zIndex(20)
  }

  private var title: String {
    switch job.phase {
    case .completed:
      return "Export Complete"
    case .failed:
      return "Export Failed"
    case .cancelled:
      return "Export Cancelled"
    default:
      return "Exporting Video"
    }
  }

  private var detail: String {
    if let reason = job.failureReason, job.isTerminal {
      return reason
    }
    return job.detailText
  }
}

private struct DuplicateResolverSheet: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.l) {
      Text("Resolve Duplicates")
        .font(TeslaCamTheme.Typography.panelTitle)
        .foregroundColor(TeslaCamTheme.Colors.textPrimary)

      Text(state.duplicateResolverMessage.isEmpty ? "Multiple clips share the same timeline position." : state.duplicateResolverMessage)
        .font(TeslaCamTheme.Typography.body)
        .foregroundColor(TeslaCamTheme.Colors.textSecondary)

      VStack(alignment: .leading, spacing: 10) {
        duplicateChoiceButton("Merge by Time", subtitle: "Keep one ordered timeline and merge matching timestamps.") {
          state.chooseDuplicatePolicy(.mergeByTime)
        }
        duplicateChoiceButton("Keep All", subtitle: "Preserve every duplicate as separate timeline entries.") {
          state.chooseDuplicatePolicy(.keepAll)
        }
        duplicateChoiceButton("Prefer Newest", subtitle: "Use the newest file when timestamps collide.") {
          state.chooseDuplicatePolicy(.preferNewest)
        }
      }

      HStack {
        Spacer()
        Button("Keep Current") {
          state.dismissDuplicateResolver()
        }
        .buttonStyle(QuickActionButtonStyle())
        .accessibilityLabel("Keep Current")
        .accessibilityIdentifier("duplicate-keep-current")
      }
    }
    .padding(TeslaCamTheme.Spacing.xl)
    .frame(width: TeslaCamTheme.Layout.duplicateSheetWidth)
    .background(TeslaCamSceneBackground())
  }

  private func duplicateChoiceButton(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(TeslaCamTheme.Colors.textPrimary)
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundColor(TeslaCamTheme.Colors.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: 12)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityIdentifier("duplicate-choice-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
  }
}

private struct StatCard: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textTertiary)
      Text(value)
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .teslaCamCard()
  }
}

private struct StageRow: View {
  let title: String
  let completed: Bool
  let active: Bool

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(active ? TeslaCamTheme.Colors.accent : Color.white.opacity(0.2))
        .frame(width: 5, height: 5)

      Text(title)
        .font(.system(size: 14, weight: active ? .semibold : .regular))
        .foregroundColor(completed || active ? TeslaCamTheme.Colors.textPrimary : TeslaCamTheme.Colors.textTertiary)

      Spacer()

      if completed {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(TeslaCamTheme.Colors.textTertiary)
      } else if active {
        Text("...")
          .font(.system(size: 14, weight: .bold, design: .monospaced))
          .foregroundColor(TeslaCamTheme.Colors.accent)
      }
    }
  }
}

private struct TimelinePreviewBars: View {
  let active: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(0..<48, id: \.self) { index in
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(TeslaCamTheme.Colors.accent.opacity(active ? 0.95 : 0.5))
          .frame(width: 4, height: CGFloat(12 + ((index * 7) % 18)))
      }
    }
  }
}

private struct TimelineSelectionTrack: View {
  @Binding var currentSeconds: Double
  @Binding var selectedStartSeconds: Double
  @Binding var selectedEndSeconds: Double
  let gapRanges: [TimelineGapRange]
  let totalDuration: Double
  let onSeekStart: () -> Void
  let onSeekChange: (Double) -> Void
  let onSeekEnd: () -> Void
  let onDragStart: () -> Void
  let onDragChange: (Double, Double) -> Void
  let onDragEnd: (Double, Double) -> Void

  @State private var dragAnchor: DragAnchor?
  @State private var isSeeking = false

  var body: some View {
    GeometryReader { proxy in
      let fullWidth = proxy.size.width
      let safeDuration = max(totalDuration, 1)
      let laneHeight: CGFloat = 42
      let laneY: CGFloat = 10
      let trackInset: CGFloat = 14
      let trackWidth = max(fullWidth - (trackInset * 2), 1)
      let startX = trackInset + trackWidth * CGFloat(max(0, min(1, selectedStartSeconds / safeDuration)))
      let endX = trackInset + trackWidth * CGFloat(max(0, min(1, selectedEndSeconds / safeDuration)))
      let playheadX = trackInset + trackWidth * CGFloat(max(0, min(1, currentSeconds / safeDuration)))
      let selectionWidth = max(endX - startX, 8)

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(TeslaCamTheme.Colors.surface)
          .frame(width: trackWidth, height: laneHeight)
          .offset(x: trackInset, y: laneY)
          .contentShape(Rectangle())
          .gesture(backgroundSeekGesture(originX: trackInset, width: trackWidth))

        ForEach(Array(gapRanges.enumerated()), id: \.offset) { _, gap in
          let gapStartX = trackInset + trackWidth * CGFloat(max(0, min(1, gap.startSeconds / safeDuration)))
          let gapEndX = trackInset + trackWidth * CGFloat(max(0, min(1, gap.endSeconds / safeDuration)))
          let gapWidth = max(gapEndX - gapStartX, 2)

          TimelineGapBand(showLabel: gap.duration > max(600, safeDuration * 0.12))
            .frame(width: gapWidth, height: laneHeight)
            .offset(x: gapStartX, y: laneY)
            .allowsHitTesting(false)
        }

        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(TeslaCamTheme.Colors.accentSoft)
          .frame(width: selectionWidth, height: laneHeight)
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(TeslaCamTheme.Colors.accent, lineWidth: 1.2)
          )
          .offset(x: startX, y: laneY)
          .contentShape(Rectangle())
          .gesture(selectionDrag(width: trackWidth))

        handle
          .offset(x: clampedHandleX(centerX: startX, trackInset: trackInset, trackWidth: trackWidth), y: laneY - 1)
          .contentShape(Rectangle())
          .gesture(handleDrag(kind: .start, originX: trackInset, width: trackWidth))

        handle
          .offset(x: clampedHandleX(centerX: endX, trackInset: trackInset, trackWidth: trackWidth), y: laneY - 1)
          .contentShape(Rectangle())
          .gesture(handleDrag(kind: .end, originX: trackInset, width: trackWidth))

        playhead
          .offset(x: clampedPlayheadX(centerX: playheadX, trackInset: trackInset, trackWidth: trackWidth), y: laneY - 1)
          .contentShape(Rectangle())
          .gesture(playheadSeekGesture(originX: trackInset, width: trackWidth))
      }
    }
    .accessibilityIdentifier("merged-timeline-track")
  }

  private var handle: some View {
    ZStack {
      Color.clear.frame(width: 28, height: 44)
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(TeslaCamTheme.Colors.controlKnob)
        .frame(width: 12, height: 30)
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(TeslaCamTheme.Colors.controlKnobStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
    }
  }

  private var playhead: some View {
    ZStack(alignment: .center) {
      Color.clear.frame(width: 22, height: 46)
      Capsule(style: .continuous)
        .fill(TeslaCamTheme.Colors.controlKnob.opacity(0.92))
        .frame(width: 2, height: 32)
      Circle()
        .fill(TeslaCamTheme.Colors.accent)
        .frame(width: 10, height: 10)
        .offset(y: 16)
        .overlay(
          Circle()
            .stroke(Color.white.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }
  }

  private func clampedHandleX(centerX: CGFloat, trackInset: CGFloat, trackWidth: CGFloat) -> CGFloat {
    max(trackInset, min(trackInset + trackWidth - 28, centerX - 14))
  }

  private func clampedPlayheadX(centerX: CGFloat, trackInset: CGFloat, trackWidth: CGFloat) -> CGFloat {
    max(trackInset, min(trackInset + trackWidth - 22, centerX - 11))
  }

  private func seconds(forX x: CGFloat, originX: CGFloat, width: CGFloat) -> Double {
    let clamped = max(0, min(width, x - originX))
    let fraction = Double(max(0, min(1, clamped / max(width, 1))))
    return totalDuration * fraction
  }

  private func updateSeek(from x: CGFloat, originX: CGFloat, width: CGFloat) {
    let seconds = seconds(forX: x, originX: originX, width: width)
    currentSeconds = seconds
    onSeekChange(seconds)
  }

  private func backgroundSeekGesture(originX: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard dragAnchor == nil else { return }
        if !isSeeking {
          isSeeking = true
          onSeekStart()
        }
        updateSeek(from: value.location.x, originX: originX, width: width)
      }
      .onEnded { value in
        guard isSeeking else { return }
        updateSeek(from: value.location.x, originX: originX, width: width)
        onSeekEnd()
        isSeeking = false
      }
  }

  private func playheadSeekGesture(originX: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !isSeeking {
          isSeeking = true
          onSeekStart()
        }
        updateSeek(from: value.location.x, originX: originX, width: width)
      }
      .onEnded { value in
        updateSeek(from: value.location.x, originX: originX, width: width)
        onSeekEnd()
        isSeeking = false
      }
  }

  private func handleDrag(kind: HandleKind, originX: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard !isSeeking else { return }
        if dragAnchor == nil {
          dragAnchor = DragAnchor(kind: kind, startSeconds: selectedStartSeconds, endSeconds: selectedEndSeconds)
          onDragStart()
        }
        var start = selectedStartSeconds
        var end = selectedEndSeconds
        let grabbed = seconds(forX: value.location.x, originX: originX, width: width)
        switch kind {
        case .start:
          start = min(grabbed, selectedEndSeconds)
        case .end:
          end = max(grabbed, selectedStartSeconds)
        case .selection:
          break
        }
        onDragChange(start, end)
      }
      .onEnded { _ in
        onDragEnd(selectedStartSeconds, selectedEndSeconds)
        dragAnchor = nil
      }
  }

  private func selectionDrag(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard !isSeeking else { return }
        if dragAnchor == nil {
          dragAnchor = DragAnchor(kind: .selection, startSeconds: selectedStartSeconds, endSeconds: selectedEndSeconds)
          onDragStart()
        }
        guard let dragAnchor else { return }
        let delta = Double(value.translation.width / max(width, 1)) * totalDuration
        let range = dragAnchor.endSeconds - dragAnchor.startSeconds
        var start = dragAnchor.startSeconds + delta
        start = max(0, min(start, totalDuration - range))
        let end = min(totalDuration, start + range)
        onDragChange(start, end)
      }
      .onEnded { _ in
        onDragEnd(selectedStartSeconds, selectedEndSeconds)
        dragAnchor = nil
      }
  }

  private enum HandleKind {
    case start
    case end
    case selection
  }

  private struct DragAnchor {
    let kind: HandleKind
    let startSeconds: Double
    let endSeconds: Double
  }
}

private struct TimelineGapBand: View {
  let showLabel: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(TeslaCamTheme.Colors.gapFill)

      Canvas { context, size in
        var path = Path()
        var x: CGFloat = -size.height
        while x < size.width {
          path.move(to: CGPoint(x: x, y: size.height))
          path.addLine(to: CGPoint(x: x + size.height, y: 0))
          x += 12
        }
        context.stroke(path, with: .color(TeslaCamTheme.Colors.gapAccent.opacity(0.22)), lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(spacing: 0) {
        Rectangle()
          .fill(TeslaCamTheme.Colors.gapAccent.opacity(0.85))
          .frame(height: 2)
        Spacer()
        Rectangle()
          .fill(TeslaCamTheme.Colors.gapAccent.opacity(0.35))
          .frame(height: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      if showLabel {
        Text("Gap")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(TeslaCamTheme.Colors.textPrimary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurface, radius: 999)
      }
    }
  }
}

private struct PrimaryButtonStyle: ButtonStyle {
  var fixedWidth: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundColor(.white)
      .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
      .frame(width: fixedWidth)
      .frame(minHeight: TeslaCamTheme.Metrics.controlHeight)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.accent.opacity(configuration.isPressed ? 0.82 : 1))
      )
  }
}

private struct IconButtonStyle: ButtonStyle {
  var prominent: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold))
      .foregroundColor(prominent ? .white : TeslaCamTheme.Colors.textPrimary)
      .frame(width: 42, height: 42)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(prominent ? TeslaCamTheme.Colors.surfaceElevated : TeslaCamTheme.Colors.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

private struct QuickActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(TeslaCamTheme.Colors.textPrimary.opacity(configuration.isPressed ? 0.78 : 0.95))
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surfaceElevated.opacity(configuration.isPressed ? 1 : 0.86))
      )
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 1)
      )
  }
}
