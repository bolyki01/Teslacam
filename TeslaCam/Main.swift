#if os(macOS)
import AppKit
import SwiftUI
#if canImport(Sentry)
import Sentry
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var window: NSWindow?
  private var settingsWindow: NSWindow?
  private let state = AppState()

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()

    let content = ContentView().environmentObject(state)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.title = "TeslaCam"
    window.contentView = NSHostingView(rootView: content)
    window.makeKeyAndOrderFront(nil)

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    self.window = window
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if state.exporter.isExporting {
      state.cancelExport()
      window?.makeKeyAndOrderFront(nil)
      return .terminateCancel
    }
    state.shutdownForTermination()
    if sender.modalWindow != nil {
      sender.abortModal()
    }
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    state.shutdownForTermination()
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let urls = filenames.map { URL(fileURLWithPath: $0) }
    if !urls.isEmpty {
      state.ingestDroppedURLs(urls)
      NSApp.activate(ignoringOtherApps: true)
      window?.makeKeyAndOrderFront(nil)
    }
    sender.reply(toOpenOrPrint: .success)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  private func installMainMenu() {
    let appName = ProcessInfo.processInfo.processName
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu(title: appName)
    let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
    settingsItem.target = self
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    let openItem = fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder), keyEquivalent: "o")
    openItem.target = self
    let reloadItem = fileMenu.addItem(withTitle: "Reload", action: #selector(reloadSources), keyEquivalent: "r")
    reloadItem.target = self
    fileMenu.addItem(NSMenuItem.separator())
    let exportItem = fileMenu.addItem(withTitle: "Export Range…", action: #selector(exportRange), keyEquivalent: "e")
    exportItem.target = self
    let cancelItem = fileMenu.addItem(withTitle: "Cancel Export", action: #selector(cancelExport), keyEquivalent: ".")
    cancelItem.target = self
    let revealItem = fileMenu.addItem(withTitle: "Reveal Last Export", action: #selector(revealLastExport), keyEquivalent: "R")
    revealItem.target = self
    fileMenuItem.submenu = fileMenu

    NSApp.mainMenu = mainMenu
  }

  @objc private func openFolder() {
    state.chooseFolder()
  }

  @objc private func reloadSources() {
    state.reloadSources()
  }

  @objc private func exportRange() {
    state.exportRange()
  }

  @objc private func cancelExport() {
    state.cancelExport()
  }

  @objc private func revealLastExport() {
    state.revealLastExport()
  }

  @objc private func showSettingsWindow() {
    if settingsWindow == nil {
      let settingsView = SettingsView().environmentObject(state)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = "Settings"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: settingsView)
      settingsWindow = window
    }

    settingsWindow?.center()
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(openFolder):
      return !state.exporter.isExporting
    case #selector(reloadSources):
      return state.canReloadSources
    case #selector(exportRange):
      return state.canExport
    case #selector(cancelExport):
      return state.exporter.isExporting
    case #selector(revealLastExport):
      return !state.exporter.exportHistory.isEmpty
    default:
      return true
    }
  }
}

@main
struct MainApp {
  static func main() {
    startSentryIfConfigured()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.activate(ignoringOtherApps: true)
    app.run()
  }
}

private func startSentryIfConfigured() {
  #if canImport(Sentry)
  guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
    return
  }

  let rawDSN = (Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String)
    ?? ProcessInfo.processInfo.environment["SENTRY_DSN"]
    ?? ""
  let dsn = rawDSN.trimmingCharacters(in: .whitespacesAndNewlines)
  guard dsn.isEmpty == false else {
    return
  }

  SentrySDK.start { options in
    options.dsn = dsn
    options.debug = false
    options.enableSwizzling = false
    options.sendDefaultPii = false
    options.tracesSampleRate = 0
    options.profilesSampleRate = 0
  }
  #endif
}

private struct SettingsView: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    ZStack {
      TeslaCamSceneBackground()

      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.screen) {
        VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.xs) {
          Text("TeslaCam Settings")
            .font(TeslaCamTheme.Typography.panelTitle)
            .foregroundColor(TeslaCamTheme.Colors.textPrimary)
          Text("Keep defaults here. Keep playback simple.")
            .font(TeslaCamTheme.Typography.sectionTitle.weight(.regular))
            .foregroundColor(TeslaCamTheme.Colors.textSecondary)
        }

        settingsCard {
          VStack(alignment: .leading, spacing: 14) {
            Text("Default Export Preset")
              .font(TeslaCamTheme.Typography.sectionTitle)
              .foregroundColor(TeslaCamTheme.Colors.textPrimary)

            Picker("", selection: $state.exportPreset) {
              ForEach(ExportPreset.allCases) { preset in
                Text(preset.displayName).tag(preset)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
          }
        }

        settingsCard {
          VStack(alignment: .leading, spacing: 14) {
            Text("Duplicate Handling")
              .font(TeslaCamTheme.Typography.sectionTitle)
              .foregroundColor(TeslaCamTheme.Colors.textPrimary)

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
            .pickerStyle(.segmented)

            Toggle("Show duplicate resolver when conflicts exist", isOn: $state.showDuplicateResolverForConflicts)
              .toggleStyle(.switch)
              .foregroundColor(TeslaCamTheme.Colors.textSecondary)
          }
        }

#if DEBUG
        if TeslaCamBuildFlags.showsDebugTools {
          DebugEventsCard(logSink: state.debugLog)
        }
#endif

        Spacer()
      }
      .padding(TeslaCamTheme.Spacing.screen + 2)
    }
    .frame(minWidth: 460, minHeight: 460)
  }

  private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(TeslaCamTheme.Metrics.cardPadding)
      .teslaCamCard()
  }
}

private struct DebugEventsCard: View {
  @ObservedObject var logSink: DebugLogSink

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Recent Debug Events")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(TeslaCamTheme.Colors.textPrimary)

      if logSink.events.isEmpty {
        Text("No events yet.")
          .font(.system(size: 12))
          .foregroundColor(TeslaCamTheme.Colors.textTertiary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(logSink.events.suffix(8).reversed())) { event in
              VStack(alignment: .leading, spacing: 2) {
                Text("[\(event.category)] \(event.message)")
                  .font(.system(size: 11, weight: .medium, design: .monospaced))
                  .foregroundColor(TeslaCamTheme.Colors.textSecondary)
                Text(TeslaCamFormatters.fullDateTime.string(from: event.timestamp))
                  .font(.system(size: 10, weight: .regular, design: .monospaced))
                  .foregroundColor(TeslaCamTheme.Colors.textTertiary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .frame(height: 110)
      }
    }
    .padding(18)
    .teslaCamCard()
  }
}
#endif
