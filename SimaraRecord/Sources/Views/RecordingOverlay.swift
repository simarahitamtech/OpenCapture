//
//  RecordingOverlay.swift
//  OpenCapture
//
//  Floating overlay shown during recording, countdown, and region border
//

import SwiftUI
import AppKit

// MARK: - Shared toggle state for overlay updates

class OverlayToggleState: ObservableObject {
    @Published var micEnabled: Bool = false
    @Published var webcamEnabled: Bool = false
    @Published var teleprompterEnabled: Bool = false
    @Published var backgroundBlurEnabled: Bool = false
}

// MARK: - Recording Overlay (timer + stop button)

struct RecordingOverlay: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var toggleState: OverlayToggleState
    let onPause: () -> Void
    let onAnnotate: () -> Void
    let onToggleWebcam: (() -> Void)?
    let onToggleMic: (() -> Void)?
    let onToggleTeleprompter: (() -> Void)?
    let onToggleBackgroundBlur: (() -> Void)?
    let onStop: () -> Void

    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isBlinking = false
    @State private var pausedAccumulated: TimeInterval = 0
    @State private var pauseStartedAt: Date?

    var body: some View {
        VStack(spacing: 10) {
            // Recording indicator + status icons
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.state.isPaused ? Color.yellow : Color.red)
                    .frame(width: 12, height: 12)
                    .opacity(recorder.state.isPaused ? 1.0 : (isBlinking ? 0.3 : 1.0))
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isBlinking)

                Text(formatTime(elapsedTime))
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.medium)

                if recorder.state.isPaused {
                    Text("PAUSED")
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)
                }

                Spacer()

                // Status indicators
                statusIcon(
                    systemName: toggleState.micEnabled ? "mic.fill" : "mic.slash.fill",
                    isOn: toggleState.micEnabled,
                    action: onToggleMic
                )

                statusIcon(
                    systemName: toggleState.webcamEnabled ? "video.fill" : "video.slash.fill",
                    isOn: toggleState.webcamEnabled,
                    action: onToggleWebcam
                )

                Button(action: { onToggleBackgroundBlur?() }) {
                    Image(systemName: "person.fill.viewfinder")
                        .font(.system(size: 12))
                        .foregroundColor(toggleState.backgroundBlurEnabled ? .green : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                statusIcon(
                    systemName: toggleState.teleprompterEnabled ? "text.below.photo.fill" : "text.below.photo",
                    isOn: toggleState.teleprompterEnabled,
                    action: onToggleTeleprompter
                )
            }

            // Controls
            HStack(spacing: 16) {
                Button(action: onPause) {
                    Label(
                        recorder.state.isPaused ? "Resume" : "Pause",
                        systemImage: recorder.state.isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: onAnnotate) {
                    Label("Annotate", systemImage: "pencil.tip.crop.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 10)
        .onAppear {
            startTimer()
            isBlinking = true
        }
        .onDisappear {
            stopTimer()
        }
    }

    private func statusIcon(systemName: String, isOn: Bool, action: (() -> Void)?) -> some View {
        Button(action: { action?() }) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(isOn ? .green : .secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(isOn ? "On" : "Off")
    }

    private func startTimer() {
        if case .recording(let startTime, _) = recorder.state {
            elapsedTime = Date().timeIntervalSince(startTime) - pausedAccumulated
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak recorder] _ in
            guard let recorder = recorder else { return }
            Task { @MainActor in
                if case .recording(let startTime, let isPaused) = recorder.state {
                    if isPaused {
                        // Track when pause started
                        if self.pauseStartedAt == nil {
                            self.pauseStartedAt = Date()
                        }
                        // Don't update elapsed time while paused
                    } else {
                        // If we just resumed, accumulate the paused duration
                        if let pauseStart = self.pauseStartedAt {
                            self.pausedAccumulated += Date().timeIntervalSince(pauseStart)
                            self.pauseStartedAt = nil
                        }
                        self.elapsedTime = Date().timeIntervalSince(startTime) - self.pausedAccumulated
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        let seconds = Int(timeInterval) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Recording Overlay Window

class RecordingOverlayWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.sharingType = .none  // Exclude from screen capture

        // Position in top-right corner
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.maxX - frame.width - 20,
                y: screenFrame.maxY - frame.height - 20
            )
            self.setFrameOrigin(origin)
        }
    }
}

// MARK: - Countdown Window

class CountdownWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.sharingType = .none  // Exclude countdown from screen capture

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let origin = NSPoint(
                x: screenFrame.midX - frame.width / 2,
                y: screenFrame.midY - frame.height / 2
            )
            self.setFrameOrigin(origin)
        }
    }
}

struct CountdownView: View {
    let number: Int
    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 1.0

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(Color.red.opacity(0.3), lineWidth: 4)
                .frame(width: 150, height: 150)
                .scaleEffect(scale * 1.2)
                .opacity(opacity * 0.5)

            // Inner circle
            Circle()
                .fill(Color.black.opacity(0.7))
                .frame(width: 120, height: 120)
                .scaleEffect(scale)
                .opacity(opacity)

            // Number
            Text("\(number)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .frame(width: 200, height: 200)
        .onAppear {
            // Scale up
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                scale = 1.0
            }
            // Fade out near the end
            withAnimation(.easeIn(duration: 0.3).delay(0.6)) {
                scale = 1.3
                opacity = 0.0
            }
        }
    }
}

@MainActor
class CountdownController {
    private var window: CountdownWindow?

    func runCountdown() async {
        for number in stride(from: 3, through: 1, by: -1) {
            let window = CountdownWindow()
            let view = CountdownView(number: number)
            window.contentView = NSHostingView(rootView: view)
            window.orderFront(nil)
            self.window = window

            // Hold for ~0.9 seconds, then close
            try? await Task.sleep(nanoseconds: 900_000_000)

            window.orderOut(nil)
            window.close()
            self.window = nil

            // Brief gap between numbers
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func cancel() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

// MARK: - Region Border Window (shown during recording)

class RegionBorderWindow: NSPanel {
    init(region: CGRect) {
        // Convert from ScreenCaptureKit coordinates (top-left origin)
        // to AppKit screen coordinates (bottom-left origin)
        let screen = NSScreen.main!
        let screenHeight = screen.frame.height
        let appKitRect = NSRect(
            x: region.origin.x + screen.frame.origin.x,
            y: screenHeight - region.origin.y - region.height,
            width: region.width,
            height: region.height
        )

        // Expand slightly so the border is outside the recording area
        let borderWidth: CGFloat = 3
        let expandedRect = appKitRect.insetBy(dx: -borderWidth - 1, dy: -borderWidth - 1)

        super.init(
            contentRect: expandedRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.sharingType = .none  // Exclude red region border from screen capture

        let borderView = RegionBorderView(frame: NSRect(origin: .zero, size: expandedRect.size), borderWidth: borderWidth)
        self.contentView = borderView
    }
}

class RegionBorderView: NSView {
    private let borderWidth: CGFloat
    private var animationTimer: Timer?
    private var dashPhase: CGFloat = 0

    init(frame: NSRect, borderWidth: CGFloat) {
        self.borderWidth = borderWidth
        super.init(frame: frame)

        // Animate the marching ants
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.dashPhase += 2
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        let insetRect = bounds.insetBy(dx: borderWidth / 2 + 1, dy: borderWidth / 2 + 1)

        // Red border with marching ants effect
        let path = NSBezierPath(rect: insetRect)
        path.lineWidth = borderWidth
        path.setLineDash([8, 4], count: 2, phase: dashPhase)

        NSColor.red.withAlphaComponent(0.8).setStroke()
        path.stroke()

        // Corner markers for extra visibility
        let cornerSize: CGFloat = 16
        NSColor.red.setFill()

        // Top-left
        NSRect(x: insetRect.minX - 1, y: insetRect.maxY - cornerSize, width: cornerSize, height: 3).fill()
        NSRect(x: insetRect.minX - 1, y: insetRect.maxY - cornerSize, width: 3, height: cornerSize).fill()

        // Top-right
        NSRect(x: insetRect.maxX - cornerSize + 1, y: insetRect.maxY - cornerSize, width: cornerSize, height: 3).fill()
        NSRect(x: insetRect.maxX - 2, y: insetRect.maxY - cornerSize, width: 3, height: cornerSize).fill()

        // Bottom-left
        NSRect(x: insetRect.minX - 1, y: insetRect.minY, width: cornerSize, height: 3).fill()
        NSRect(x: insetRect.minX - 1, y: insetRect.minY, width: 3, height: cornerSize).fill()

        // Bottom-right
        NSRect(x: insetRect.maxX - cornerSize + 1, y: insetRect.minY, width: cornerSize, height: 3).fill()
        NSRect(x: insetRect.maxX - 2, y: insetRect.minY, width: 3, height: cornerSize).fill()
    }
}
