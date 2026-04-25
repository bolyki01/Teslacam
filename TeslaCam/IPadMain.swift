#if os(iOS)
import SwiftUI
#if canImport(Sentry)
import Sentry
#endif

@main
struct TeslaCamIPadApp: App {
  @StateObject private var state = AppState()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(state)
    }
  }
}
#endif
