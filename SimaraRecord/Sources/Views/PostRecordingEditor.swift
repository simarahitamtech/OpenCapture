//
//  PostRecordingEditor.swift
//  OpenCapture
//
//  Post-recording editor window with silence removal, trim, export presets, and thumbnails
//

import SwiftUI
import AVFoundation
import AVKit
import AppKit

// MARK: - Post Recording Editor View

struct PostRecordingEditor: View {
    let videoURL: URL
    let onDismiss: () -> Void

    @State private var duration: TimeInterval = 0
    @State private var fileSize: Int64 = 0
    @State private var thumbnail: CGImage?
    @State private var isProcessing = false
    @State private var processingStatus = ""
    @State private var progress: Double = 0
    @State private var showingError = false
    @State private var errorMessage = ""

    // Silence removal
    @State private var silenceThreshold: Float = -40
    @State private var minSilenceDuration: Double = 0.5
    @State private var silenceAnalysis: [SilenceRemover.Segment] = []
    @State private var estimatedSilenceRemoval: TimeInterval = 0

    // Trim
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var trimPlayer: AVPlayer?
    @State private var trimPlayerTime: Double = 0
    @State private var trimTimeObserver: Any?

    // Export
    @State private var selectedPreset: ExportPreset = .original

    // Tab selection
    @State private var selectedTab = 0

    private let silenceRemover = SilenceRemover()
    private let videoTrimmer = VideoTrimmer()
    private let videoExporter = VideoExporter()
    private let thumbnailGenerator = ThumbnailGenerator()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Tab bar
            tabBar

            Divider()

