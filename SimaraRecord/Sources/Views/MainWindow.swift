//
//  MainWindow.swift
//  OpenCapture
//
//  Main control panel UI
//

import SwiftUI
import AppKit
import AVFoundation

struct MainWindow: View {
    @StateObject private var recorder = ScreenRecorder()
    @StateObject private var audioManager = AudioManager()
    @StateObject private var regionSelector = RegionSelectorController()
    @StateObject private var annotationController = AnnotationController()
    @StateObject private var webcamManager = WebcamManager()
    @StateObject private var hotkeyManager = HotkeyManager()
    @StateObject private var teleprompterState = TeleprompterState()

    @State private var settings = RecordingSettings.default
    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingPermissionAlert = false
    @State private var hasRequestedPermission = false
    @State private var recordingOverlayWindow: RecordingOverlayWindow?
    @State private var regionBorderWindow: RegionBorderWindow?
    @State private var webcamPiPWindow: WebcamPiPWindow?
    @State private var webcamPiPView: WebcamPiPView?
    @State private var teleprompterWindow: TeleprompterWindow?
    @State private var scriptEditorWindow: NSWindow?
    @State private var webcamPreviewWindow: NSWindow?
    @State private var postRecordingWindow: PostRecordingWindow?
    @StateObject private var overlayState = OverlayToggleState()

