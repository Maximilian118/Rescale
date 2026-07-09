# Rescale

A macOS menu bar app that **scales UI elements on external monitors without changing display resolution**.

## The Problem

When using a high-resolution external monitor with a Mac, everything on screen can be tiny — text, buttons, the menu bar, browser content. macOS offers "More Space" and "Less Space" options in Display settings, but these actually lower the resolution sent to the monitor, making everything blurry.

Rescale fixes this. It keeps the monitor running at its full resolution while making everything on screen bigger or smaller — the way scaling should work.

## Installation

### Download (Recommended)

1. Download **[Rescale-v0.2.0-macOS.zip](https://github.com/Maximilian118/Rescale/releases/latest)** from the Releases page
2. Unzip it
3. Drag **Rescale.app** to the **Applications** folder
4. **Right-click** the app → click **Open** (required the first time — macOS blocks unsigned apps by default)
5. A display icon appears in the menu bar — click it to get started

> **Note:** If macOS shows "Apple cannot check it for malicious software", go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

### Build from Source

For developers who want to build from source or contribute:

<details>
<summary>Click to expand build instructions</summary>

#### Prerequisites

1. Install Xcode Command Line Tools:
   ```
   xcode-select --install
   ```

2. Accept the Xcode license:
   ```
   sudo xcodebuild -license accept
   ```

3. Install [Homebrew](https://brew.sh) (if not already installed):
   ```
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

4. Install XcodeGen:
   ```
   brew install xcodegen
   ```

#### Build and Run

```bash
git clone https://github.com/Maximilian118/Rescale.git
cd Rescale
xcodegen generate
xcodebuild -project Rescale.xcodeproj -scheme Rescale -configuration Release build
```

The built app will be at:
```
~/Library/Developer/Xcode/DerivedData/Rescale-*/Build/Products/Release/Rescale.app
```

Copy it to Applications:
```
cp -r ~/Library/Developer/Xcode/DerivedData/Rescale-*/Build/Products/Release/Rescale.app /Applications/
```

</details>

## How to Use

1. Click the **display icon** in the menu bar
2. Each connected external monitor appears as a card
3. Drag the **UI Scale** slider:
   - Slide **left** for larger text and UI elements
   - Slide **right** for more screen space (smaller UI)
4. The monitor will briefly go black while the new scale is applied — this is normal
5. **Brightness** can also be adjusted if the monitor supports DDC (most modern monitors over DisplayPort/USB-C on Apple Silicon Macs)

The app must stay running for the scaling to remain active. Quitting the app restores the monitor to its original settings.

## Features

- **UI Scale slider** — 8 steps from 100% (native) to 200% (2x magnification)
- **Brightness control** — hardware brightness adjustment for external monitors (Apple Silicon only)
- **Per-display controls** — each external monitor gets its own independent settings
- **Non-destructive** — quitting the app restores everything to normal

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon Mac** recommended (brightness control requires it; UI scaling works on Intel too)

## Known Limitations

- **Slight color shift** — the scaling method may introduce subtle color differences on wide-gamut monitors. The app matches color profiles and gamma tables as closely as possible, but macOS's internal rendering can cause slight desaturation
- **Variable refresh rate** — the monitor switches to variable refresh (e.g., 48–165Hz) while scaling is active. This has no visible impact during normal use — the display still runs at its maximum refresh rate during mouse movement, scrolling, video, and gaming. It only drops the refresh rate when nothing on screen is changing, which saves power
- **App must stay running** — closing Rescale restores the original display configuration
- **Very large monitors** — displays wider than ~8000 pixels at 2x backing may not work on some hardware

---

## Technical Details

<details>
<summary>Click to expand for developers</summary>

### How It Works

Rescale uses macOS's private `CGVirtualDisplay` API to create a virtual HiDPI display, then configures the physical monitor to mirror it:

1. **Creates a virtual display** at the chosen logical resolution with HiDPI (2x) backing — e.g., 3658x1542 logical with a 7316x3084 backing store
2. **Mirrors the physical monitor** to the virtual display using `CGConfigureDisplayMirrorOfDisplay` — macOS renders UI at the virtual display's logical resolution
3. **The monitor stays at native resolution** — macOS composites the HiDPI-rendered content onto the display's native pixel grid
4. **Protects other displays** — the built-in display and any other monitors are explicitly pinned to their current positions and states in every configuration transaction

### Color Matching

When mirroring is active, macOS composites through the virtual display's color pipeline. Rescale mitigates color differences by:

- Extracting the physical display's ICC color primaries (rXYZ/gXYZ/bXYZ/wtpt tags) and applying them to the virtual display descriptor
- Copying the full ICC color space via `SLSSetDisplayColorSpace` (SkyLight private API)
- Copying the gamma/transfer table via `CGSetDisplayTransferByTable`
- Re-applying color matching multiple times after mirror setup to handle system overrides

### Private APIs Used

| API | Framework | Purpose |
|-----|-----------|---------|
| `CGVirtualDisplay` | CoreGraphics | Creates virtual displays with HiDPI backing stores |
| `CGConfigureDisplayMirrorOfDisplay` | CoreGraphics | Mirrors physical display to virtual display |
| `SLSSetDisplayColorSpace` | SkyLight | Copies ICC color profile to match physical display |
| `IOAVServiceRef` | IOKit | DDC/CI brightness control over DisplayPort (Apple Silicon) |

This app cannot be distributed via the Mac App Store due to private API usage.

### Project Structure

```
Rescale/
├── project.yml                          # XcodeGen project definition
├── Rescale/
│   ├── App/
│   │   └── RescaleApp.swift             # @main entry point, menu bar setup
│   ├── Models/
│   │   └── Monitor.swift                # Display model, scale step generation
│   ├── Views/
│   │   ├── ContentView.swift            # Monitor list, quit button
│   │   └── MonitorCardView.swift        # UI scale slider, brightness slider
│   ├── Services/
│   │   ├── DisplayService.swift         # Display enumeration, hotplug events
│   │   ├── VirtualDisplayService.swift  # Virtual display lifecycle, mirroring, color matching
│   │   └── BrightnessService.swift      # DDC/CI brightness over IOAVService
│   ├── Rescale-Bridging-Header.h        # CGVirtualDisplay + IOAVService declarations
│   ├── Rescale.entitlements
│   └── Assets.xcassets/
├── CHANGELOG.md
└── README.md
```

### Building (Developer Quick Start)

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Rescale.xcodeproj -scheme Rescale build
```

</details>

## License

MIT
