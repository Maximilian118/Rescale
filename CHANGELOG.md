# Changelog

All notable changes to Rescale will be documented in this file.

## [0.3.0] - 2026-07-09

### Changed
- Resolution readout now shows the display's native panel resolution instead of the macOS logical mode, which changes during HiDPI mirroring

### Removed
- Removed `restoreNativeMode` — macOS constrains available modes within a mirror set, making post-mirror mode switching ineffective
- Removed `currentResolutionLabel` in favour of the fixed `nativeResolutionLabel`

## [0.2.0] - 2026-07-09

### Added
- Launch at login toggle — enable via the switch in the dropdown menu
- Persistent scale settings — saved per display and automatically restored on app launch
- Scale settings keyed by vendor/product ID so they survive display ID changes across reboots

## [0.1.0] - 2026-07-09

### Added
- Initial release
- UI Scale slider with 8 discrete steps (100%–200%) per external monitor
- Virtual HiDPI display creation via `CGVirtualDisplay` private API
- Physical display mirroring to virtual display for resolution-independent UI scaling
- DDC/CI brightness control for external monitors (Apple Silicon only)
- Per-display controls in a menu bar dropdown
- ICC color space matching between virtual and physical displays (primary extraction from ICC profile + `SLSSetDisplayColorSpace`)
- Gamma/transfer table copying between displays
- Display position pinning — built-in display and other monitors are never affected during scaling operations
- Automatic cleanup of virtual displays on app quit
- Display hotplug detection via `CGDisplayRegisterReconfigurationCallback`
