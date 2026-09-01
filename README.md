# Net Speed Monitor

A lightweight macOS utility that displays real-time network and disk speeds in
the menu bar and an optional always-on-top floating panel.

## Features

- Download, upload, disk-read, and disk-write indicators
- Independently selectable rates, with at least one always visible
- Borderless, resizable, always-on-top floating panel
- Bits/s and Bytes/s display modes
- Configurable refresh intervals: 1, 2, 3, 5, or 10 seconds
- Launch at login
- Persistent panel position, size, and display preferences
- Native support for Apple silicon and Intel Macs
- Self-contained traffic helper with no separate installation

## Requirements

- macOS 13.0 or later
- Xcode with the macOS SDK

## Build

Open `NetSpeedMonitor.xcodeproj` in Xcode and build the
`NetSpeedMonitor` scheme, or build a universal release from Terminal:

```bash
xcodebuild \
  -project NetSpeedMonitor.xcodeproj \
  -scheme NetSpeedMonitor \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build
```

The built application is located at:

```text
build/Build/Products/Release/Net Speed Monitor.app
```

To regenerate the Xcode project after editing `project.yml`, install
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and run:

```bash
xcodegen generate
```

## Usage

1. Launch **Net Speed Monitor**.
2. Click its menu-bar indicator and select **Settings**.
3. Choose the speed unit, refresh interval, launch-at-login behavior, and
   which displays should remain visible.
4. Drag the center of the floating panel to move it, or drag within 10 points
   of an edge to resize it.

The floating panel stays within the visible screen area. Double-clicking it
opens Settings.

## How It Works

The app bundles a universal `net-speed-all` helper. The helper reads per-flow
traffic data from macOS `nettop`, aggregates it by network interface, and reads
disk byte counters through IOKit. It streams newline-delimited JSON samples to
the app. All processing remains local to the Mac.
