import Foundation
import Metal
import MetalKit
import AVFoundation

protocol PreviewFrameCaching: AnyObject {
  func texture(
    for camera: Camera,
    at itemTime: CMTime,
    from fileURLs: [Camera: URL],
    cameraDurations: [Camera: Double],
    previousTexture: MTLTexture?,
    onReady: @escaping () -> Void
  ) -> MTLTexture?

  func invalidate(camera: Camera)
}

private final class PreviewImageResultBox: @unchecked Sendable {
  nonisolated(unsafe) var image: CGImage?
}

final class PreviewFrameCache: PreviewFrameCaching {
  private let textureLoader: MTKTextureLoader
  private var fallbackGenerators: [URL: PreviewImageGeneratorBox] = [:]
  private let decodeQueue = DispatchQueue(label: "com.magrathean.TeslaCam.preview-cache", qos: .userInitiated)
  private let cacheLock = NSLock()
  private var pendingFrameKeys: Set<String> = []
  private var queuedFrameKeysByCamera: [Camera: String] = [:]
  private var lastFrameKeysByCamera: [Camera: String] = [:]
  private var cachedTextures: [String: MTLTexture] = [:]
  private var cachedTextureOrder: [String] = []
  private let maxCachedTextureCount = 90

  init(textureLoader: MTKTextureLoader) {
    self.textureLoader = textureLoader
  }

  func texture(
    for camera: Camera,
    at itemTime: CMTime,
    from fileURLs: [Camera: URL],
    cameraDurations: [Camera: Double],
    previousTexture: MTLTexture?,
    onReady: @escaping () -> Void
  ) -> MTLTexture? {
    guard let url = fileURLs[camera] else {
      invalidate(camera: camera)
      return nil
    }

    let seconds = max(0, itemTime.seconds.isFinite ? itemTime.seconds : 0)
    if let duration = cameraDurations[camera], seconds > duration + (1.0 / 30.0) {
      invalidate(camera: camera)
      return nil
    }

    let bucket = Int((seconds * 12.0).rounded(.down))
    let frameKey = "\(url.path)#\(bucket)"
    if lastFrameKeysByCamera[camera] == frameKey {
      return previousTexture
    }
    if let texture = cachedTexture(for: frameKey) {
      lastFrameKeysByCamera[camera] = frameKey
      return texture
    }

    queuePreviewDecode(camera: camera, frameKey: frameKey, url: url, seconds: seconds, onReady: onReady)
    return previousTexture
  }

