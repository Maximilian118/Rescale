import SwiftUI

/// Per-display controls: UI scale slider and brightness.
struct MonitorCardView: View {
    @ObservedObject var monitor: Monitor

    @State private var scaleIndex: Double = 0
    @State private var brightness: Double = 100
    @State private var isReady = false
    @State private var isApplyingScale = false

    /// The discrete scale steps available for this display.
    private var steps: [ScaleStep] {
        monitor.scaleSteps
    }

    /// The currently selected scale step.
    private var currentStep: ScaleStep? {
        let idx = Int(scaleIndex.rounded())
        guard steps.indices.contains(idx) else { return nil }
        return steps[idx]
    }

    /// Scale percentage label (100% = native 1:1, 200% = 2× magnification).
    private var scalePercentage: Int {
        guard let step = currentStep else { return 100 }
        let ratio = Double(monitor.nativeWidth) / Double(step.logicalWidth)
        return Int((ratio * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Display name and native resolution header
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(monitor.currentResolutionLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // UI Scale slider
            if steps.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("UI Scale")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if isApplyingScale {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                        Text("\(scalePercentage)%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        // Large A = bigger UI (higher scale factor)
                        Image(systemName: "textformat.size.larger")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Slider(
                            value: $scaleIndex,
                            in: 0...Double(steps.count - 1),
                            step: 1
                        ) { editing in
                            // Only apply when the user releases the slider
                            if !editing {
                                applyScale()
                            }
                        }
                        .disabled(isApplyingScale)
                        // Small A = more space (native resolution)
                        Image(systemName: "textformat.size.smaller")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    // Show the logical resolution for the current step
                    if let step = currentStep {
                        Text("Looks like \(step.label)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Brightness slider — only shown when DDC is available
            if monitor.ddcAvailable {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Brightness")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(brightness))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $brightness, in: 0...100) { editing in
                        if !editing {
                            Task.detached { [displayID = monitor.displayID, brightness] in
                                BrightnessService.shared.setBrightness(brightness, for: displayID)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .task {
            syncFromMonitor()
            await monitor.refreshBrightness()
            brightness = monitor.brightness
            isReady = true
        }
    }

    // MARK: - Helpers

    /// Syncs slider position from the monitor's current virtual display state,
    /// or from saved settings if no virtual display is active yet.
    private func syncFromMonitor() {
        let service = VirtualDisplayService.shared
        if let activeWidth = service.currentLogicalWidth(for: monitor.displayID) {
            if let idx = steps.firstIndex(where: { $0.logicalWidth == activeWidth }) {
                scaleIndex = Double(idx)
                return
            }
        }
        // Check for a saved scale index from a previous session
        if let savedIdx = ScaleSettingsStore.loadScale(for: monitor.displayID),
           steps.indices.contains(savedIdx) {
            scaleIndex = Double(savedIdx)
            return
        }
        scaleIndex = 0
    }

    /// Applies the selected scale step via the virtual display service
    /// and saves the setting to UserDefaults for persistence across restarts.
    private func applyScale() {
        guard isReady, let step = currentStep else { return }

        let service = VirtualDisplayService.shared
        let idx = Int(scaleIndex.rounded())

        // Index 0 = native resolution, disable virtual display
        if idx == 0 {
            service.disableHiDPI(for: monitor.displayID)
            ScaleSettingsStore.removeScale(for: monitor.displayID)
            return
        }

        // Save the scale index for this display so it persists across restarts
        ScaleSettingsStore.saveScale(index: idx, for: monitor.displayID)

        isApplyingScale = true
        Task {
            await service.enableHiDPI(
                for: monitor.displayID,
                logicalWidth: step.logicalWidth,
                logicalHeight: step.logicalHeight
            )
            isApplyingScale = false
        }
    }
}
