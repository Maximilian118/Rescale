import Foundation
import CoreGraphics

// MARK: - Reconfig callback (top-level C function)

/// Called by CoreGraphics when any display is added, removed, or changes mode.
private func reconfigCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }
    let service = Unmanaged<DisplayService>.fromOpaque(ptr).takeUnretainedValue()
    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .setModeFlag]
    guard !flags.intersection(relevant).isEmpty,
          !flags.contains(.beginConfigurationFlag) else { return }

    Task { @MainActor in
        service.refresh()
    }
}

// MARK: - DisplayService

/// Enumerates connected monitors and handles display hotplug events.
@MainActor
final class DisplayService: ObservableObject {
    @Published var monitors: [Monitor] = []

    // Stored outside actor isolation so deinit can access it.
    nonisolated(unsafe) private var callbackCtx: UnsafeMutableRawPointer?

    init() {
        refresh()
        let ctx = Unmanaged.passRetained(self).toOpaque()
        callbackCtx = ctx
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, ctx)
    }

    deinit {
        if let ctx = callbackCtx {
            CGDisplayRemoveReconfigurationCallback(reconfigCallback, ctx)
            Unmanaged<DisplayService>.fromOpaque(ctx).release()
        }
    }

    /// Re-enumerates all online displays, preserving existing Monitor objects.
    func refresh() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let existingByID = Dictionary(uniqueKeysWithValues: monitors.map { ($0.displayID, $0) })

        monitors = (0..<Int(count)).map { i in
            let id = ids[i]
            if let existing = existingByID[id] {
                existing.loadModes()
                return existing
            }
            return Monitor(displayID: id)
        }
    }

    /// Switches a display to the given mode.
    static func setMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) {
        let err = CGDisplaySetDisplayMode(displayID, mode.cgMode, nil)
        if err != .success {
            print("[DisplayService] Mode switch failed: \(err.rawValue)")
        }
    }
}
