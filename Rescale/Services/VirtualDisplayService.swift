import Foundation
import CoreGraphics

/// Manages virtual HiDPI displays and mirrors physical displays to them,
/// enabling UI scaling without changing the physical display resolution.
@MainActor
final class VirtualDisplayService {
    static let shared = VirtualDisplayService()

    /// Active virtual display per physical display ID.
    private var virtualDisplays: [CGDirectDisplayID: CGVirtualDisplay] = [:]

    /// Currently applied logical width per physical display.
    private var appliedLogicalWidths: [CGDirectDisplayID: Int] = [:]

    /// Set of all virtual display IDs we've created, used to filter them from the monitor list.
    private(set) var virtualDisplayIDs: Set<CGDirectDisplayID> = []

    /// Whether a scaling operation is currently in progress.
    private var isConfiguring = false

    /// Resolved SLSSetDisplayColorSpace function pointer (loaded once via dlopen).
    private let setDisplayColorSpace: SLSSetDisplayColorSpaceFunc? = {
        guard let skylight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else { return nil }
        guard let sym = dlsym(skylight, "SLSSetDisplayColorSpace") else { return nil }
        return unsafeBitCast(sym, to: SLSSetDisplayColorSpaceFunc.self)
    }()

    private init() {}

    /// Returns true if the given display ID is one of our virtual displays.
    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        virtualDisplayIDs.contains(displayID)
    }

    /// Enables HiDPI scaling for a physical display by creating a virtual display
    /// and mirroring the physical display onto it.
    func enableHiDPI(
        for physicalDisplayID: CGDirectDisplayID,
        logicalWidth: Int,
        logicalHeight: Int,
        refreshRate: Double = 60.0
    ) async {
        // Prevent concurrent configuration changes
        guard !isConfiguring else {
            print("[VirtualDisplayService] Configuration already in progress, skipping")
            return
        }
        isConfiguring = true
        defer { isConfiguring = false }

        // Capture the physical display's color characteristics BEFORE any changes
        let physicalColorSpace = CGDisplayCopyColorSpace(physicalDisplayID)
        let physicalGamma = readGammaTable(for: physicalDisplayID)
        let primaries = extractPrimaries(from: physicalDisplayID)

        if let p = primaries {
            print("[VirtualDisplayService] Physical display primaries: R(\(String(format: "%.3f", p.red.x)), \(String(format: "%.3f", p.red.y))) G(\(String(format: "%.3f", p.green.x)), \(String(format: "%.3f", p.green.y))) B(\(String(format: "%.3f", p.blue.x)), \(String(format: "%.3f", p.blue.y)))")
        } else {
            print("[VirtualDisplayService] WARNING: Could not read physical display primaries")
        }

        if let g = physicalGamma {
            print("[VirtualDisplayService] Physical gamma table: \(g.sampleCount) samples captured")
        } else {
            print("[VirtualDisplayService] WARNING: Could not read physical gamma table")
        }

        // Tear down any existing virtual display for this monitor
        let hadExisting = virtualDisplays[physicalDisplayID] != nil
        disableHiDPI(for: physicalDisplayID)
        if hadExisting {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Read physical display properties for the descriptor
        let physicalVendor = CGDisplayVendorNumber(physicalDisplayID)
        let physicalProduct = CGDisplayModelNumber(physicalDisplayID)
        let physicalSize = CGDisplayScreenSize(physicalDisplayID)

        print("[VirtualDisplayService] Creating virtual display: logical=\(logicalWidth)×\(logicalHeight), backing=\(logicalWidth * 2)×\(logicalHeight * 2)")

        // Build the virtual display descriptor matching the physical display
        guard let descriptor = CGVirtualDisplayDescriptor() else {
            print("[VirtualDisplayService] Failed to create descriptor")
            return
        }
        descriptor.name = "Rescale HiDPI"
        descriptor.maxPixelsWide = UInt32(logicalWidth * 2)
        descriptor.maxPixelsHigh = UInt32(logicalHeight * 2)
        descriptor.sizeInMillimeters = physicalSize
        descriptor.vendorID = UInt32(physicalVendor)
        descriptor.productID = UInt32(physicalProduct)
        descriptor.serialNum = 1
        descriptor.queue = DispatchQueue(label: "com.rescale.virtualdisplay")

        // Set color primaries from the physical display's ICC profile
        if let p = primaries {
            descriptor.redPrimary = p.red
            descriptor.greenPrimary = p.green
            descriptor.bluePrimary = p.blue
            descriptor.whitePoint = p.white
        } else {
            // Fall back to Display P3 (most wide-gamut external monitors)
            descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
            descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
            descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
            descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        }

        descriptor.terminationHandler = { _, _ in }

        // Create the virtual display
        guard let vDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            print("[VirtualDisplayService] Failed to create virtual display")
            return
        }

        // Apply HiDPI settings
        guard let settings = CGVirtualDisplaySettings() else {
            print("[VirtualDisplayService] Failed to create settings")
            return
        }
        guard let mode = CGVirtualDisplayMode(
            width: UInt(logicalWidth),
            height: UInt(logicalHeight),
            refreshRate: refreshRate
        ) else {
            print("[VirtualDisplayService] Failed to create mode")
            return
        }
        settings.modes = [mode]
        settings.hiDPI = 1

        guard vDisplay.apply(settings) else {
            print("[VirtualDisplayService] Failed to apply HiDPI settings")
            return
        }

        let virtualID = vDisplay.displayID

        // Track BEFORE mirroring triggers display reconfiguration
        virtualDisplayIDs.insert(virtualID)
        virtualDisplays[physicalDisplayID] = vDisplay

        // Wait for the virtual display to fully register with WindowServer
        let registered = await waitForDisplay(virtualID, timeout: 5.0)
        if !registered {
            print("[VirtualDisplayService] Virtual display \(virtualID) never appeared")
            virtualDisplays.removeValue(forKey: physicalDisplayID)
            virtualDisplayIDs.remove(virtualID)
            return
        }

        // Small delay to let WindowServer fully initialize the display
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Configure mirroring — the physical display mirrors the virtual display.
        // Also explicitly un-mirror all other displays to prevent macOS from
        // pulling them into the mirror set.
        let mirrorOk = configureMirror(physicalID: physicalDisplayID, virtualID: virtualID)
        if !mirrorOk {
            // Retry once after a longer delay
            try? await Task.sleep(nanoseconds: 500_000_000)
            let retryOk = configureMirror(physicalID: physicalDisplayID, virtualID: virtualID)
            if !retryOk {
                print("[VirtualDisplayService] Failed to configure mirroring")
                virtualDisplays.removeValue(forKey: physicalDisplayID)
                virtualDisplayIDs.remove(virtualID)
                return
            }
        }

        // Apply color matching after mirror is established
        applyColorMatching(physicalColorSpace: physicalColorSpace, gamma: physicalGamma, to: virtualID)

        for delay in [300_000_000, 1_000_000_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: delay)
            applyColorMatching(physicalColorSpace: physicalColorSpace, gamma: physicalGamma, to: virtualID)
        }

        // Verify the color spaces match
        verifyColorMatch(physicalID: physicalDisplayID, virtualID: virtualID)

        appliedLogicalWidths[physicalDisplayID] = logicalWidth
        print("[VirtualDisplayService] SUCCESS: HiDPI \(logicalWidth)×\(logicalHeight) active for physical display \(physicalDisplayID)")
    }

    /// Removes mirroring and destroys the virtual display, pinning all other
    /// displays to their current positions so nothing else moves.
    func disableHiDPI(for physicalDisplayID: CGDirectDisplayID) {
        guard let vDisplay = virtualDisplays[physicalDisplayID] else { return }
        let virtualID = vDisplay.displayID

        // Snapshot all display positions before changing anything
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var allDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &allDisplays, &displayCount)

        var savedBounds: [CGDirectDisplayID: CGRect] = [:]
        for displayID in allDisplays {
            savedBounds[displayID] = CGDisplayBounds(displayID)
        }

        // Remove mirroring and pin all other displays
        var configRef: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef {
            CGConfigureDisplayMirrorOfDisplay(config, physicalDisplayID, kCGNullDirectDisplay)

            // Pin every non-target, non-virtual display to its current position
            for displayID in allDisplays {
                if displayID == physicalDisplayID || displayID == virtualID ||
                   virtualDisplayIDs.contains(displayID) {
                    continue
                }
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                if let bounds = savedBounds[displayID] {
                    CGConfigureDisplayOrigin(
                        config, displayID,
                        Int32(bounds.origin.x),
                        Int32(bounds.origin.y)
                    )
                }
            }

            let err = CGCompleteDisplayConfiguration(config, .forSession)
            if err != .success {
                print("[VirtualDisplayService] Failed to remove mirroring: \(err.rawValue)")
                CGCancelDisplayConfiguration(config)
            }
        }

        CGDisplayRestoreColorSyncSettings()

        // Release the virtual display AFTER mirror is unconfigured
        virtualDisplays.removeValue(forKey: physicalDisplayID)
        appliedLogicalWidths.removeValue(forKey: physicalDisplayID)
        virtualDisplayIDs.remove(virtualID)

        print("[VirtualDisplayService] Disabled HiDPI for display \(physicalDisplayID)")
    }

    func isHiDPIActive(for displayID: CGDirectDisplayID) -> Bool {
        virtualDisplays[displayID] != nil
    }

    func currentLogicalWidth(for displayID: CGDirectDisplayID) -> Int? {
        appliedLogicalWidths[displayID]
    }

    func tearDownAll() {
        for displayID in virtualDisplays.keys {
            disableHiDPI(for: displayID)
        }
    }

    // MARK: - Color Matching

    /// Applies both ICC color space and gamma table from the physical display to the virtual display.
    private func applyColorMatching(
        physicalColorSpace: CGColorSpace,
        gamma: GammaTable?,
        to virtualID: CGDirectDisplayID
    ) {
        // Copy full ICC color space via SkyLight
        if let setCS = setDisplayColorSpace {
            let err = setCS(virtualID, physicalColorSpace)
            if err != .success {
                print("[VirtualDisplayService] SLSSetDisplayColorSpace failed: \(err.rawValue)")
            }
        }

        // Copy gamma/transfer table
        if let g = gamma {
            let err = CGSetDisplayTransferByTable(
                virtualID, g.sampleCount, g.red, g.green, g.blue
            )
            if err != .success {
                print("[VirtualDisplayService] CGSetDisplayTransferByTable failed: \(err.rawValue)")
            }
        }
    }

    /// Logs whether the two displays' ICC profiles match after setup.
    private func verifyColorMatch(physicalID: CGDirectDisplayID, virtualID: CGDirectDisplayID) {
        let physCS = CGDisplayCopyColorSpace(physicalID)
        let virtCS = CGDisplayCopyColorSpace(virtualID)

        let physICC = physCS.copyICCData() as Data?
        let virtICC = virtCS.copyICCData() as Data?

        if let p = physICC, let v = virtICC {
            if p == v {
                print("[VirtualDisplayService] ✓ ICC profiles MATCH (\(p.count) bytes)")
            } else {
                print("[VirtualDisplayService] ✗ ICC profiles DIFFER: physical=\(p.count) bytes, virtual=\(v.count) bytes")

                // Compare profile names for diagnostics
                let physName = physCS.name as String? ?? "unknown"
                let virtName = virtCS.name as String? ?? "unknown"
                print("[VirtualDisplayService]   Physical profile: \(physName)")
                print("[VirtualDisplayService]   Virtual profile:  \(virtName)")
            }
        } else {
            print("[VirtualDisplayService] Could not read ICC data for comparison")
        }

        // Also check gamma tables
        let physGamma = readGammaTable(for: physicalID)
        let virtGamma = readGammaTable(for: virtualID)
        if let pg = physGamma, let vg = virtGamma {
            let redMatch = pg.red.prefix(5).map { String(format: "%.3f", $0) }
            let vRedMatch = vg.red.prefix(5).map { String(format: "%.3f", $0) }
            print("[VirtualDisplayService] Physical gamma[0..4]: \(redMatch)")
            print("[VirtualDisplayService] Virtual  gamma[0..4]: \(vRedMatch)")
        }
    }

    // MARK: - ICC Profile Parsing

    /// Extracts CIE xy chromaticity primaries from a display's ICC profile.
    private func extractPrimaries(
        from displayID: CGDirectDisplayID
    ) -> (red: CGPoint, green: CGPoint, blue: CGPoint, white: CGPoint)? {
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        guard let iccData = colorSpace.copyICCData() as Data?,
              iccData.count > 132 else { return nil }

        let tagCount = iccUInt32(iccData, offset: 128)

        // Build lookup from tag signature → byte offset
        var tagOffsets: [UInt32: Int] = [:]
        for i in 0..<Int(tagCount) {
            let base = 132 + i * 12
            guard base + 12 <= iccData.count else { break }
            tagOffsets[iccUInt32(iccData, offset: base)] = Int(iccUInt32(iccData, offset: base + 4))
        }

        /// Reads an XYZ tag and converts to CIE xy chromaticity.
        func xyChromaticity(signature: UInt32) -> CGPoint? {
            guard let offset = tagOffsets[signature],
                  offset + 20 <= iccData.count else { return nil }
            let base = offset + 8
            let x = iccS15Fixed16(iccData, offset: base)
            let y = iccS15Fixed16(iccData, offset: base + 4)
            let z = iccS15Fixed16(iccData, offset: base + 8)
            let sum = x + y + z
            guard sum > 0 else { return nil }
            return CGPoint(x: x / sum, y: y / sum)
        }

        guard let r = xyChromaticity(signature: 0x7258595A),  // rXYZ
              let g = xyChromaticity(signature: 0x6758595A),  // gXYZ
              let b = xyChromaticity(signature: 0x6258595A),  // bXYZ
              let w = xyChromaticity(signature: 0x77747074)   // wtpt
        else { return nil }

        return (red: r, green: g, blue: b, white: w)
    }

    private func iccUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private func iccS15Fixed16(_ data: Data, offset: Int) -> Double {
        Double(Int32(bitPattern: iccUInt32(data, offset: offset))) / 65536.0
    }

    // MARK: - Gamma Table

    /// Stored gamma table from a physical display.
    private struct GammaTable {
        let sampleCount: UInt32
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    /// Reads the current gamma/transfer table for a display.
    private func readGammaTable(for displayID: CGDirectDisplayID) -> GammaTable? {
        var red = [CGGammaValue](repeating: 0, count: 256)
        var green = [CGGammaValue](repeating: 0, count: 256)
        var blue = [CGGammaValue](repeating: 0, count: 256)
        var sampleCount: UInt32 = 0

        let err = CGGetDisplayTransferByTable(displayID, 256, &red, &green, &blue, &sampleCount)
        guard err == .success, sampleCount > 0 else { return nil }

        return GammaTable(
            sampleCount: sampleCount,
            red: Array(red.prefix(Int(sampleCount))),
            green: Array(green.prefix(Int(sampleCount))),
            blue: Array(blue.prefix(Int(sampleCount)))
        )
    }

    // MARK: - Helpers

    /// Configures the physical display to mirror the virtual display in a single
    /// transaction. Pins every other display to its current position and state
    /// so the built-in display is never touched.
    private func configureMirror(
        physicalID: CGDirectDisplayID,
        virtualID: CGDirectDisplayID
    ) -> Bool {
        // Snapshot ALL current displays and their positions before changing anything
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var allDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &allDisplays, &displayCount)

        // Save every display's current bounds
        var savedBounds: [CGDirectDisplayID: CGRect] = [:]
        for displayID in allDisplays {
            savedBounds[displayID] = CGDisplayBounds(displayID)
        }

        // The virtual display should sit where the physical display currently is
        let physicalBounds = CGDisplayBounds(physicalID)

        var configRef: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        guard beginErr == .success, let config = configRef else {
            print("[VirtualDisplayService] CGBeginDisplayConfiguration failed: \(beginErr.rawValue)")
            return false
        }

        // Set the physical display to mirror the virtual display
        CGConfigureDisplayMirrorOfDisplay(config, physicalID, virtualID)

        // Place the virtual display where the physical display was — NOT at (0,0)
        // which would displace the built-in display
        CGConfigureDisplayOrigin(
            config, virtualID,
            Int32(physicalBounds.origin.x),
            Int32(physicalBounds.origin.y)
        )

        // Pin every other display to its current position and ensure it's not mirroring
        for displayID in allDisplays {
            if displayID == physicalID || displayID == virtualID ||
               virtualDisplayIDs.contains(displayID) {
                continue
            }

            // Force this display to NOT mirror anything
            CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)

            // Pin it to its current position so it doesn't move
            if let bounds = savedBounds[displayID] {
                CGConfigureDisplayOrigin(
                    config, displayID,
                    Int32(bounds.origin.x),
                    Int32(bounds.origin.y)
                )
            }
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        if completeErr != .success {
            print("[VirtualDisplayService] CGCompleteDisplayConfiguration failed: \(completeErr.rawValue)")
            CGCancelDisplayConfiguration(config)
            return false
        }

        // Verify the mirror actually took effect
        let mirrorOf = CGDisplayMirrorsDisplay(physicalID)
        if mirrorOf == virtualID {
            print("[VirtualDisplayService] ✓ Mirror verified: physical \(physicalID) mirrors virtual \(virtualID)")
        } else {
            print("[VirtualDisplayService] ✗ Mirror NOT active: CGDisplayMirrorsDisplay returned \(mirrorOf)")
        }

        return true
    }

    /// Polls the system display list until the given display ID appears or timeout expires.
    private func waitForDisplay(_ displayID: CGDirectDisplayID, timeout: Double) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetOnlineDisplayList(count, &ids, &count)
            if ids.contains(displayID) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

/// Function signature for SLSSetDisplayColorSpace from the SkyLight framework.
private typealias SLSSetDisplayColorSpaceFunc = @convention(c) (CGDirectDisplayID, CGColorSpace) -> CGError
