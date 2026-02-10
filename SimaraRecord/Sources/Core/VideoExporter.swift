//
//  VideoExporter.swift
//  OpenCapture
//
//  Provides preset-based video export with quality/size tradeoffs.
//  Allows users to re-encode recordings with different bitrates and resolutions.
//

import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - Export Presets

/// Available export presets with different quality and file size characteristics.
enum ExportPreset: String, CaseIterable, Identifiable {
    case original = "Original (No Re-encode)"
    case highQuality = "High Quality (8 Mbps)"
    case balanced = "Balanced (4 Mbps)"
    case smallFile = "Small File (720p, 2 Mbps)"
    case webOptimized = "Web Optimized (Fast Start)"

    var id: String { rawValue }

    /// Human-readable description of what this preset does.
    var description: String {
        switch self {
        case .original:
            return "Copies the video without re-encoding. Fastest export, same file size as original."
        case .highQuality:
            return "Re-encodes at 1080p with 8 Mbps bitrate. High quality, moderate compression."
        case .balanced:
            return "Re-encodes at 1080p with 4 Mbps bitrate. Good quality with smaller file size."
        case .smallFile:
            return "Scales down to 720p with 2 Mbps bitrate. Smaller files for easy sharing."
        case .webOptimized:
            return "Re-encodes at 1080p with 4 Mbps and fast-start enabled. Ideal for web streaming."
        }
    }

    /// Estimated size multiplier relative to original file size.
    /// Values less than 1.0 indicate compression, 1.0 means same size.
    var estimatedSizeMultiplier: Double {
        switch self {
        case .original:
            return 1.0
        case .highQuality:
            return 0.7  // Typically smaller than original due to more efficient encoding
        case .balanced:
            return 0.4
        case .smallFile:
            return 0.2
        case .webOptimized:
            return 0.4
        }
    }

    /// Target video bitrate in bits per second.
    var targetBitrate: Int {
        switch self {
        case .original:
            return 0  // Not used
        case .highQuality:
            return 8_000_000  // 8 Mbps
        case .balanced:
            return 4_000_000  // 4 Mbps
        case .smallFile:
            return 2_000_000  // 2 Mbps
        case .webOptimized:
            return 4_000_000  // 4 Mbps
        }
    }

    /// Target resolution height. nil means maintain original.
    var targetHeight: Int? {
        switch self {
        case .original, .highQuality, .balanced, .webOptimized:
            return nil  // Maintain original resolution (capped at 1080p for non-original)
        case .smallFile:
            return 720
        }
    }

    /// Maximum height for presets that maintain original but cap at 1080p.
    var maxHeight: Int {
        switch self {
        case .original:
            return Int.max  // No cap
        case .highQuality, .balanced, .webOptimized:
            return 1080
        case .smallFile:
            return 720
        }
    }

    /// Whether to optimize for network streaming (moov atom at front).
    var shouldOptimizeForNetworkUse: Bool {
        return self == .webOptimized
    }
}

// MARK: - Export Result

/// Result of a video export operation.
struct ExportResult {
    /// Size of the input file in bytes.
    let inputSize: Int64

    /// Size of the output file in bytes.
    let outputSize: Int64

    /// Compression ratio (inputSize / outputSize). Higher means more compression.
    var compressionRatio: Double {
        guard outputSize > 0 else { return 0 }
        return Double(inputSize) / Double(outputSize)
    }

    /// Time taken to complete the export in seconds.
    let duration: TimeInterval

    /// Human-readable summary of the export result.
    var summary: String {
        let inputMB = Double(inputSize) / 1_000_000
        let outputMB = Double(outputSize) / 1_000_000
        let savings = max(0, inputSize - outputSize)
        let savingsMB = Double(savings) / 1_000_000
        let savingsPercent = inputSize > 0 ? Double(savings) / Double(inputSize) * 100 : 0

        return String(format: "%.1f MB -> %.1f MB (saved %.1f MB, %.0f%% reduction) in %.1fs",
                      inputMB, outputMB, savingsMB, savingsPercent, duration)
    }
}

// MARK: - Export Errors

