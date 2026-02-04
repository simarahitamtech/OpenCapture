# OpenCapture

**Open source screen recording for Mac. No cloud, no subscriptions, no hostage-taking.**

A native macOS screen recorder built with SwiftUI and ScreenCaptureKit. Your recordings write directly to disk from the first frame — if the app crashes, your file is still playable. No "processing", no "exporting", no paywalls.

## Features

**Screen Recording**
- Full screen or custom region capture
- Region selection with live pixel dimensions
- 24 / 30 / 60 FPS
- Quality presets: High (8 Mbps), Medium (4 Mbps), Low (2 Mbps)
- H.264 hardware-accelerated encoding
- Pause and resume with full A/V sync

**Audio**
- Microphone input with device selection
- Mic volume slider with real-time level meter
- System audio capture
- Mute/unmute mic during recording

**Webcam**
- Floating circular webcam overlay (Picture-in-Picture)
- Camera device selection
- Draggable — reposition anywhere on screen
- Toggle on/off during recording

**Annotation**
- Draw on screen during recording
- Multiple colors (red, blue, green, yellow, white)
- Adjustable line thickness
- Clear all annotations instantly

**Keyboard Shortcuts**

| Shortcut | Action |
|----------|--------|
| `⇧⌘R` | Start / Stop Recording |
| `⇧⌘P` | Pause / Resume |
| `⇧⌘A` | Toggle Annotation |
| `⇧⌘D` | Clear Annotations |
| `⇧⌘V` | Toggle Webcam |
| `⇧⌘M` | Toggle Microphone |
| `Esc` | Cancel Recording |

All shortcuts work globally — even when the app is in the background.

## Install

### Download (pre-built)

1. Download the latest `.dmg` from [Releases](https://github.com/simarahitamtech/OpenCapture/releases)
2. Open the `.dmg` and drag **OpenCapture** to your **Applications** folder
3. Run this command in Terminal to clear the macOS quarantine flag:

```bash
xattr -cr /Applications/OpenCapture.app
```

4. Open OpenCapture from Applications

> **Why step 3?** macOS Gatekeeper blocks apps that aren't signed with an Apple Developer certificate. This is standard for open source Mac apps distributed outside the App Store. The `xattr -cr` command removes the quarantine flag.

### Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon (arm64) for the pre-built `.dmg`
- Xcode 15+ (only if building from source)
- No external dependencies

## Building from Source

Building from source avoids the Gatekeeper issue entirely.

### Using Swift Package Manager

```bash
git clone https://github.com/simarahitamtech/OpenCapture.git
cd OpenCapture
swift build -c release
swift run
```

### Using Xcode

1. Open the project folder in Xcode 15+
2. Select the **OpenCapture** scheme
3. **Product > Run** (`⌘R`)

## Project Structure

```
SimaraRecord/Sources/
├── App/
│   ├── SimaraRecordApp.swift     # Entry point, AppDelegate, menu bar
│   ├── Info.plist                # Permissions & bundle config
│   └── AppIcon.icns             # App icon
├── Core/
│   ├── ScreenRecorder.swift     # ScreenCaptureKit capture engine
│   ├── VideoWriter.swift        # Incremental MP4 file writer
│   ├── AudioManager.swift       # Mic device discovery & levels
│   ├── WebcamManager.swift      # Camera device discovery & capture
│   └── HotkeyManager.swift     # Global keyboard shortcuts
├── Models/
│   └── RecordingSettings.swift  # Recording configuration types
└── Views/
    ├── MainWindow.swift         # Main control panel UI
    ├── RecordingOverlay.swift   # Floating timer & controls
    ├── RegionSelector.swift     # Custom region selection
    ├── AnnotationOverlay.swift  # On-screen drawing
    └── WebcamOverlay.swift      # Webcam PiP window
```

## How It Works

### Direct-to-Disk Recording

Most screen recorders buffer your entire recording in memory, then hold it hostage until you "export" (often behind a paywall). OpenCapture writes directly to your chosen file:

```swift
// VideoWriter.swift — fragmented MP4 makes the file playable during recording
writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
```

The recording is playable from the first second. If the app crashes, you lose at most one second of footage.

### Architecture

- **ScreenCaptureKit** — hardware-accelerated screen capture
- **AVFoundation** — H.264 encoding and file writing
- **AVCaptureSession** — microphone and webcam capture
- **SwiftUI + AppKit** — native macOS UI
- **NSEvent monitors** — global keyboard shortcuts

Zero third-party dependencies. Pure Apple frameworks.

## Permissions

OpenCapture requests permissions as needed (never in advance):

| Permission | When | Required |
|------------|------|----------|
| Screen Recording | First time you click Start | Yes |
| Microphone | When you enable mic | Only if recording audio |
| Camera | When you enable webcam | Only if using webcam |
| Accessibility | For global hotkeys | Recommended |

Manage permissions in **System Settings > Privacy & Security**.

## Known Limitations

- Mic toggle during recording only works if mic was enabled before recording started (mute/unmute). Starting mic capture mid-recording is not yet supported.
- System audio capture requires macOS 13+.
- The project folder is named `SimaraRecord` (the original name) while the app is `OpenCapture`. This is cosmetic and doesn't affect functionality.

## Contributing

Contributions are welcome. Fork, make your changes, and open a pull request.

```bash
# Development setup
xcode-select --install
git clone https://github.com/simarahitamtech/OpenCapture.git
cd OpenCapture
swift build
```

## License

MIT License — see [LICENSE](LICENSE) for details.

---

**Built with SwiftUI, ScreenCaptureKit, and zero third-party dependencies.**
