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

        self.settings = settings

        // Fetch displays — this also verifies permission at runtime.
        // SCShareableContent is the true permission check; CGPreflight can be stale.
        await updateAvailableDisplays()

        guard let display = availableDisplays.first else {
            throw RecorderError.permissionRequired
        }

        print("🔍 Using display: \(display.width)x\(display.height)")

        // Create content filter
        let contentFilter: SCContentFilter
        if let customRect = settings.region.rect {
            // Custom region recording
            contentFilter = SCContentFilter(display: display, excludingWindows: [])
            print("🎯 Recording custom region: \(customRect)")
        } else {
            // Full screen recording
            contentFilter = SCContentFilter(display: display, excludingWindows: [])
            print("🎯 Recording full display: \(display.width)x\(display.height)")
        }

        // Configure stream
        let streamConfig = SCStreamConfiguration()

        // Determine recording dimensions and ensure they are valid for H.264 (even sizes).
        // Important: sourceRect is in points, width/height are in pixels.
        let backingScale = backingScaleFactor(for: display)
        let screenFramePoints = screenFrameInPoints(for: display)
        var captureRectPoints = settings.region.rect?.standardized

        if let rectPoints = captureRectPoints {
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

            captureRectPoints = evenRectPoints
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
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.rawValue))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = true

        // Audio configuration
        if settings.audioSettings.systemAudioEnabled {
            streamConfig.capturesAudio = true
            streamConfig.sampleRate = 44100
            streamConfig.channelCount = 2
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

        self.state = .recording(startTime: startTime, isPaused: true)
        print("⏸ Recording paused")
    }

    func resumeRecording() {
        guard case .recording(let startTime, true) = state else { return }

        // Resume video writer
        videoWriter?.resume()

        // Resume microphone capture
        micCaptureSession?.startRunning()

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
