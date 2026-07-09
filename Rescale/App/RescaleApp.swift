import SwiftUI

@main
struct RescaleApp: App {
    @StateObject private var displayService = DisplayService()

    /// Handles cleanup and restoring saved scale settings.
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

/// Restores saved scale settings on launch and cleans up virtual displays on quit.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // Brief delay to let displays enumerate
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await restoreSavedScales()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            VirtualDisplayService.shared.tearDownAll()
        }
    }

    /// Re-applies saved scale settings for all connected displays.
    @MainActor
    private func restoreSavedScales() async {
        let service = VirtualDisplayService.shared

        // Find all connected external displays
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        for displayID in ids {
            guard CGDisplayIsBuiltin(displayID) == 0 else { continue }

            // Check if this display has a saved scale setting
            guard let savedIdx = ScaleSettingsStore.loadScale(for: displayID),
                  savedIdx > 0 else { continue }

            // Compute the scale step for this display
            let nativeW = Int(CGDisplayPixelsWide(displayID))
            let nativeH = Int(CGDisplayPixelsHigh(displayID))
            let factors: [Double] = [1.0, 1.15, 1.25, 1.4, 1.5, 1.6, 1.75, 2.0]

            guard savedIdx < factors.count else { continue }

            let factor = factors[savedIdx]
            let logicalW = Int((Double(nativeW) / factor / 2.0).rounded()) * 2
            let logicalH = Int((Double(nativeH) / factor / 2.0).rounded()) * 2

            print("[Rescale] Restoring scale index \(savedIdx) (\(logicalW)×\(logicalH)) for display \(displayID)")

            await service.enableHiDPI(
                for: displayID,
                logicalWidth: logicalW,
                logicalHeight: logicalH
            )
        }
    }
}
