//
//  ScreenRecorder.swift
//  OpenCapture
//
//  Core screen recording engine using ScreenCaptureKit
//

import ScreenCaptureKit
import AVFoundation
import Combine
import CoreMedia
import AppKit

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var availableDisplays: [SCDisplay] = []
    @Published var permissionGranted = false
    @Published var error: String?

    private var stream: SCStream?
    private var videoWriter: VideoWriter?
    private var streamOutput: StreamOutput?

    private var micCaptureSession: AVCaptureSession?
    private var micAudioOutput: AVCaptureAudioDataOutput?
    private var micAudioConnection: AVCaptureConnection?

    private var settings: RecordingSettings?
    private var recordingStartTime: Date?

    // MARK: - Window-Capture Mode State (display + dynamic sourceRect)

    /// A timestamped record of where the captured window's screen frame was
    /// during recording. Surface in `consumeWindowFrameEvents()` for the Pro
    /// layer to persist into RecordingMetadata.
    public struct WindowFrameEventInternal {
        public let timestamp: TimeInterval  // seconds since recordingStartTime (paused-duration-adjusted)
        public let frame: CGRect            // bottom-up screen points
    }

    private var windowCaptureWindowID: CGWindowID?
    private var windowCaptureDisplay: SCDisplay?
    private var windowCaptureBackingScale: CGFloat = 1.0
    private var windowCaptureBufferWidthPx: Int = 0
    private var windowCaptureBufferHeightPx: Int = 0
    private var windowCaptureLastAppliedFrame: CGRect = .zero
    private var windowCaptureBaseConfig: SCStreamConfiguration?
    private var windowFramePollTimer: Timer?
    private var windowFrameUpdateInFlight = false
    private var windowFrameEvents: [WindowFrameEventInternal] = []
    private let windowFrameEventsLock = NSLock()

    // MARK: - Initialization

    override init() {
        super.init()
        // Just check — don't trigger the permission prompt yet.
        // The prompt will appear when the user tries to start recording,
        // so the main window is already visible and centered.
        permissionGranted = CGPreflightScreenCaptureAccess()
        print("🔐 Screen recording permission on launch: \(permissionGranted)")
    }

    // MARK: - Permission & Display Management

    /// Quick permission check — tries to fetch displays via SCShareableContent.
    /// Returns true if at least one display is available (meaning permission is granted).
    func checkPermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let granted = !content.displays.isEmpty
            self.permissionGranted = granted
            return granted
        } catch {
            print("⚠️ Permission check failed: \(error)")
            return false
        }
    }

    /// Fetches available displays. Also serves as a runtime permission check
    /// since SCShareableContent returns displays only if access is granted.
    private func updateAvailableDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableDisplays = content.displays
            if !content.displays.isEmpty {
                self.permissionGranted = true
            }
            print("📺 Found \(content.displays.count) displays")
        } catch {
            print("⚠️ Error getting displays: \(error)")
        }
    }

    // MARK: - Display Helpers

    private func screenFrameInPoints(for display: SCDisplay) -> CGRect {
        guard let screen = screenForDisplay(display) else {
            return CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        }
        return screen.frame
    }

    private func backingScaleFactor(for display: SCDisplay) -> CGFloat {
        guard let screen = screenForDisplay(display) else { return 1.0 }
        return screen.backingScaleFactor
    }

    private func screenForDisplay(_ display: SCDisplay) -> NSScreen? {
        let displayID = display.displayID
        return NSScreen.screens.first { screen in
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return screenID == displayID
        }
    }

    // MARK: - Recording Control

    func startRecording(settings: RecordingSettings) async throws {
        guard state == .idle else {
            throw RecorderError.invalidState
        }

        // Reset window-capture state for the new session.
        windowCaptureWindowID = nil
        windowCaptureDisplay = nil
        windowCaptureBaseConfig = nil
        windowCaptureBufferWidthPx = 0
        windowCaptureBufferHeightPx = 0
        windowCaptureLastAppliedFrame = .zero
        windowFrameUpdateInFlight = false
        windowFrameEventsLock.lock()
        windowFrameEvents.removeAll()
        windowFrameEventsLock.unlock()

        // Fetch displays — this also verifies permission at runtime.
        // SCShareableContent is the true permission check; CGPreflight can be stale.
        await updateAvailableDisplays()

        guard let display = availableDisplays.first else {
            throw RecorderError.permissionRequired
        }

        // Resolve window-capture mode up front. If the user picked a window
        // that has since been closed, fall back gracefully to full screen
        // instead of failing hard.
        var workingSettings = settings
        var pickedWindow: SCWindow?
        if case .window(let windowID) = workingSettings.region {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let match = content.windows.first(where: { $0.windowID == windowID }) {
                    pickedWindow = match
                } else {
                    print("⚠️ Picked window \(windowID) is no longer available — falling back to full screen.")
                    workingSettings.region = .fullScreen
                }
            } catch {
                print("⚠️ Could not fetch shareable content for window capture (\(error)) — falling back to full screen.")
                workingSettings.region = .fullScreen
            }
        }

        self.settings = workingSettings

        print("🔍 Using display: \(display.width)x\(display.height)")

        // Resolve excluded windows (webcam PiP, recording overlay, etc.) so they
        // aren't baked into the screen capture. The IDs come from the Pro layer.
        var windowsToExclude: [SCWindow] = []
        if !workingSettings.excludedWindowIDs.isEmpty {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let idSet = Set(workingSettings.excludedWindowIDs)
                windowsToExclude = content.windows.filter { idSet.contains($0.windowID) }
                if !windowsToExclude.isEmpty {
                    print("🚫 Excluding \(windowsToExclude.count) windows from capture: \(windowsToExclude.map { $0.windowID })")
                }
            } catch {
                print("⚠️ Could not resolve excluded windows: \(error)")
            }
        }

        // Create content filter
        let contentFilter: SCContentFilter
        if let scWindow = pickedWindow {
            // Window capture via display + sourceRect (NOT desktopIndependentWindow).
            // Display capture delivers steady frames as long as anything on the
            // display changes (cursor counts), fixing the jerky playback inherent
            // to change-driven window capture. We track the window's frame in
            // real time and update sourceRect via SCStream.updateConfiguration.
            contentFilter = SCContentFilter(display: display, excludingWindows: windowsToExclude)
            let f = scWindow.frame
            let title = scWindow.title ?? ""
            let appName = scWindow.owningApplication?.applicationName ?? "?"
            print("🎯 Recording window \(scWindow.windowID) \"\(title)\" (\(appName)): \(Int(f.width))x\(Int(f.height)) pts (via display+sourceRect)")
        } else if let customRect = workingSettings.region.rect {
            // Custom region recording
            contentFilter = SCContentFilter(display: display, excludingWindows: windowsToExclude)
            print("🎯 Recording custom region: \(customRect)")
        } else {
            // Full screen recording
            contentFilter = SCContentFilter(display: display, excludingWindows: windowsToExclude)
            print("🎯 Recording full display: \(display.width)x\(display.height)")
        }

        // Configure stream
        let streamConfig = SCStreamConfiguration()

        // Determine recording dimensions and ensure they are valid for H.264 (even sizes).
        // Important: sourceRect is in points, width/height are in pixels.
        let backingScale = backingScaleFactor(for: display)
        let screenFramePoints = screenFrameInPoints(for: display)

        if let scWindow = pickedWindow {
            // Display + sourceRect window-capture path.
            // - sourceRect: window's screen frame (top-down POINTS), clamped to display.
            //   IMPORTANT: SCDisplay.width/height is in POINTS, not pixels.
            // - width/height: output buffer in PIXELS, fixed at the initial window
            //   pixel dimensions (no growth-headroom multiplier). On resize/move
            //   the sourceRect changes but the buffer stays — content is letterboxed
            //   inside the buffer via scalesToFit when aspect differs.
            let displayRectPts = CGRect(
                x: 0, y: 0,
                width: CGFloat(display.width),       // SCDisplay is points
                height: CGFloat(display.height)
            )
            let initialSourceRect = scWindow.frame.intersection(displayRectPts)
            let initialPxW = max(2, Int((initialSourceRect.width * backingScale).rounded(.down)))
            let initialPxH = max(2, Int((initialSourceRect.height * backingScale).rounded(.down)))
            // Lock buffer at the initial pixel size — sourceRect can change to
            // any sub-region; SCK will scale-to-fit. No upscaling artifacts since
            // the window's content quality matches its captured pixels exactly.
            let evenPixelWidth = (initialPxW / 2) * 2
            let evenPixelHeight = (initialPxH / 2) * 2

            streamConfig.sourceRect = initialSourceRect
            streamConfig.width = evenPixelWidth
            streamConfig.height = evenPixelHeight
            if #available(macOS 14.0, *) {
                streamConfig.scalesToFit = true  // letterbox aspect mismatch inside the buffer
            }

            // Cache for the window-frame polling loop
            self.windowCaptureWindowID = scWindow.windowID
            self.windowCaptureDisplay = display
            self.windowCaptureBackingScale = backingScale
            self.windowCaptureBufferWidthPx = evenPixelWidth
            self.windowCaptureBufferHeightPx = evenPixelHeight
            self.windowCaptureLastAppliedFrame = initialSourceRect

            print("🎯 Window capture buffer (pixels): \(evenPixelWidth)x\(evenPixelHeight), initial sourceRect: \(initialSourceRect), scale: \(backingScale)")
        } else if let rectPoints = workingSettings.region.rect?.standardized {
            // Clamp to screen bounds (points)
            let clampedPoints = rectPoints.intersection(screenFramePoints)

            // Convert to pixels, coerce to even dimensions
            let pixelWidth = max(2, Int((clampedPoints.width * backingScale).rounded(.down)))
            let pixelHeight = max(2, Int((clampedPoints.height * backingScale).rounded(.down)))
            let evenPixelWidth = (pixelWidth / 2) * 2
            let evenPixelHeight = (pixelHeight / 2) * 2

            // Convert back to points so sourceRect matches pixel size
            let evenWidthPoints = CGFloat(evenPixelWidth) / backingScale
            let evenHeightPoints = CGFloat(evenPixelHeight) / backingScale

            let evenRectPoints = CGRect(
                x: clampedPoints.minX.rounded(.down),
                y: clampedPoints.minY.rounded(.down),
                width: max(2, evenWidthPoints),
                height: max(2, evenHeightPoints)
            )

            streamConfig.sourceRect = evenRectPoints
            streamConfig.width = evenPixelWidth
            streamConfig.height = evenPixelHeight
            print("🎯 Normalized capture rect (points): \(evenRectPoints)")
            print("🎯 Capture size (pixels): \(evenPixelWidth)x\(evenPixelHeight), scale: \(backingScale)")
        } else {
            // Full display - use display's pixel size (already in pixels)
            let evenWidth = (Int(display.width) / 2) * 2
            let evenHeight = (Int(display.height) / 2) * 2
            streamConfig.width = evenWidth
            streamConfig.height = evenHeight

            if evenWidth != display.width || evenHeight != display.height {
                let evenRect = CGRect(x: 0, y: 0, width: CGFloat(evenWidth) / backingScale, height: CGFloat(evenHeight) / backingScale)
                streamConfig.sourceRect = evenRect
                print("🎯 Adjusted full-screen capture rect to even size (points): \(evenRect)")
            }
            print("🎯 Full-screen capture size (pixels): \(evenWidth)x\(evenHeight), scale: \(backingScale)")
        }
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(workingSettings.frameRate.rawValue))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = true
        streamConfig.queueDepth = 8  // absorb compositor stalls; default 3 is tight under load

        // Audio configuration
        if settings.audioSettings.systemAudioEnabled {
            streamConfig.capturesAudio = true
            streamConfig.sampleRate = 44100
            streamConfig.channelCount = 2
        }

        // Window-capture mode: cache the base config for the polling loop.
        // updateConfiguration replaces the entire config, so we need all fields handy.
        if pickedWindow != nil {
            self.windowCaptureBaseConfig = streamConfig
        }

        // Create video writer
        let writer = try VideoWriter(
            outputURL: settings.outputURL,
            width: streamConfig.width,
            height: streamConfig.height,
            frameRate: settings.frameRate.rawValue,
            bitrate: settings.quality.bitrate
        )
        try writer.startWriting()
        self.videoWriter = writer

        // Create stream
        let stream = SCStream(filter: contentFilter, configuration: streamConfig, delegate: self)

        // Create and add stream output handler
        let output = StreamOutput(videoWriter: writer)
        self.streamOutput = output

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

            if settings.audioSettings.systemAudioEnabled {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            }

            try await stream.startCapture()

            // Start microphone capture separately using AVCaptureSession
            if settings.audioSettings.microphoneEnabled {
                startMicrophoneCapture(output: output, deviceID: settings.audioSettings.selectedMicrophoneID, gain: settings.audioSettings.micInputGain)
            }

            self.stream = stream
            self.recordingStartTime = Date()
            self.state = .recording(startTime: Date(), isPaused: false)

            // Start the window-frame polling loop for window-capture mode.
            // No-op when windowCaptureWindowID is nil.
            self.startWindowFramePolling()

            print("✅ Recording started")
            print("   Output: \(settings.outputURL.path)")
            print("   Resolution: \(streamConfig.width)x\(streamConfig.height)")
            print("   Frame rate: \(settings.frameRate.rawValue) FPS")
            print("   Quality: \(settings.quality.rawValue)")
            print("   Microphone: \(settings.audioSettings.microphoneEnabled)")
            print("   System audio: \(settings.audioSettings.systemAudioEnabled)")

        } catch {
            writer.cancelWriting()
            throw RecorderError.failedToStartCapture(error)
        }
    }

    func pauseRecording() {
        guard case .recording(let startTime, false) = state else { return }

        // Pause video writer (drops incoming buffers + tracks paused duration)
        videoWriter?.pause()

        // Pause microphone capture
        micCaptureSession?.stopRunning()

        // Pause window-frame polling so we don't issue updateConfiguration
        // while paused (no frames in flight to apply against).
        stopWindowFramePolling()

        self.state = .recording(startTime: startTime, isPaused: true)
        print("⏸ Recording paused")
    }

    func resumeRecording() {
        guard case .recording(let startTime, true) = state else { return }

        // Resume video writer
        videoWriter?.resume()

        // Resume microphone capture
        micCaptureSession?.startRunning()

        // Resume window-frame polling
        startWindowFramePolling()

        self.state = .recording(startTime: startTime, isPaused: false)
        print("▶️ Recording resumed")
    }

    func togglePause() {
        if state.isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    func stopRecording() async throws {
        guard case .recording = state else {
            throw RecorderError.invalidState
        }

        guard let stream = stream, let writer = videoWriter else {
            throw RecorderError.notRecording
        }

        // Stop the window-frame polling loop (no-op outside window-capture mode)
        stopWindowFramePolling()

        // Stop microphone capture
        stopMicrophoneCapture()

        // Stop screen capture
        do {
            try await stream.stopCapture()
        } catch {
            print("⚠️ Error stopping capture: \(error)")
        }

        // Finalize video file
        await withCheckedContinuation { continuation in
            writer.finishWriting { result in
                switch result {
                case .success(let url):
                    print("✅ Recording stopped and saved to: \(url.path)")
                case .failure(let error):
                    print("❌ Error finalizing recording: \(error)")
                }
                continuation.resume()
            }
        }

        // Cleanup
        self.stream = nil
        self.videoWriter = nil
        self.streamOutput = nil
        self.state = .idle
    }

    func cancelRecording() async {
        guard case .recording = state else { return }

        stopWindowFramePolling()
        stopMicrophoneCapture()

        if let stream = stream {
            try? await stream.stopCapture()
        }

        videoWriter?.cancelWriting()

        self.stream = nil
        self.videoWriter = nil
        self.streamOutput = nil
        self.state = .idle

        print("❌ Recording cancelled")
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture(output: StreamOutput, deviceID: String?, gain: Float = 0.75) {
        let session = AVCaptureSession()
        session.beginConfiguration()

        // Find the microphone device
        let micDevice: AVCaptureDevice?
        if let deviceID = deviceID {
            micDevice = AVCaptureDevice(uniqueID: deviceID)
        } else {
            micDevice = AVCaptureDevice.default(for: .audio)
        }

        guard let mic = micDevice else {
            print("⚠️ No microphone device found")
            return
        }

        do {
            let micInput = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(micInput) else {
                print("⚠️ Cannot add microphone input to capture session")
                return
            }
            session.addInput(micInput)

            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(output, queue: .global(qos: .userInteractive))
            guard session.canAddOutput(audioOutput) else {
                print("⚠️ Cannot add audio output to capture session")
                return
            }
            session.addOutput(audioOutput)

            session.commitConfiguration()

            // Apply mic input gain via audio connection volume
            if let connection = audioOutput.connection(with: .audio) {
                for channel in connection.audioChannels {
                    channel.volume = gain
                }
                self.micAudioConnection = connection
            }

            session.startRunning()

            self.micCaptureSession = session
            self.micAudioOutput = audioOutput

            print("🎤 Microphone capture started: \(mic.localizedName), gain: \(gain)")
        } catch {
            print("❌ Failed to start microphone capture: \(error)")
        }
    }

    func updateMicGain(_ gain: Float) {
        guard let connection = micAudioConnection else { return }
        for channel in connection.audioChannels {
            channel.volume = gain
        }
    }

    private var savedMicGain: Float = 0.75

    func muteMicrophone() {
        guard let connection = micAudioConnection else { return }
        // Save current gain before muting
        savedMicGain = connection.audioChannels.first?.volume ?? 0.75
        for channel in connection.audioChannels {
            channel.volume = 0
        }
    }

    func unmuteMicrophone() {
        guard let connection = micAudioConnection else { return }
        for channel in connection.audioChannels {
            channel.volume = savedMicGain
        }
    }

    private func stopMicrophoneCapture() {
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micAudioOutput = nil
        micAudioConnection = nil
    }

    // MARK: - Window-Capture Polling (dynamic sourceRect)

    /// Starts polling the captured window's screen frame at 15 Hz and updating
    /// the SCStream's sourceRect when it changes. No-op outside window-capture mode.
    private func startWindowFramePolling() {
        guard windowCaptureWindowID != nil else { return }
        windowFramePollTimer?.invalidate()
        windowFramePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollWindowFrame() }
        }
    }

    /// Tears down the window-frame polling Timer.
    private func stopWindowFramePolling() {
        windowFramePollTimer?.invalidate()
        windowFramePollTimer = nil
    }

    /// Reads the current window frame via CGWindowList (fast, synchronous) and
    /// triggers an updateConfiguration when it differs > 0.5 pt from last applied.
    @MainActor
    private func pollWindowFrame() {
        guard let stream = self.stream,
              let windowID = self.windowCaptureWindowID,
              !self.windowFrameUpdateInFlight,
              !(self.videoWriter?.isPaused ?? true) else { return }

        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let first = info.first,
              let bounds = first[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"],
              w > 0, h > 0
        else { return }

        let topDown = CGRect(x: x, y: y, width: w, height: h)
        let last = self.windowCaptureLastAppliedFrame
        if abs(topDown.minX - last.minX) < 0.5,
           abs(topDown.minY - last.minY) < 0.5,
           abs(topDown.width - last.width) < 0.5,
           abs(topDown.height - last.height) < 0.5 { return }

        self.applyWindowFrameUpdate(topDownFrame: topDown, stream: stream)
    }

    /// Issues SCStream.updateConfiguration with the new sourceRect. Logs the
    /// applied frame as a time-series event on success (paused-adjusted timestamp).
    @MainActor
    private func applyWindowFrameUpdate(topDownFrame: CGRect, stream: SCStream) {
        guard let display = windowCaptureDisplay,
              let base = windowCaptureBaseConfig else { return }

        let displayRect = CGRect(
            x: 0, y: 0,
            width: CGFloat(display.width) / windowCaptureBackingScale,
            height: CGFloat(display.height) / windowCaptureBackingScale
        )
        let clamped = topDownFrame.intersection(displayRect)
        guard !clamped.isEmpty, clamped.width >= 2, clamped.height >= 2 else { return }

        // updateConfiguration replaces the entire config — clone the base and
        // only modify sourceRect. width/height MUST stay fixed (encoder locked).
        let newConfig = SCStreamConfiguration()
        newConfig.sourceRect = clamped
        newConfig.width = windowCaptureBufferWidthPx
        newConfig.height = windowCaptureBufferHeightPx
        newConfig.minimumFrameInterval = base.minimumFrameInterval
        newConfig.pixelFormat = base.pixelFormat
        newConfig.showsCursor = base.showsCursor
        newConfig.capturesAudio = base.capturesAudio
        newConfig.sampleRate = base.sampleRate
        newConfig.channelCount = base.channelCount
        newConfig.queueDepth = base.queueDepth
        if #available(macOS 14.0, *) { newConfig.scalesToFit = true }

        windowFrameUpdateInFlight = true
        stream.updateConfiguration(newConfig) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.windowFrameUpdateInFlight = false
                if let error {
                    print("⚠️ SCStream.updateConfiguration failed: \(error.localizedDescription)")
                    return
                }
                self.windowCaptureLastAppliedFrame = topDownFrame

                // Stamp the event with the paused-duration-adjusted timestamp.
                guard let start = self.recordingStartTime else { return }
                let elapsed = Date().timeIntervalSince(start)
                let pausedSec = self.videoWriter?.totalPausedSeconds ?? 0
                let adjustedTimestamp = max(0, elapsed - pausedSec)

                // Convert top-down → bottom-up for the Pro layer's compositor.
                let displayH = CGFloat(display.height) / self.windowCaptureBackingScale
                let bottomUp = CGRect(
                    x: topDownFrame.origin.x,
                    y: displayH - topDownFrame.origin.y - topDownFrame.size.height,
                    width: topDownFrame.size.width,
                    height: topDownFrame.size.height
                )

                self.windowFrameEventsLock.lock()
                self.windowFrameEvents.append(WindowFrameEventInternal(
                    timestamp: adjustedTimestamp,
                    frame: bottomUp
                ))
                self.windowFrameEventsLock.unlock()
            }
        }
    }

    /// Drains the collected window-frame events. Called by the Pro layer after
    /// stopRecording so they can be persisted into RecordingMetadata.
    func consumeWindowFrameEvents() -> [WindowFrameEventInternal] {
        windowFrameEventsLock.lock()
        defer { windowFrameEventsLock.unlock() }
        let events = windowFrameEvents
        windowFrameEvents = []
        return events
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.error = error.localizedDescription
            self.state = .error(error.localizedDescription)
        }
    }
}