            // Content based on selected tab
            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case 0:
                        silenceRemovalView
                    case 1:
                        trimView
                    case 2:
                        exportView
                    default:
                        EmptyView()
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer with actions
            footer
        }
        .frame(width: 500, height: 780)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            loadVideoInfo()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let thumb = thumbnail {
                Image(decorative: thumb, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 45)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.6)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(videoURL.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(formatDuration(duration), systemImage: "clock")
                    Label(formatFileSize(fileSize), systemImage: "doc")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: playVideo) {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Remove Silence", icon: "waveform.badge.minus", index: 0)
            tabButton(title: "Trim", icon: "scissors", index: 1)
            tabButton(title: "Export", icon: "square.and.arrow.up", index: 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabButton(title: String, icon: String, index: Int) -> some View {
        Button(action: { selectedTab = index }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: selectedTab == index ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectedTab == index ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(selectedTab == index ? .accentColor : .secondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Silence Removal View

    private var silenceRemovalView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove Silent Portions")
                .font(.system(size: 14, weight: .semibold))

            Text("Automatically detect and remove silent segments from your recording to tighten it up.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    // Threshold slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Silence Threshold")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(silenceThreshold)) dB")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(silenceThreshold) },
                            set: { silenceThreshold = Float($0) }
                        ), in: -60...(-20))
                        HStack {
                            Text("More aggressive")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Less aggressive")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Min silence duration
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Minimum Silence Duration")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(String(format: "%.1f", minSilenceDuration))s")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $minSilenceDuration, in: 0.2...2.0, step: 0.1)
                    }
                }
                .padding(12)
            }

            // Analysis button
            Button(action: analyzeSilence) {
                HStack {
                    Image(systemName: "waveform.badge.magnifyingglass")
                    Text("Analyze Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

            // Analysis results
            if !silenceAnalysis.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        let speechSegments = silenceAnalysis.filter { $0.isSpeech }
                        let silentSegments = silenceAnalysis.filter { !$0.isSpeech }
                        let totalSilence = silentSegments.reduce(0) { $0 + $1.duration }

                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(speechSegments.count)")
                                    .font(.system(size: 18, weight: .bold))
                                Text("Speech segments")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .center) {
                                Text("\(silentSegments.count)")
                                    .font(.system(size: 18, weight: .bold))
                                Text("Silent segments")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(formatDuration(totalSilence))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.orange)
                                Text("Can be removed")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if totalSilence > 0 {
                            Divider()

                            let newDuration = duration - totalSilence
                            let percentReduction = (totalSilence / duration) * 100

                            Text("Result: \(formatDuration(newDuration)) (\(Int(percentReduction))% shorter)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                    .padding(12)
                }
            }

            // Process button
            if !silenceAnalysis.isEmpty {
                Button(action: processSilenceRemoval) {
                    HStack {
                        Image(systemName: "scissors")
                        Text("Remove Silence")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || silenceAnalysis.filter { !$0.isSpeech }.isEmpty)
            }
        }
    }

    // MARK: - Trim View

    private var trimView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trim Start & End")
                .font(.system(size: 14, weight: .semibold))

            Text("Preview the video and mark your trim points, or use the sliders below.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Video player with mark buttons
            GroupBox {
                VStack(spacing: 8) {
                    // Video preview
                    if let player = trimPlayer {
                        TrimPlayerView(player: player)
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.8))
                            .frame(height: 160)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.8)
                            )
                    }

                    // Current time display
                    Text(formatTimePrecise(trimPlayerTime))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)

                    // Mark buttons
                    HStack(spacing: 12) {
                        Button(action: markTrimStart) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.to.line")
                                Text("Mark In")
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .help("Set trim start to current position")

                        Button(action: markTrimEnd) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.to.line")
                                Text("Mark Out")
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .help("Set trim end to current position")
                    }
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    // Start trim
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Start")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(formatTimePrecise(trimStart))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $trimStart, in: 0...max(0, duration - 0.1)) { editing in
                            if !editing {
                                seekTrimPlayer(to: trimStart)
                            }
                        }
                    }

                    Divider()

                    // End trim
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("End")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(formatTimePrecise(trimEnd))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $trimEnd, in: 0.1...duration) { editing in
                            if !editing {
                                seekTrimPlayer(to: trimEnd)
                            }
                        }
                    }

                    Divider()

                    // Result preview
                    let newDuration = max(0, trimEnd - trimStart)
                    let trimmed = duration - newDuration

                    HStack {
                        Text("New duration:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(formatDuration(newDuration))
                            .font(.system(size: 11, weight: .semibold))

                        if trimmed > 0 {
                            Text("(\(formatDuration(trimmed)) removed)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(12)
            }

            Button(action: processTrim) {
                HStack {
                    Image(systemName: "scissors")
                    Text("Trim Video")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing || trimStart >= trimEnd || (trimStart == 0 && trimEnd == duration))
        }
        .onAppear {
            setupTrimPlayer()
        }
        .onDisappear {
            cleanupTrimPlayer()
        }
    }

    // MARK: - Export View

    private var exportView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export with Preset")
                .font(.system(size: 14, weight: .semibold))

            Text("Re-export your recording with different quality settings to reduce file size.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            GroupBox {
                VStack(spacing: 0) {
                    ForEach(ExportPreset.allCases, id: \.self) { preset in
                        exportPresetRow(preset)
                        if preset != ExportPreset.allCases.last {
                            Divider()
                        }
                    }
                }
            }

            // Estimated size
            if selectedPreset != .original {
                let estimatedSize = Int64(Double(fileSize) * selectedPreset.estimatedSizeMultiplier)
                let savings = fileSize - estimatedSize

                HStack {
                    Text("Estimated size:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(formatFileSize(estimatedSize))
                        .font(.system(size: 11, weight: .semibold))

                    if savings > 0 {
                        Text("(save \(formatFileSize(savings)))")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                }
            }

            Button(action: processExport) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
        }
    }

    private func exportPresetRow(_ preset: ExportPreset) -> some View {
        Button(action: { selectedPreset = preset }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(preset.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if selectedPreset == preset {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Progress indicator
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text(processingStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([videoURL])
            }
            .buttonStyle(.bordered)

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadVideoInfo() {
        Task {
            // Get duration
            let asset = AVURLAsset(url: videoURL)
            if let d = try? await asset.load(.duration) {
                duration = d.seconds
                trimEnd = d.seconds
            }

            // Get file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
               let size = attrs[.size] as? Int64 {
                fileSize = size
            }

            // Generate thumbnail
            do {
                let thumb = try await thumbnailGenerator.generate(from: videoURL, options: .init(size: .medium))
                thumbnail = thumb
            } catch {
                print("Failed to generate thumbnail: \(error)")
            }

        }
    }

    private func playVideo() {
        NSWorkspace.shared.open(videoURL)
    }

    private func analyzeSilence() {
        isProcessing = true
        processingStatus = "Analyzing..."
        progress = 0

        Task {
            do {
                silenceRemover.silenceThreshold = silenceThreshold
                silenceRemover.minSilenceDuration = minSilenceDuration

                let segments = try await silenceRemover.analyze(url: videoURL)
                silenceAnalysis = segments
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            isProcessing = false
            processingStatus = ""
        }
    }

    private func processSilenceRemoval() {
        isProcessing = true
        processingStatus = "Removing silence..."
        progress = 0

        Task {
            do {
                let outputURL = generateOutputURL(suffix: "_trimmed")

                silenceRemover.silenceThreshold = silenceThreshold
                silenceRemover.minSilenceDuration = minSilenceDuration

                let result = try await silenceRemover.process(
                    inputURL: videoURL,
                    outputURL: outputURL
                ) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }

                // Show result
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])

                processingStatus = "Removed \(formatDuration(result.silenceRemoved)) of silence"

            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            isProcessing = false
        }
    }

    private func processTrim() {
        isProcessing = true
        processingStatus = "Trimming..."
        progress = 0

        Task {
            do {
                let outputURL = generateOutputURL(suffix: "_trimmed")

                let range = VideoTrimmer.TrimRange(
                    start: CMTime(seconds: trimStart, preferredTimescale: 600),
                    end: CMTime(seconds: trimEnd, preferredTimescale: 600)
                )

                let result = try await videoTrimmer.trim(
                    inputURL: videoURL,
                    outputURL: outputURL,
                    range: range
                ) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }

                NSWorkspace.shared.activateFileViewerSelecting([outputURL])

                processingStatus = "Trimmed to \(formatDuration(result.newDuration))"

            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            isProcessing = false
        }
    }

    private func processExport() {
        isProcessing = true
        processingStatus = "Exporting..."
        progress = 0

        Task {
            do {
                let suffix = selectedPreset == .original ? "_copy" : "_\(selectedPreset.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))"
                let outputURL = generateOutputURL(suffix: suffix)

                let result = try await videoExporter.export(
                    inputURL: videoURL,
                    outputURL: outputURL,
                    preset: selectedPreset
                ) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }

                NSWorkspace.shared.activateFileViewerSelecting([outputURL])

                let savings = result.inputSize - result.outputSize
                if savings > 0 {
                    processingStatus = "Saved \(formatFileSize(savings))"
                } else {
                    processingStatus = "Export complete"
                }

            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            isProcessing = false
        }
    }

    // MARK: - Trim Player

    private func setupTrimPlayer() {
        let player = AVPlayer(url: videoURL)
        player.volume = 0.5
        trimPlayer = player

        // Observe playback time
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        trimTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            trimPlayerTime = time.seconds
        }
    }

    private func cleanupTrimPlayer() {
        if let observer = trimTimeObserver, let player = trimPlayer {
            player.removeTimeObserver(observer)
        }
        trimTimeObserver = nil
        trimPlayer?.pause()
        trimPlayer = nil
    }

    private func seekTrimPlayer(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        trimPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func markTrimStart() {
        trimStart = trimPlayerTime
        // Ensure start doesn't exceed end
        if trimStart >= trimEnd {
            trimEnd = min(duration, trimStart + 1)
        }
    }

    private func markTrimEnd() {
        trimEnd = trimPlayerTime
        // Ensure end doesn't go below start
        if trimEnd <= trimStart {
            trimStart = max(0, trimEnd - 1)
        }
    }

    // MARK: - Helpers

    private func generateOutputURL(suffix: String) -> URL {
        let directory = videoURL.deletingLastPathComponent()
        let filename = videoURL.deletingPathExtension().lastPathComponent
        let ext = videoURL.pathExtension
        let outputURL = directory.appendingPathComponent("\(filename)\(suffix).\(ext)")
        // Fall back to temp directory if the source directory isn't writable
        // (sandbox can deny writes to .simarecord bundles in some cases)
        if FileManager.default.isWritableFile(atPath: directory.path) {
            return outputURL
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(filename)\(suffix).\(ext)")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatTimePrecise(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, frac)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Post Recording Window

class PostRecordingWindow: NSWindow {
    init(videoURL: URL, onDismiss: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 780),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        self.title = "Recording Complete"
        self.isReleasedWhenClosed = false
        self.center()

        let view = PostRecordingEditor(videoURL: videoURL, onDismiss: {
            onDismiss()
            self.close()
        })
        self.contentView = NSHostingView(rootView: view)
    }
}

// MARK: - AVPlayerView Wrapper (replaces VideoPlayer to avoid runtime crash)

struct TrimPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
