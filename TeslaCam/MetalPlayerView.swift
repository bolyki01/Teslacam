#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import MetalKit

struct MetalPlayerView: NSViewRepresentable {
  @ObservedObject var playback: MultiCamPlaybackController
  var cameraOrder: [Camera]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.preferredFramesPerSecond = 30

    if let renderer = MetalRenderer(mtkView: view) {
      context.coordinator.renderer = renderer
      applyState(to: renderer)
      view.delegate = renderer
    }

    return view
  }

  func updateNSView(_ nsView: MTKView, context: Context) {
    guard let renderer = context.coordinator.renderer else { return }
    applyState(to: renderer)
    nsView.needsDisplay = true
  }

  static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
    nsView.delegate = nil
    coordinator.renderer = nil
  }

  private func applyState(to renderer: MetalRenderer) {
    renderer.cameraOrder = cameraOrder
    renderer.itemTimeProvider = { playback.currentItemTime() }
    renderer.fileURLsProvider = { playback.files }
    renderer.cameraDurationsProvider = { playback.cameraDurations }
  }

  final class Coordinator: NSObject {
    var renderer: MetalRenderer?
  }
}
#endif
