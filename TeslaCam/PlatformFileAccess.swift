import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Platform File Access

/// Abstraction over file/folder picking and revealing across macOS and iPadOS.
/// macOS uses NSOpenPanel / NSSavePanel / NSWorkspace.
/// iPad uses SwiftUI fileImporter / fileExporter modals and UIActivityViewController.
enum PlatformFileAccess {

  // MARK: Bookmark options

  #if os(macOS)
  static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
  static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
  #else
  static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
  static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
  #endif

  // MARK: Choose folder (macOS)

  #if os(macOS)
  static func chooseFolder(
    title: String = "Select TeslaCam Files/Folders",
    directoryURL: URL?,
    completion: @escaping ([URL]) -> Void
  ) {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Choose"
    panel.directoryURL = directoryURL

    presentOpenPanel(panel) { urls in
      completion(urls)
    }
  }

  static func presentOpenPanel(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window) { response in
        guard response == .OK else { return }
        completion(panel.urls)
      }
      return
    }

    if panel.runModal() == .OK {
      completion(panel.urls)
    }
  }
  #endif

  // MARK: Save panel (macOS)

  #if os(macOS)
  static func presentSavePanel(
    title: String = "Save Export",
    nameFieldStringValue: String,
    allowedContentTypes: [UTType],
    directoryURL: URL?,
    completion: @escaping (URL) -> Void
  ) {
    let panel = NSSavePanel()
    panel.title = title
    panel.nameFieldStringValue = nameFieldStringValue
    panel.canCreateDirectories = true
    panel.allowedContentTypes = allowedContentTypes
    panel.directoryURL = directoryURL

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

  // MARK: Reveal in Finder / Share on iPad

  #if os(macOS)
  static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
  #else
  /// On iPad, "reveal" is not available. Use share sheet instead.
  static func shareFile(_ url: URL, from viewController: UIViewController? = nil) {
    let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    guard let presenter = viewController ?? topViewController() else { return }
    activityVC.popoverPresentationController?.sourceView = presenter.view
    activityVC.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX,
      y: presenter.view.bounds.midY,
      width: 0,
      height: 0
    )
    presenter.present(activityVC, animated: true)
  }

  private static func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first(where: \.isKeyWindow),
          var top = window.rootViewController else { return nil }
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
  #endif

  // MARK: Activate app

  #if os(macOS)
  static func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
  }
  #else
  static func activateApp() {
    // No-op on iPad; app is always active when in foreground.
  }
  #endif
}

// MARK: - UTType helpers

import UniformTypeIdentifiers

extension PlatformFileAccess {
  static func contentTypes(for preset: ExportPreset) -> [UTType] {
    preset.defaultExtension == "mov" ? [.movie] : [.mpeg4Movie]
  }
}
