import Foundation
import CoreGraphics
import ServiceManagement

/// Persists per-display scale settings and launch-at-login state via UserDefaults.
enum ScaleSettingsStore {
    private nonisolated(unsafe) static let defaults = UserDefaults.standard
    private static let scalePrefix = "rescale.scaleIndex."
    private static let launchAtLoginKey = "rescale.launchAtLogin"

    // MARK: - Per-Display Scale Index

    /// Saves the selected scale index for a display, keyed by vendor+product ID
    /// so it survives display ID changes across reboots.
    static func saveScale(index: Int, for displayID: CGDirectDisplayID) {
        let key = scaleKey(for: displayID)
        defaults.set(index, forKey: key)
    }

    /// Loads the saved scale index for a display. Returns nil if none was saved.
    static func loadScale(for displayID: CGDirectDisplayID) -> Int? {
        let key = scaleKey(for: displayID)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    /// Removes the saved scale setting for a display.
    static func removeScale(for displayID: CGDirectDisplayID) {
        let key = scaleKey(for: displayID)
        defaults.removeObject(forKey: key)
    }

    /// Returns all saved display keys and their scale indices.
    static func allSavedScales() -> [(key: String, index: Int)] {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(scalePrefix) }
            .compactMap { key, value in
                guard let idx = value as? Int else { return nil }
                return (key: key, index: idx)
            }
    }

    /// Builds a stable key from vendor + product ID (these don't change across reboots,
    /// unlike CGDirectDisplayID which can).
    private static func scaleKey(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        return "\(scalePrefix)\(vendor)_\(product)"
    }

    // MARK: - Launch at Login

    /// Whether launch-at-login is currently enabled.
    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: launchAtLoginKey) }
        set {
            defaults.set(newValue, forKey: launchAtLoginKey)
            updateLoginItem(enabled: newValue)
        }
    }

    /// Registers or unregisters the app as a login item via SMAppService.
    private static func updateLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                print("[ScaleSettingsStore] Registered as login item")
            } else {
                try service.unregister()
                print("[ScaleSettingsStore] Unregistered login item")
            }
        } catch {
            print("[ScaleSettingsStore] Login item update failed: \(error)")
        }
    }
}
