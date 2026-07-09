# Rescale

A macOS menu bar app that **scales UI elements on external monitors without changing display resolution**.

## Why This Exists

macOS doesn't offer independent UI element scaling on external monitors. The "More Space" and "Less Space" options in System Settings actually change the resolution the display receives — a high-resolution monitor ends up running at a lower resolution with everything looking blurry.

Running at native resolution makes the UI too small to read on many high-DPI panels. Scaling down means the display isn't running at its full resolution. There's no middle ground.

Rescale fixes this.

## What It Does

Rescale keeps external monitors at their **full native resolution** while making UI elements (text, menu bar, window chrome, buttons) larger or smaller. The display always outputs at its maximum pixel count — only the logical rendering size changes.

## How It Works (Technical)

Rescale uses macOS's private `CGVirtualDisplay` API to create a virtual HiDPI display, then configures the physical monitor to mirror it:

1. **Creates a virtual display** at the chosen logical resolution with HiDPI (2×) backing — e.g., 3658×1542 logical with a 7316×3084 backing store
2. **Mirrors the physical monitor** to the virtual display using `CGConfigureDisplayMirrorOfDisplay` — macOS renders UI at the virtual display's logical resolution
3. **The monitor stays at native resolution** — macOS composites the HiDPI-rendered content onto the display's native pixel grid
4. **Protects other displays** — the built-in display and any other monitors are explicitly pinned to their current positions and states in every configuration transaction

The result: macOS renders UI as if the display were a lower resolution (bigger elements), but the monitor receives a full-resolution signal.

### Color Matching

When mirroring is active, macOS composites through the virtual display's color pipeline. Rescale mitigates color differences by:

- Extracting the physical display's ICC color primaries (rXYZ/gXYZ/bXYZ/wtpt tags) and applying them to the virtual display descriptor
- Copying the full ICC color space via `SLSSetDisplayColorSpace` (SkyLight private API)
- Copying the gamma/transfer table via `CGSetDisplayTransferByTable`
- Re-applying color matching multiple times after mirror setup to handle system overrides

Note: macOS's internal mirror compositing pipeline may still introduce subtle color differences. ICC profiles and gamma tables are verified to match byte-for-byte, but the compositor's rendering path can cause slight desaturation on wide-gamut displays.

## Features

- **UI Scale slider** — 8 discrete steps from 100% (native) to 200% (2× magnification)
- **Brightness control** — DDC/CI brightness via IOAVService (Apple Silicon only)
- **Per-display controls** — each external monitor gets its own independent card
- **Display protection** — built-in display is never touched during any operation
- **Clean teardown** — virtual displays are destroyed on quit, restoring original configuration

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon** recommended (DDC brightness requires it; UI scaling works on Intel)
- **XcodeGen** for project generation
- **Xcode 15+** for building

## Building

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -project Rescale.xcodeproj -scheme Rescale build

# Or open in Xcode
open Rescale.xcodeproj
```

The built app will be at:
```
~/Library/Developer/Xcode/DerivedData/Rescale-*/Build/Products/Debug/Rescale.app
```

## Usage

1. Build and launch `Rescale.app` — a display icon appears in the menu bar
2. Click the icon to see connected external monitors
3. Drag the **UI Scale** slider to adjust UI element size
4. Slide left for larger UI, right for more screen space
5. The change takes a moment to apply while the virtual display is created

## Project Structure

```
Rescale/
├── project.yml                      # XcodeGen project definition
├── Rescale/
│   ├── App/
│   │   └── RescaleApp.swift         # @main entry point, menu bar setup
│   ├── Models/
│   │   └── Monitor.swift            # Display model, scale step generation
│   ├── Views/
│   │   ├── ContentView.swift        # Monitor list, quit button
│   │   └── MonitorCardView.swift    # UI scale slider, brightness slider
│   ├── Services/
│   │   ├── DisplayService.swift     # Display enumeration, hotplug events
│   │   ├── VirtualDisplayService.swift  # Virtual display lifecycle, mirroring, color matching
│   │   └── BrightnessService.swift  # DDC/CI brightness over IOAVService
│   ├── Rescale-Bridging-Header.h    # CGVirtualDisplay + IOAVService declarations
│   ├── Rescale.entitlements
│   └── Assets.xcassets/
├── CHANGELOG.md
└── README.md
```

## Private APIs

| API | Framework | Purpose |
|-----|-----------|---------|
| `CGVirtualDisplay` | CoreGraphics | Creates virtual displays with HiDPI backing stores |
| `CGConfigureDisplayMirrorOfDisplay` | CoreGraphics | Mirrors physical display to virtual display |
| `SLSSetDisplayColorSpace` | SkyLight | Copies ICC color profile to match physical display |
| `IOAVServiceRef` | IOKit | DDC/CI brightness control over DisplayPort (Apple Silicon) |

This app cannot be distributed via the Mac App Store due to private API usage.

## Known Limitations

- **Color fidelity** — macOS's mirror compositing pipeline may introduce subtle color desaturation on wide-gamut displays, despite ICC and gamma table matching
- **Variable refresh rate** — VRR (48-165Hz) is enabled on the external monitor during mirroring. This is functionally identical to fixed high refresh during active use (mouse movement, gaming, video) and saves power at idle
- **Backing store size** — Virtual displays with backing stores wider than ~8000px may fail on some hardware due to DCP firmware limits
- **App must stay running** — the virtual display is destroyed when the app quits, restoring the original display configuration

## License

MIT