    var body: some View {
        VStack(spacing: 10) {
            // Header
            headerView

            // Recording Area
            settingsCard {
                regionSelectionView
            }

            // Audio & Webcam side by side
            HStack(alignment: .top, spacing: 10) {
                settingsCard {
                    audioSettingsView
                }
                settingsCard {
                    webcamSettingsView
                }
            }

            // Teleprompter
            settingsCard {
                teleprompterSettingsView
            }

            // Output & Quality combined
            settingsCard {
                outputAndQualityView
            }

            // Main Action Button
            mainActionButton

            // Keyboard Shortcuts hint
            shortcutsHint
        }
        .padding(16)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Screen Recording Permission Required", isPresented: $showingPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please enable OpenCapture in System Settings > Privacy & Security > Screen & System Audio Recording, then click Start Recording again.\n\nIf it still doesn't work, quit and reopen the app.")
        }
        .onAppear {
            updateDefaultOutputURL()
            setupHotkeys()
        }
    }

    // MARK: - Settings Card Container

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            // App icon — camera on gradient circle
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.58, green: 0.44, blue: 0.86),
                                Color(red: 0.50, green: 0.62, blue: 0.85),
                                Color(red: 0.55, green: 0.78, blue: 0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: "video.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)

                Circle()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .offset(x: 8, y: -7)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenCapture")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Open source screen recording for Mac")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Edit existing recording button
            Button(action: openExistingRecording) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .help("Edit existing recording (⌘O)")
        }
    }

    // MARK: - Region Selection

    private var regionSelectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recording Area", systemImage: "viewfinder")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                // Full Screen card
                regionCard(
                    icon: "rectangle.inset.filled",
                    title: "Full Screen",
                    subtitle: "Entire display",
                    isSelected: settings.region == .fullScreen
                ) {
                    settings.region = .fullScreen
                }
                .disabled(recorder.state.isRecording)

                // Select Region card
                regionCard(
                    icon: "viewfinder",
                    title: "Select Region",
                    subtitle: regionSubtitle,
                    isSelected: settings.region != .fullScreen
                ) {
                    selectRegion()
                }
                .disabled(recorder.state.isRecording)
            }
        }
    }

    private var regionSubtitle: String {
        if case .custom(let rect) = settings.region {
            return "\(Int(rect.width)) × \(Int(rect.height))"
        }
        return "Click to select"
    }

    private var micGainIcon: String {
        let gain = settings.audioSettings.micInputGain
        if gain == 0 { return "speaker.slash" }
        if gain < 0.33 { return "speaker.wave.1" }
        if gain < 0.66 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }

    private var audioLevelColor: Color {
        let level = audioManager.audioLevel
        if level > 0.8 { return .red }
        if level > 0.5 { return .orange }
        return .green
    }

    private func regionCard(icon: String, title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.5), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Audio Settings

    private var audioSettingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Audio", systemImage: "waveform")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Microphone", isOn: $settings.audioSettings.microphoneEnabled)
                .font(.system(size: 12))
                .disabled(recorder.state.isRecording)
                .onChange(of: settings.audioSettings.microphoneEnabled) { newValue in
                    if newValue {
                        Task {
                            let granted = await audioManager.requestMicrophonePermission()
                            if !granted {
                                settings.audioSettings.microphoneEnabled = false
                                showError("Microphone permission denied. Please enable it in System Settings.")
                            }
                        }
                    }
                }

            if settings.audioSettings.microphoneEnabled && !audioManager.availableMicrophones.isEmpty {
                Picker("Device", selection: $audioManager.selectedMicrophone) {
                    ForEach(audioManager.availableMicrophones) { device in
                        Text(device.displayName).tag(device as AudioDevice?)
                    }
                }
                .font(.system(size: 11))
                .disabled(recorder.state.isRecording)

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: micGainIcon)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 14)

                        Slider(value: $settings.audioSettings.micInputGain, in: 0...1)
                            .controlSize(.small)
                            .onChange(of: settings.audioSettings.micInputGain) { newValue in
                                recorder.updateMicGain(newValue)
                            }

                        Text("\(Int(settings.audioSettings.micInputGain * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }

                    // Level meter
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(NSColor.separatorColor).opacity(0.3))
                                .frame(height: 3)

                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(audioLevelColor)
                                .frame(width: geo.size.width * CGFloat(audioManager.audioLevel), height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }

            Toggle("System Audio", isOn: $settings.audioSettings.systemAudioEnabled)
                .font(.system(size: 12))
                .disabled(recorder.state.isRecording)
        }
    }

    // MARK: - Webcam Settings

    private var webcamSettingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Webcam", systemImage: "camera")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Show overlay", isOn: $settings.webcamSettings.enabled)
                .font(.system(size: 12))
                .disabled(recorder.state.isRecording)
                .onChange(of: settings.webcamSettings.enabled) { newValue in
                    if newValue {
                        Task {
                            let granted = await webcamManager.requestCameraPermission()
                            if !granted {
                                settings.webcamSettings.enabled = false
                                showError("Camera permission denied. Please enable it in System Settings.")
                            }
                        }
                    }
                }

            if settings.webcamSettings.enabled && !webcamManager.availableCameras.isEmpty {
                Picker("Camera", selection: $webcamManager.selectedCamera) {
                    ForEach(webcamManager.availableCameras) { camera in
                        Text(camera.displayName).tag(camera as CameraDevice?)
                    }
                }
                .font(.system(size: 11))
                .disabled(recorder.state.isRecording)

                // Background options row
                HStack(spacing: 8) {
                    Text("Background")
                        .font(.system(size: 12))

                    Spacer()

                    // Blur toggle
                    Toggle("Blur", isOn: $settings.webcamSettings.backgroundBlurEnabled)
                        .toggleStyle(.button)
                        .font(.system(size: 10))
                        .controlSize(.small)

                    // Virtual background image button
                    if let bgURL = settings.webcamSettings.backgroundImageURL {
                        HStack(spacing: 4) {
                            Text(bgURL.lastPathComponent)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 80)

                            Button(action: clearBackgroundImage) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("Remove background image")
                        }
                    } else {
                        Button("Image...") {
                            selectBackgroundImage()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Blur intensity slider (only when blur is on and no image)
                if settings.webcamSettings.backgroundBlurEnabled && settings.webcamSettings.backgroundImageURL == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "aqi.low")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Slider(value: $settings.webcamSettings.blurIntensity, in: 0...1)
                            .controlSize(.small)
                            .onChange(of: settings.webcamSettings.blurIntensity) { newValue in
                                webcamManager.updateBlurIntensity(newValue)
                            }

                        Image(systemName: "aqi.high")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Text("\(Int(settings.webcamSettings.blurIntensity * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }

                HStack(spacing: 8) {
                    Text("Shape")
                        .font(.system(size: 12))
                        .frame(width: 40, alignment: .leading)

                    Picker("", selection: $settings.webcamSettings.shape) {
                        ForEach(WebcamShape.allCases) { shape in
                            Text(shape.rawValue).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(recorder.state.isRecording)
                    .onChange(of: settings.webcamSettings.shape) { newShape in
                        webcamPiPView?.setShape(newShape)
                    }
                }

                Button(action: { showWebcamPreview() }) {
                    Label("Preview Webcam", systemImage: "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(recorder.state.isRecording)
            }
        }
    }

    // MARK: - Teleprompter Settings

    private var teleprompterSettingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Teleprompter", systemImage: "text.below.photo")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Enable teleprompter", isOn: $settings.teleprompterSettings.enabled)
                .font(.system(size: 12))
                .disabled(recorder.state.isRecording)

            if settings.teleprompterSettings.enabled {
                // Script preview + Edit button
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if settings.teleprompterSettings.scriptText.isEmpty {
                            Text("No script — click Edit Script to add one")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            Text(settings.teleprompterSettings.scriptText.prefix(100) + (settings.teleprompterSettings.scriptText.count > 100 ? "..." : ""))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(2)

                            let pageCount = settings.teleprompterSettings.scriptText.replacingOccurrences(of: "\n---\n", with: "\n###\n").components(separatedBy: "\n###\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                            let wordCount = settings.teleprompterSettings.scriptText.split(separator: " ").count
                            Text("\(pageCount) page\(pageCount == 1 ? "" : "s"), \(wordCount) words")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    Spacer()
                    Button("Edit Script") {
                        openScriptEditor()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(recorder.state.isRecording)
                }

                HStack(spacing: 8) {
                    Text("Font size")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Slider(value: $settings.teleprompterSettings.fontSize, in: 16...48, step: 2)
                        .controlSize(.small)

                    Text("\(Int(settings.teleprompterSettings.fontSize))pt")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 30)
                }

                Text("### page break  •  *bold*  •  - bullet  •  ← → navigate")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Output & Quality (combined)

    private var outputAndQualityView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Output", systemImage: "folder")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(settings.outputURL.deletingLastPathComponent().lastPathComponent + "/" + settings.outputURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Button("Change") {
                    chooseOutputLocation()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(recorder.state.isRecording)
            }

            Divider()

            HStack(spacing: 12) {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(recorder.state.isRecording)

                Picker("FPS", selection: $settings.frameRate) {
                    ForEach(FrameRate.allCases) { fps in
                        Text(fps.displayName).tag(fps)
                    }
                }
                .frame(width: 100)
                .disabled(recorder.state.isRecording)
            }
        }
    }

    // MARK: - Main Action Button

    private var mainActionButton: some View {
        Group {
            if recorder.state.isRecording {
                Button(action: stopRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                        Text("Stop Recording")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button(action: startRecording) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                        Text("Start Recording")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Shortcuts Hint

    private var shortcutsHint: some View {
        HStack(spacing: 12) {
            shortcutLabel("R", "Start/Stop", shortcut: "\u{21E7}\u{2318}R")
            shortcutLabel("P", "Pause", shortcut: "\u{21E7}\u{2318}P")
            shortcutLabel("A", "Annotate", shortcut: "\u{21E7}\u{2318}A")
            shortcutLabel("D", "Clear", shortcut: "\u{21E7}\u{2318}D")
            shortcutLabel("V", "Webcam", shortcut: "\u{21E7}\u{2318}V")
            shortcutLabel("M", "Mic", shortcut: "\u{21E7}\u{2318}M")
            shortcutLabel("T", "Prompt", shortcut: "\u{21E7}\u{2318}T")
            shortcutLabel("B", "Blur", shortcut: "\u{21E7}\u{2318}B")
            shortcutLabel("\u{238B}", "Cancel", shortcut: "Esc")
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcutLabel(_ icon: String, _ label: String, shortcut: String) -> some View {
        VStack(spacing: 2) {
            Text(shortcut)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
    }

    // MARK: - Actions

    private func selectRegion() {
        regionSelector.showSelector { rect in
            if let rect = rect {
                settings.region = .custom(rect)
            }
        }
    }

    private func chooseOutputLocation() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.quickTimeMovie]
        savePanel.nameFieldStringValue = "recording_\(DateFormatter.filenameDateFormatter.string(from: Date())).mov"
        savePanel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                settings.outputURL = url
            }
        }
    }

    private func openScriptEditor() {
        // If already open, bring to front
        if let existing = scriptEditorWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = ScriptEditorView(scriptText: $settings.teleprompterSettings.scriptText)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Teleprompter Script"
        window.contentView = NSHostingView(rootView: editorView)
        window.center()
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scriptEditorWindow = window
    }

    private func startRecording() {
        Task {
            do {
                // Check screen recording permission BEFORE countdown
                // by actually trying SCShareableContent. CGPreflight is unreliable
                // (can return false even when permission is granted).
                let hasPermission = await recorder.checkPermission()
                if !hasPermission {
                    if !hasRequestedPermission {
                        // First time — trigger the macOS system dialog.
                        CGRequestScreenCaptureAccess()
                        hasRequestedPermission = true
                    } else {
                        // Already triggered system dialog before.
                        showingPermissionAlert = true
                    }
                    return
                }

                // Update output URL with current timestamp
                updateDefaultOutputURL()

                // Cinematic countdown: 3... 2... 1...
                let countdown = CountdownController()
                await countdown.runCountdown()

                try await recorder.startRecording(settings: settings)

                // Show recording overlay
                showRecordingOverlay()

                // Show region border if recording a custom region
                if case .custom(let rect) = settings.region {
                    let border = RegionBorderWindow(region: rect)
                    border.orderFront(nil)
                    regionBorderWindow = border
                }

                // Start teleprompter if enabled
                if settings.teleprompterSettings.enabled {
                    showTeleprompter()
                    overlayState.teleprompterEnabled = true
                }

                // Start webcam PiP if enabled
                if settings.webcamSettings.enabled {
                    let granted = await webcamManager.requestCameraPermission()
                    if granted {
                        if let previewLayer = webcamManager.startCapture(deviceID: webcamManager.selectedCamera?.id) {
                            showWebcamPiP(previewLayer: previewLayer)
                        }
                    }
                }

            } catch RecorderError.permissionRequired {
                showingPermissionAlert = true
            } catch {
                let errorDesc = error.localizedDescription
                if errorDesc.contains("TCC") || errorDesc.contains("declined") || errorDesc.contains("denied") {
                    showingPermissionAlert = true
                } else {
                    showError(errorDesc)
                }
            }
        }
    }

    private func stopRecording() {
        Task {
            do {
                // Cancel any active annotation
                annotationController.cancel()

                try await recorder.stopRecording()

                // Hide recording overlay
                hideRecordingOverlay()

                // Show post-recording editor
                showPostRecordingEditor()

            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func showPostRecordingEditor() {
        let window = PostRecordingWindow(videoURL: settings.outputURL) { [self] in
            postRecordingWindow = nil
            // Generate new output URL for next recording
            updateDefaultOutputURL()
        }
        window.makeKeyAndOrderFront(nil)
        postRecordingWindow = window
    }

    private func showRecordingOverlay() {
        // Set initial toggle state
        overlayState.micEnabled = settings.audioSettings.microphoneEnabled
        overlayState.webcamEnabled = settings.webcamSettings.enabled
        overlayState.teleprompterEnabled = settings.teleprompterSettings.enabled
        overlayState.backgroundBlurEnabled = settings.webcamSettings.backgroundBlurEnabled

        let window = RecordingOverlayWindow()
        let overlay = RecordingOverlay(
            recorder: recorder,
            toggleState: overlayState,
            onPause: { recorder.togglePause() },
            onAnnotate: { annotationController.startAnnotating() },
            onToggleWebcam: { [self] in toggleWebcamDuringRecording() },
            onToggleMic: { [self] in toggleMicDuringRecording() },
            onToggleTeleprompter: { [self] in toggleTeleprompter() },
            onToggleBackgroundBlur: { [self] in toggleBackgroundBlur() },
            onStop: stopRecording
        )
        window.contentView = NSHostingView(rootView: overlay)
        window.orderFront(nil)
        recordingOverlayWindow = window
    }

    private func toggleWebcamDuringRecording() {
        if webcamPiPWindow != nil {
            webcamManager.stopCapture()
            webcamPiPWindow?.close()
            webcamPiPWindow = nil
            webcamPiPView = nil
            overlayState.webcamEnabled = false
            overlayState.backgroundBlurEnabled = false
        } else {
            Task {
                let granted = await webcamManager.requestCameraPermission()
                if granted {
                    if let previewLayer = webcamManager.startCapture(deviceID: webcamManager.selectedCamera?.id) {
                        showWebcamPiP(previewLayer: previewLayer)
                        overlayState.webcamEnabled = true
                    }
                }
            }
        }
    }

    private func toggleMicDuringRecording() {
        if overlayState.micEnabled {
            recorder.muteMicrophone()
            overlayState.micEnabled = false
        } else {
            recorder.unmuteMicrophone()
            overlayState.micEnabled = true
        }
    }

    private func hideRecordingOverlay() {
        annotationController.cancel()
        recordingOverlayWindow?.close()
        recordingOverlayWindow = nil
        regionBorderWindow?.close()
        regionBorderWindow = nil

        // Stop webcam
        webcamManager.stopCapture()
        webcamPiPWindow?.close()
        webcamPiPWindow = nil
        webcamPiPView = nil

        // Hide teleprompter
        hideTeleprompter()
    }

    private func showWebcamPiP(previewLayer: AVCaptureVideoPreviewLayer) {
        let window = WebcamPiPWindow()
        let view = WebcamPiPView(
            previewLayer: previewLayer,
            processedLayer: webcamManager.processedFrameLayer,
            shape: settings.webcamSettings.shape
        )
        window.contentView = view
        window.orderFront(nil)
        webcamPiPWindow = window
        webcamPiPView = view

        // Auto-enable blur if setting is on
        if settings.webcamSettings.backgroundBlurEnabled {
            webcamManager.enableBackgroundBlur(intensity: settings.webcamSettings.blurIntensity)
            view.setBlurEnabled(true)
            overlayState.backgroundBlurEnabled = true

            // Apply background image if one is set
            if let bgURL = settings.webcamSettings.backgroundImageURL {
                webcamManager.setBackgroundImage(url: bgURL, intensity: settings.webcamSettings.blurIntensity)
            }
        }
    }

    private func toggleBackgroundBlur() {
        print("🟡 toggleBackgroundBlur — webcamWindow: \(webcamPiPWindow != nil), view: \(webcamPiPView != nil), wasBlur: \(webcamManager.backgroundBlurEnabled)")
        guard webcamPiPWindow != nil else {
            print("🔴 BAILED — no webcam window")
            return
        }

        if webcamManager.backgroundBlurEnabled {
            // Turning OFF — switch to preview layer first, then disable processing
            webcamPiPView?.setBlurEnabled(false)
            webcamManager.disableBackgroundBlur()
        } else {
            // Turning ON — enable blur processing first
            webcamManager.enableBackgroundBlur(intensity: settings.webcamSettings.blurIntensity)

            // Re-apply background image if one was set (do this BEFORE switching layers)
            if let bgURL = settings.webcamSettings.backgroundImageURL {
                webcamManager.setBackgroundImage(url: bgURL, intensity: settings.webcamSettings.blurIntensity)
            }

            // Give the processor a moment to start producing frames, then switch layers
            let view = webcamPiPView
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                view?.setBlurEnabled(true)
            }
        }
        let blurNowEnabled = webcamManager.backgroundBlurEnabled
        overlayState.backgroundBlurEnabled = blurNowEnabled
        settings.webcamSettings.backgroundBlurEnabled = blurNowEnabled
        print("🟢 Result — blur: \(blurNowEnabled), overlay: \(overlayState.backgroundBlurEnabled)")
    }

    private func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Select Background Image"
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            settings.webcamSettings.backgroundImageURL = url
            // Auto-enable background processing
            settings.webcamSettings.backgroundBlurEnabled = true

            // If webcam is running, apply immediately
            if webcamManager.isRunning {
                if !webcamManager.backgroundBlurEnabled {
                    webcamManager.enableBackgroundBlur(intensity: settings.webcamSettings.blurIntensity)
                    webcamPiPView?.setBlurEnabled(true)
                    overlayState.backgroundBlurEnabled = true
                }
                webcamManager.setBackgroundImage(url: url, intensity: settings.webcamSettings.blurIntensity)
            }
        }
    }

    private func clearBackgroundImage() {
        settings.webcamSettings.backgroundImageURL = nil
        webcamManager.clearBackgroundImage()
    }

    // MARK: - Webcam Preview

    private func showWebcamPreview() {
        // Close existing preview
        webcamPreviewWindow?.close()
        webcamPreviewWindow = nil

        // Start webcam if not running
        guard let previewLayer = webcamManager.startCapture(deviceID: settings.webcamSettings.selectedDeviceID) else {
            showError("Could not start webcam")
            return
        }

        // Create preview window
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Webcam Preview"
        window.isFloatingPanel = true
        window.level = .floating
        window.center()

        let previewView = WebcamPreviewView(
            webcamManager: webcamManager,
            previewLayer: previewLayer,
            blurEnabled: settings.webcamSettings.backgroundBlurEnabled,
            blurIntensity: settings.webcamSettings.blurIntensity
        )
        window.contentView = NSHostingView(rootView: previewView)
        window.orderFront(nil)
        webcamPreviewWindow = window

        // Enable blur/background if setting is on
        if settings.webcamSettings.backgroundBlurEnabled {
            webcamManager.enableBackgroundBlur(intensity: settings.webcamSettings.blurIntensity)

            // Apply background image if one is set
            if let bgURL = settings.webcamSettings.backgroundImageURL {
                webcamManager.setBackgroundImage(url: bgURL, intensity: settings.webcamSettings.blurIntensity)
            }
        }
    }

    // MARK: - Teleprompter Lifecycle

    private func showTeleprompter() {
        guard teleprompterWindow == nil else { return }
        let window = TeleprompterWindow()
        window.teleprompterState = teleprompterState
        teleprompterState.fontSize = settings.teleprompterSettings.fontSize
        teleprompterState.opacity = settings.teleprompterSettings.opacity
        teleprompterState.parseScript(settings.teleprompterSettings.scriptText)

        let view = TeleprompterView(state: teleprompterState)
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        window.startKeyMonitor()
        teleprompterWindow = window
        hotkeyManager.teleprompterActive = true
    }

    private func hideTeleprompter() {
        teleprompterWindow?.stopKeyMonitor()
        teleprompterWindow?.orderOut(nil)
        teleprompterWindow?.close()
        teleprompterWindow = nil
        hotkeyManager.teleprompterActive = false
    }

    private func toggleTeleprompter() {
        if teleprompterWindow != nil {
            hideTeleprompter()
            overlayState.teleprompterEnabled = false
        } else {
            showTeleprompter()
            overlayState.teleprompterEnabled = true
        }
    }

    private func updateDefaultOutputURL() {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let timestamp = DateFormatter.filenameDateFormatter.string(from: Date())
        let filename = "recording_\(timestamp).mov"
        settings.outputURL = desktopURL.appendingPathComponent(filename)
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private func openExistingRecording() {
        let panel = NSOpenPanel()
        panel.title = "Select Recording to Edit"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            let window = PostRecordingWindow(videoURL: url) {
                // Window closed
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeyManager.onAction = { [self] action in
            switch action {
            case .toggleRecording:
                if recorder.state.isRecording {
                    stopRecording()
                } else if recorder.state == .idle {
                    startRecording()
                }
            case .togglePause:
                if recorder.state.isRecording {
                    recorder.togglePause()
                }
            case .cancelRecording:
                if recorder.state.isRecording {
                    Task {
                        await recorder.cancelRecording()
                        hideRecordingOverlay()
                    }
                }
            case .toggleAnnotation:
                if recorder.state.isRecording {
                    if annotationController.isActive {
                        annotationController.stopAnnotating()
                    } else {
                        annotationController.startAnnotating()
                    }
                }
            case .clearAnnotations:
                if recorder.state.isRecording {
                    annotationController.clearAnnotations()
                }
            case .toggleWebcam:
                if recorder.state.isRecording {
                    toggleWebcamDuringRecording()
                }
            case .toggleMicrophone:
                if recorder.state.isRecording {
                    toggleMicDuringRecording()
                }
            case .toggleTeleprompter:
                if recorder.state.isRecording {
                    toggleTeleprompter()
                }
            case .teleprompterNext:
                if teleprompterWindow != nil {
                    teleprompterState.nextPage()
                }
            case .teleprompterPrevious:
                if teleprompterWindow != nil {
                    teleprompterState.previousPage()
                }
            case .toggleBackgroundBlur:
                if recorder.state.isRecording {
                    toggleBackgroundBlur()
                }
            }
        }
        hotkeyManager.start()
    }
}

// MARK: - Preview

#Preview {
    MainWindow()
}
