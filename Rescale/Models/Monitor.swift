import Foundation
import CoreGraphics
import AppKit

// MARK: - ScaleStep

/// Represents one discrete UI scale position — a logical resolution the display
/// can render at while keeping its native physical resolution.
struct ScaleStep: Identifiable, Equatable {
    let logicalWidth: Int
    let logicalHeight: Int

    var id: String { "\(logicalWidth)x\(logicalHeight)" }
    var label: String { "\(logicalWidth) × \(logicalHeight)" }
}

// MARK: - DisplayMode

/// Wraps a CGDisplayMode with pre-extracted properties.
struct DisplayMode: Identifiable, Hashable {
    let cgMode: CGDisplayMode
    let width: Int           // logical width (points)
    let height: Int          // logical height (points)
    let pixelWidth: Int      // backing pixel width
    let pixelHeight: Int     // backing pixel height
    let refreshRate: Double  // Hz
    let isHiDPI: Bool

    var id: String { "\(width)x\(height)@\(refreshRate)_\(isHiDPI)" }

    init(cgMode: CGDisplayMode) {
        self.cgMode = cgMode
        self.width = cgMode.width
        self.height = cgMode.height
        self.pixelWidth = cgMode.pixelWidth
        self.pixelHeight = cgMode.pixelHeight
        self.refreshRate = cgMode.refreshRate
        self.isHiDPI = cgMode.pixelWidth > 0 && cgMode.pixelWidth > cgMode.width
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height &&
        lhs.refreshRate == rhs.refreshRate && lhs.isHiDPI == rhs.isHiDPI
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(refreshRate)
        hasher.combine(isHiDPI)
    }
}

// MARK: - Monitor

/// Represents a connected display with its available modes and brightness.
@MainActor
final class Monitor: ObservableObject, Identifiable {
    nonisolated var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool

    /// Native panel pixel dimensions, captured at init before any scaling is applied.
    let nativeWidth: Int
    let nativeHeight: Int

    @Published var modes: [DisplayMode] = []
    @Published var currentMode: DisplayMode?
    @Published var brightness: Double = 100
    @Published var ddcAvailable: Bool = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        self.name = Self.screenName(for: displayID, isBuiltin: isBuiltin)

        // Capture native pixel dimensions from the current display mode
        self.nativeWidth = Int(CGDisplayPixelsWide(displayID))
        self.nativeHeight = Int(CGDisplayPixelsHigh(displayID))

        loadModes()
    }

    var nativeResolutionLabel: String { "\(nativeWidth) × \(nativeHeight)" }

    /// Generates UI scale steps from 100% (native 1:1) up to 200% (2× magnification).
    /// Each step is a logical resolution the virtual display will use, producing
    /// progressively larger UI elements while the physical output stays at native resolution.
    var scaleSteps: [ScaleStep] {
        let w = nativeWidth
        let h = nativeHeight

        guard w > 0, h > 0 else { return [] }

        // Scale factors from 1.0 (native, smallest UI) to 2.0 (largest UI)
        let factors: [Double] = [1.0, 1.15, 1.25, 1.4, 1.5, 1.6, 1.75, 2.0]
        return factors.map { factor in
            // Logical resolution = native / factor, rounded to nearest even number
            let lw = Int((Double(w) / factor / 2.0).rounded()) * 2
            let lh = Int((Double(h) / factor / 2.0).rounded()) * 2
            return ScaleStep(logicalWidth: lw, logicalHeight: lh)
        }
    }

    /// Reloads available display modes and current mode from CoreGraphics.
    func loadModes() {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return }

        modes = cgModes
            .map { DisplayMode(cgMode: $0) }
            .filter { $0.cgMode.isUsableForDesktopGUI() }

        if let cg = CGDisplayCopyDisplayMode(displayID) {
            currentMode = DisplayMode(cgMode: cg)
        }
    }

    /// Reads DDC brightness asynchronously and updates published state.
    func refreshBrightness() async {
        guard !isBuiltin else { return }
        let result = await Task.detached { [displayID] in
            BrightnessService.shared.readBrightness(for: displayID)
        }.value
        if let result {
            brightness = result.current
            ddcAvailable = true
        }
    }

    private static func screenName(for id: CGDirectDisplayID, isBuiltin: Bool) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == id
        }?.localizedName ?? (isBuiltin ? "Built-in Display" : "External Display")
    }
}