  func invalidate(camera: Camera) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    lastFrameKeysByCamera[camera] = nil
    queuedFrameKeysByCamera[camera] = nil
  }

  private func queuePreviewDecode(
    camera: Camera,
    frameKey: String,
    url: URL,
    seconds: Double,
    onReady: @escaping () -> Void
  ) {
    guard beginQueuedDecode(camera: camera, frameKey: frameKey) else { return }

    decodeQueue.async { [weak self] in
      guard let self else { return }
      guard self.shouldDecode(camera: camera, frameKey: frameKey) else {
        self.finishQueuedDecode(camera: camera, frameKey: frameKey)
        return
      }

      let image = self.copyPreviewImage(url: url, seconds: seconds)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        defer {
          self.finishQueuedDecode(camera: camera, frameKey: frameKey)
          onReady()
        }

        guard let image,
              let texture = try? self.textureLoader.newTexture(
                cgImage: image,
                options: [MTKTextureLoader.Option.SRGB: false]
              )
        else { return }

        self.storeCachedTexture(texture, for: frameKey)
      }
    }
  }

  private func copyPreviewImage(url: URL, seconds: Double) -> CGImage? {
    let generator = fallbackGenerators[url] ?? {
      let asset = AVURLAsset(url: url)
      let tolerance = CMTime(seconds: 1.0, preferredTimescale: 600)
      let generator = PreviewImageGeneratorBox(asset: asset, tolerance: tolerance)
      fallbackGenerators[url] = generator
      return generator
    }()

    let attempts = [seconds, max(0, seconds - 0.15), seconds + 0.15, seconds + 0.5, seconds + 1.0]
    for candidate in attempts {
      if let image = waitForImage(from: generator, at: CMTime(seconds: candidate, preferredTimescale: 600)) {
        return image
      }
    }
    return nil
  }

  private func waitForImage(from generator: PreviewImageGeneratorBox, at time: CMTime) -> CGImage? {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = PreviewImageResultBox()
    Task.detached(priority: .userInitiated) {
      resultBox.image = await generator.image(at: time)
      semaphore.signal()
    }
    semaphore.wait()
    return resultBox.image
  }

  private func beginQueuedDecode(camera: Camera, frameKey: String) -> Bool {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    queuedFrameKeysByCamera[camera] = frameKey
    if pendingFrameKeys.contains(frameKey) {
      return false
    }
    pendingFrameKeys.insert(frameKey)
    return true
  }

  private func shouldDecode(camera: Camera, frameKey: String) -> Bool {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return queuedFrameKeysByCamera[camera] == frameKey
  }

  private func finishQueuedDecode(camera: Camera, frameKey: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    pendingFrameKeys.remove(frameKey)
    if queuedFrameKeysByCamera[camera] == frameKey {
      queuedFrameKeysByCamera[camera] = nil
    }
  }

  private func cachedTexture(for frameKey: String) -> MTLTexture? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return cachedTextures[frameKey]
  }

  private func storeCachedTexture(_ texture: MTLTexture, for frameKey: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    cachedTextures[frameKey] = texture
    cachedTextureOrder.removeAll { $0 == frameKey }
    cachedTextureOrder.append(frameKey)
    while cachedTextureOrder.count > maxCachedTextureCount {
      let oldest = cachedTextureOrder.removeFirst()
      cachedTextures.removeValue(forKey: oldest)
    }
  }
}

