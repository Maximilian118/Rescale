import SwiftUI

@main
struct RescaleApp: App {
    @StateObject private var displayService = DisplayService()

    /// Handles cleanup when the app terminates.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(displayService)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Cleans up virtual displays when the app is about to quit.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            VirtualDisplayService.shared.tearDownAll()
        }
    }
}