// MARK: - Stream Output Handler

private class StreamOutput: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    let videoWriter: VideoWriter

    init(videoWriter: VideoWriter) {
        self.videoWriter = videoWriter
        super.init()
    }

    private var frameCount = 0
    private var audioSampleCount = 0
    private var micSampleCount = 0

    // MARK: - SCStreamOutput (screen + system audio)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            frameCount += 1
            if frameCount == 1 {
                print("🎬 First video frame captured!")
            } else if frameCount % 60 == 0 {
                print("📹 Captured \(frameCount) video frames...")
            }
            videoWriter.appendVideoBuffer(sampleBuffer)

        case .audio:
            audioSampleCount += 1
            if audioSampleCount == 1 {
                print("🔊 First system audio sample captured!")
            }
            videoWriter.appendAudioBuffer(sampleBuffer)

        case .microphone:
            videoWriter.appendAudioBuffer(sampleBuffer)

        @unknown default:
            break
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (microphone)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }

        micSampleCount += 1
        if micSampleCount == 1 {
            print("🎤 First microphone sample captured!")
        }
        videoWriter.appendAudioBuffer(sampleBuffer)
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case invalidState
    case noDisplayAvailable
    case notRecording
    case permissionRequired
    case failedToStartCapture(Error)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Invalid recorder state"
        case .noDisplayAvailable:
            return "No display available for recording"
        case .permissionRequired:
            return "Screen recording permission required"
        case .notRecording:
            return "Not currently recording"
        case .failedToStartCapture(let error):
            return "Failed to start capture: \(error.localizedDescription)"
        }
    }
}