private actor PreviewImageGeneratorBox {
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

final class MetalRenderer: NSObject, MTKViewDelegate {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private let vertexBuffer: MTLBuffer
  private let blackTexture: MTLTexture
  private weak var view: MTKView?
  private let frameCache: PreviewFrameCaching

  var cameraOrder: [Camera] = []
  var itemTimeProvider: (() -> CMTime)?
  var fileURLsProvider: (() -> [Camera: URL])?
  var cameraDurationsProvider: (() -> [Camera: Double])?

  private var lastTextures: [Camera: MTLTexture] = [:]

  init?(mtkView: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    self.device = device
    self.view = mtkView
    guard let queue = device.makeCommandQueue() else { return nil }
    self.commandQueue = queue
    self.frameCache = PreviewFrameCache(textureLoader: MTKTextureLoader(device: device))

    mtkView.device = device
    mtkView.colorPixelFormat = .bgra8Unorm
    mtkView.framebufferOnly = false

    guard let lib = MetalRenderer.loadLibrary(device: device),
          let vertexFunc = lib.makeFunction(name: "vertex_main"),
          let fragFunc = lib.makeFunction(name: "fragment_main") else { return nil }

    let pipelineDesc = MTLRenderPipelineDescriptor()
    pipelineDesc.vertexFunction = vertexFunc
    pipelineDesc.fragmentFunction = fragFunc
    pipelineDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

    do {
      pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
    } catch {
      return nil
    }

    let samplerDesc = MTLSamplerDescriptor()
    samplerDesc.minFilter = .linear
    samplerDesc.magFilter = .linear
    samplerDesc.sAddressMode = .clampToEdge
    samplerDesc.tAddressMode = .clampToEdge
    sampler = device.makeSamplerState(descriptor: samplerDesc)!

    let quad: [Float] = [
      -1, -1, 0, 1,
       1, -1, 1, 1,
      -1,  1, 0, 0,
       1, -1, 1, 1,
       1,  1, 1, 0,
      -1,  1, 0, 0
    ]
    vertexBuffer = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<Float>.size, options: [])!

    let blackDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
    blackDesc.usage = [.shaderRead]
    blackTexture = device.makeTexture(descriptor: blackDesc)!
    var blackPixel: [UInt8] = [0, 0, 0, 255]
    blackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &blackPixel, bytesPerRow: 4)

    super.init()
  }

  private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    guard let url = bundle.url(forResource: "MetalShaders", withExtension: "metal") else {
      return device.makeDefaultLibrary()
    }
    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      return try device.makeLibrary(source: source, options: nil)
    } catch {
      return device.makeDefaultLibrary()
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let pass = view.currentRenderPassDescriptor else { return }

    let itemTime = itemTimeProvider?() ?? .zero
    let fileURLs = fileURLsProvider?() ?? [:]
    let cameraDurations = cameraDurationsProvider?() ?? [:]
    for camera in cameraOrder {
      let onReady: () -> Void = { [weak view] in
        guard let view else { return }
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
      }
      if let texture = frameCache.texture(
        for: camera,
        at: itemTime,
        from: fileURLs,
        cameraDurations: cameraDurations,
        previousTexture: lastTextures[camera],
        onReady: onReady
      ) {
        lastTextures[camera] = texture
      } else {
        lastTextures[camera] = nil
      }
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)

    let cams = cameraOrder
    let count = cams.count
    let usesHw4Grid = Set(cams).isSubset(of: Set(Camera.hw4SixCamOrder)) && !Set(cams).intersection([.left, .right, .left_pillar, .right_pillar]).isEmpty
    let columns = usesHw4Grid ? 3 : (count > 4 ? 3 : 2)
    let rows = usesHw4Grid ? 3 : 2

    let w = Double(view.drawableSize.width)
    let h = Double(view.drawableSize.height)
    let tileW = w / Double(columns)
    let tileH = h / Double(rows)

    for (idx, camera) in cams.enumerated() {
      let col: Int
      let row: Int
      if usesHw4Grid {
        switch camera {
        case .front:
          row = 0
          col = 1
        case .left:
          row = 1
          col = 0
        case .back:
          row = 1
          col = 1
        case .right:
          row = 1
          col = 2
        case .left_pillar:
          row = 2
          col = 0
        case .right_pillar:
          row = 2
          col = 2
        default:
          row = idx / columns
          col = idx % columns
        }
      } else {
        col = idx % columns
        row = idx / columns
      }
      let tileViewport = MTLViewport(
        originX: Double(col) * tileW,
        originY: Double(row) * tileH,
        width: tileW,
        height: tileH,
        znear: 0,
        zfar: 1
      )
      let texture = lastTextures[camera] ?? blackTexture
      let viewport = aspectFitViewport(
        tile: tileViewport,
        textureWidth: texture.width,
        textureHeight: texture.height
      )
      encoder.setViewport(viewport)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func aspectFitViewport(tile: MTLViewport, textureWidth: Int, textureHeight: Int) -> MTLViewport {
    guard textureWidth > 0, textureHeight > 0, tile.width > 0, tile.height > 0 else {
      return tile
    }

    let sourceAspect = Double(textureWidth) / Double(textureHeight)
    let tileAspect = tile.width / tile.height

    if sourceAspect > tileAspect {
      let fittedHeight = tile.width / sourceAspect
      let yInset = (tile.height - fittedHeight) / 2
      return MTLViewport(
        originX: tile.originX,
        originY: tile.originY + yInset,
        width: tile.width,
        height: fittedHeight,
        znear: tile.znear,
        zfar: tile.zfar
      )
    } else {
      let fittedWidth = tile.height * sourceAspect
      let xInset = (tile.width - fittedWidth) / 2
      return MTLViewport(
        originX: tile.originX + xInset,
        originY: tile.originY,
        width: fittedWidth,
        height: tile.height,
        znear: tile.znear,
        zfar: tile.zfar
      )
    }
  }
}