/// Errors that can occur during video export.
enum VideoExportError: LocalizedError {
    case inputFileNotFound
    case cannotReadAsset
    case cannotCreateExportSession
    case exportFailed(Error?)
    case exportCancelled
    case cannotCreateAssetWriter
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotCreateAssetReader
    case noVideoTrack
    case writingFailed(Error?)
    case invalidOutputURL

    var errorDescription: String? {
        switch self {
        case .inputFileNotFound:
            return "Input video file not found"
        case .cannotReadAsset:
            return "Cannot read the input video file"
        case .cannotCreateExportSession:
            return "Cannot create export session for this video"
        case .exportFailed(let error):
            return "Export failed: \(error?.localizedDescription ?? "unknown error")"
        case .exportCancelled:
            return "Export was cancelled"
        case .cannotCreateAssetWriter:
            return "Cannot create video writer for output"
        case .cannotAddVideoInput:
            return "Cannot configure video encoding"
        case .cannotAddAudioInput:
            return "Cannot configure audio encoding"
        case .cannotCreateAssetReader:
            return "Cannot read input video for processing"
        case .noVideoTrack:
            return "Input file contains no video"
        case .writingFailed(let error):
            return "Writing failed: \(error?.localizedDescription ?? "unknown error")"
        case .invalidOutputURL:
            return "Invalid output file location"
        }
    }
}

// MARK: - Video Exporter

/// Handles video export with various quality presets.
/// Provides both passthrough (no re-encoding) and transcoding options.
class VideoExporter {

    // MARK: - Properties

    /// Current export task, if any. Can be used for cancellation.
    private var currentExportSession: AVAssetExportSession?
    private var currentAssetReader: AVAssetReader?
    private var currentAssetWriter: AVAssetWriter?
    private var isCancelled = false

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Exports a video file using the specified preset.
    ///
    /// - Parameters:
    ///   - inputURL: URL of the source video file.
    ///   - outputURL: URL where the exported video will be saved.
    ///   - preset: The export preset to use for quality/size tradeoff.
    ///   - progress: Optional callback for progress updates (0.0 to 1.0).
    /// - Returns: ExportResult with size and timing information.
    /// - Throws: VideoExportError if export fails.
    func export(
        inputURL: URL,
        outputURL: URL,
        preset: ExportPreset,
        progress: ((Double) -> Void)? = nil
    ) async throws -> ExportResult {
        isCancelled = false
        let startTime = Date()

        // Validate input file exists
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw VideoExportError.inputFileNotFound
        }

        // Get input file size
        let inputSize = try getFileSize(url: inputURL)

        // Remove existing output file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Choose export method based on preset
        if preset == .original {
            try await exportPassthrough(inputURL: inputURL, outputURL: outputURL, progress: progress)
        } else {
            try await exportWithTranscoding(
                inputURL: inputURL,
                outputURL: outputURL,
                preset: preset,
                progress: progress
            )
        }

        // Get output file size
        let outputSize = try getFileSize(url: outputURL)
        let duration = Date().timeIntervalSince(startTime)

        return ExportResult(
            inputSize: inputSize,
            outputSize: outputSize,
            duration: duration
        )
    }

    /// Estimates the output file size for a given preset without actually exporting.
    ///
    /// - Parameters:
    ///   - inputURL: URL of the source video file.
    ///   - preset: The export preset to estimate for.
    /// - Returns: Estimated output size in bytes.
    /// - Throws: VideoExportError if the file cannot be analyzed.
    func estimateSize(inputURL: URL, preset: ExportPreset) async throws -> Int64 {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw VideoExportError.inputFileNotFound
        }

        let inputSize = try getFileSize(url: inputURL)

        if preset == .original {
            return inputSize
        }

        // Load asset to get video properties
        let asset = AVAsset(url: inputURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }

        let duration = try await asset.load(.duration).seconds
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // Calculate target dimensions
        let (_, targetHeight) = calculateTargetDimensions(
            originalWidth: Int(naturalSize.width),
            originalHeight: Int(naturalSize.height),
            preset: preset
        )

        // Estimate based on target bitrate and duration
        let videoBitrate = preset.targetBitrate
        let audioBitrate = 128_000  // 128 kbps AAC
        let totalBitrate = videoBitrate + audioBitrate

        // Factor in resolution scaling
        let originalPixels = naturalSize.width * naturalSize.height
        let targetPixels = Double(targetHeight) * (Double(targetHeight) * naturalSize.width / naturalSize.height)
        let resolutionFactor = min(1.0, targetPixels / originalPixels)

        // Estimate: (bitrate * duration) / 8 bytes, adjusted for resolution
        let estimatedBytes = Int64((Double(totalBitrate) * duration * resolutionFactor) / 8.0)

        // Add 10% overhead for container format
        return Int64(Double(estimatedBytes) * 1.1)
    }

    /// Cancels the current export operation.
    func cancel() {
        isCancelled = true
        currentExportSession?.cancelExport()
        currentAssetReader?.cancelReading()
        currentAssetWriter?.cancelWriting()
    }

    // MARK: - Private Methods

    /// Exports using passthrough (no re-encoding) via AVAssetExportSession.
    private func exportPassthrough(
        inputURL: URL,
        outputURL: URL,
        progress: ((Double) -> Void)?
    ) async throws {
        let asset = AVAsset(url: inputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw VideoExportError.cannotCreateExportSession
        }

        currentExportSession = exportSession

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        // Start progress monitoring
        let progressTask = Task {
            while !Task.isCancelled && exportSession.status == .exporting {
                progress?(Double(exportSession.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
            }
        }

        await exportSession.export()
        progressTask.cancel()

        currentExportSession = nil

        switch exportSession.status {
        case .completed:
            progress?(1.0)
        case .cancelled:
            throw VideoExportError.exportCancelled
        case .failed:
            throw VideoExportError.exportFailed(exportSession.error)
        default:
            throw VideoExportError.exportFailed(nil)
        }
    }

    /// Exports with transcoding using AVAssetReader/Writer for custom bitrate control.
    private func exportWithTranscoding(
        inputURL: URL,
        outputURL: URL,
        preset: ExportPreset,
        progress: ((Double) -> Void)?
    ) async throws {
        let asset = AVAsset(url: inputURL)

        // Load tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            throw VideoExportError.noVideoTrack
        }

        // Get video properties
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // Calculate target dimensions respecting aspect ratio
        let (targetWidth, targetHeight) = calculateTargetDimensions(
            originalWidth: Int(naturalSize.width),
            originalHeight: Int(naturalSize.height),
            preset: preset
        )

        // Determine if we need to scale
        let needsScaling = targetWidth != Int(naturalSize.width) || targetHeight != Int(naturalSize.height)

        // Create asset reader
        let assetReader: AVAssetReader
        do {
            assetReader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoExportError.cannotCreateAssetReader
        }
        currentAssetReader = assetReader

        // Configure video reader output
        let videoReaderOutput: AVAssetReaderOutput

        if needsScaling {
            // Use video composition for scaling
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: targetWidth, height: targetHeight)
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominalFrameRate > 0 ? nominalFrameRate : 30))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

            // Calculate scale transform
            let scaleX = CGFloat(targetWidth) / naturalSize.width
            let scaleY = CGFloat(targetHeight) / naturalSize.height
            let scale = CGAffineTransform(scaleX: scaleX, y: scaleY)
            layerInstruction.setTransform(transform.concatenating(scale), at: .zero)

            instruction.layerInstructions = [layerInstruction]
            composition.instructions = [instruction]

            let compositionOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            compositionOutput.videoComposition = composition
            videoReaderOutput = compositionOutput
        } else {
            // Direct video output without scaling
            videoReaderOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
        }

        guard assetReader.canAdd(videoReaderOutput) else {
            throw VideoExportError.cannotCreateAssetReader
        }
        assetReader.add(videoReaderOutput)

        // Configure audio reader output if audio exists
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            if assetReader.canAdd(output) {
                assetReader.add(output)
                audioReaderOutput = output
            }
        }

        // Create asset writer
        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw VideoExportError.cannotCreateAssetWriter
        }
        currentAssetWriter = assetWriter

        // Configure for web optimization if needed
        assetWriter.shouldOptimizeForNetworkUse = preset.shouldOptimizeForNetworkUse

        // Configure video writer input with target bitrate
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.targetBitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(nominalFrameRate > 0 ? nominalFrameRate : 30),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(nominalFrameRate > 0 ? nominalFrameRate : 30)
            ] as [String: Any]
        ]

        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = .identity  // Transform already applied in composition

        guard assetWriter.canAdd(videoWriterInput) else {
            throw VideoExportError.cannotAddVideoInput
        }
        assetWriter.add(videoWriterInput)

        // Configure audio writer input
        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false

            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                audioWriterInput = input
            }
        }

        // Start reading and writing
        guard assetReader.startReading() else {
            throw VideoExportError.cannotCreateAssetReader
        }

        guard assetWriter.startWriting() else {
            throw VideoExportError.cannotCreateAssetWriter
        }

        assetWriter.startSession(atSourceTime: .zero)

        let durationSeconds = duration.seconds

        // Process video and audio in parallel using dispatch groups
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Video processing
            group.addTask { [weak self] in
                try await self?.processTrack(
                    readerOutput: videoReaderOutput,
                    writerInput: videoWriterInput,
                    durationSeconds: durationSeconds,
                    progress: progress,
                    isVideo: true
                )
            }

            // Audio processing
            if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
                group.addTask { [weak self] in
                    try await self?.processTrack(
                        readerOutput: audioOutput,
                        writerInput: audioInput,
                        durationSeconds: durationSeconds,
                        progress: nil,  // Only report video progress
                        isVideo: false
                    )
                }
            }

            // Wait for all tracks to complete
            try await group.waitForAll()
        }

        // Finish writing
        videoWriterInput.markAsFinished()
        audioWriterInput?.markAsFinished()

        await assetWriter.finishWriting()

        currentAssetReader = nil
        currentAssetWriter = nil

        if let error = assetWriter.error {
            throw VideoExportError.writingFailed(error)
        }

        if isCancelled {
            // Clean up output file on cancellation
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoExportError.exportCancelled
        }

        progress?(1.0)
    }

    /// Processes a single track (video or audio) by reading and writing samples.
    private func processTrack(
        readerOutput: AVAssetReaderOutput,
        writerInput: AVAssetWriterInput,
        durationSeconds: Double,
        progress: ((Double) -> Void)?,
        isVideo: Bool
    ) async throws {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.opencapture.export.\(isVideo ? "video" : "audio")")

            writerInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                while writerInput.isReadyForMoreMediaData && !(self?.isCancelled ?? true) {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sampleBuffer) {
                            break
                        }

                        // Report progress for video track
                        if isVideo, let progressCallback = progress {
                            let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                            let progressValue = min(1.0, currentTime / durationSeconds)
                            DispatchQueue.main.async {
                                progressCallback(progressValue)
                            }
                        }
                    } else {
                        // No more samples
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }

                // Check if cancelled
                if self?.isCancelled ?? false {
                    writerInput.markAsFinished()
                    continuation.resume()
                }
            }
        }
    }

    /// Calculates target dimensions while maintaining aspect ratio.
    private func calculateTargetDimensions(
        originalWidth: Int,
        originalHeight: Int,
        preset: ExportPreset
    ) -> (width: Int, height: Int) {
        let maxHeight = preset.maxHeight

        // If original is smaller than max, keep original
        if originalHeight <= maxHeight {
            // Ensure even dimensions for H.264
            let evenWidth = (originalWidth / 2) * 2
            let evenHeight = (originalHeight / 2) * 2
            return (evenWidth, evenHeight)
        }

        // Scale down to max height while maintaining aspect ratio
        let aspectRatio = Double(originalWidth) / Double(originalHeight)
        var targetHeight = maxHeight
        var targetWidth = Int(Double(targetHeight) * aspectRatio)

        // Ensure even dimensions for H.264
        targetWidth = (targetWidth / 2) * 2
        targetHeight = (targetHeight / 2) * 2

        return (targetWidth, targetHeight)
    }

    /// Gets the file size in bytes for a given URL.
    private func getFileSize(url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int64 else {
            return 0
        }
        return size
    }
}
