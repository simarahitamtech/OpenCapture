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
    case proRes422 = "ProRes 422 (Editor Handoff) — Beta"
    case lossless = "Lossless Quality (HEVC, larger files)"
    case highQuality = "High Quality (12 Mbps)"
    case balanced = "Balanced (6 Mbps)"
    case smallFile = "Small File (720p, 2 Mbps)"
    case webOptimized = "Web Optimized (Fast Start)"

    var id: String { rawValue }

    /// Human-readable description of what this preset does.
    var description: String {
        switch self {
        case .original:
            return "Copies the video without re-encoding. Fastest export, same file size as original."
        case .proRes422:
            return "BETA: Apple ProRes 422 in MOV container, designed for handoff to Final Cut Pro, Premiere, or DaVinci Resolve. Currently routed through the standard polish pipeline — the final encode is ProRes but intermediate quality is still being tuned. Very large files (~5 GB per minute at 1080p)."
        case .lossless:
            return "HEVC (H.265) at 30 Mbps. Pristine quality with full chroma — matches the original screen. ~3× larger files than High Quality."
        case .highQuality:
            return "H.264 at 12 Mbps. Sharp recordings suitable for sharing and uploading."
        case .balanced:
            return "H.264 at 6 Mbps. Good quality with smaller file size."
        case .smallFile:
            return "Scales down to 720p with 2 Mbps. Smaller files for easy sharing."
        case .webOptimized:
            return "H.264 at 6 Mbps with fast-start enabled. Ideal for web streaming."
        }
    }

    /// True for presets that produce very large output and should show a
    /// warning before export.
    var producesLargeFiles: Bool {
        switch self {
        case .proRes422: return true
        default: return false
        }
    }

    /// Estimated size multiplier relative to original file size.
    /// Values less than 1.0 indicate compression, 1.0 means same size.
    var estimatedSizeMultiplier: Double {
        switch self {
        case .original:
            return 1.0
        case .proRes422:
            return 8.0   // ProRes 422 at ~660 Mbps — much larger than the HEVC source
        case .lossless:
            return 2.5
        case .highQuality:
            return 0.7
        case .balanced:
            return 0.4
        case .smallFile:
            return 0.2
        case .webOptimized:
            return 0.4
        }
    }

    /// Target video bitrate in bits per second. Zero means codec-controlled
    /// (ProRes uses fixed per-frame allocation, not a bitrate target).
    var targetBitrate: Int {
        switch self {
        case .original:
            return 0  // Not used (no re-encode)
        case .proRes422:
            return 0  // ProRes is intra-frame at a fixed quality, AVAssetWriter handles allocation
        case .lossless:
            return 30_000_000  // 30 Mbps HEVC
        case .highQuality:
            return 12_000_000  // 12 Mbps H.264
        case .balanced:
            return 6_000_000   // 6 Mbps H.264
        case .smallFile:
            return 2_000_000   // 2 Mbps H.264
        case .webOptimized:
            return 6_000_000   // 6 Mbps H.264
        }
    }

    /// Video codec used for this preset.
    var codec: AVVideoCodecType {
        switch self {
        case .proRes422:
            return .proRes422
        case .lossless:
            return .hevc
        default:
            return .h264
        }
    }

    /// Container/file-type used for the output. ProRes is only valid inside a
    /// .mov container — MP4 doesn't support it. Everything else uses .mp4.
    var fileType: AVFileType {
        switch self {
        case .proRes422:
            return .mov
        default:
            return .mp4
        }
    }

    /// File extension that matches the container. Drives the output filename.
    var fileExtension: String {
        switch self {
        case .proRes422:
            return "mov"
        default:
            return "mp4"
        }
    }

    /// Target resolution height. nil means maintain original.
    var targetHeight: Int? {
        switch self {
        case .original, .proRes422, .lossless, .highQuality, .balanced, .webOptimized:
            return nil  // Maintain original resolution (capped via maxHeight for some)
        case .smallFile:
            return 720
        }
    }

    /// Maximum height for presets that maintain original but cap at 1080p.
    /// ProRes / Lossless intentionally have no cap so 2x supersampled captures
    /// stay full native resolution.
    var maxHeight: Int {
        switch self {
        case .original, .proRes422, .lossless:
            return Int.max
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
        // Passthrough preserves the original codec — match the container to
        // the output URL's extension so HEVC source.mov → polished.mov and
        // legacy H.264 sources keep .mp4.
        exportSession.outputFileType = outputURL.pathExtension.lowercased() == "mov" ? .mov : .mp4

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
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: preset.fileType)
        } catch {
            throw VideoExportError.cannotCreateAssetWriter
        }
        currentAssetWriter = assetWriter

        // Configure for web optimization if needed
        assetWriter.shouldOptimizeForNetworkUse = preset.shouldOptimizeForNetworkUse

        // Configure video writer input. Codec-specific properties:
        // - H.264 (compatible delivery): explicit High Auto Level profile,
        //   bitrate target, GOP length, expected source frame rate.
        // - HEVC (Lossless): same as H.264 but profile chosen automatically
        //   by the encoder based on bitrate.
        // - ProRes 422 (editor handoff): no compression properties at all —
        //   ProRes is intra-frame (every frame is a keyframe by definition)
        //   and fixed-quality, so AVAssetWriter rejects MaxKeyFrameInterval,
        //   bitrate, and profile level for codec type 'apcn'.
        // Display P3 color metadata applies to every codec so the wide gamut
        // captured by SCStream survives the re-encode.
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: preset.codec,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] as [String: String]
        ]

        if preset.codec != .proRes422 {
            var compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: preset.targetBitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(nominalFrameRate > 0 ? nominalFrameRate : 30),
                AVVideoExpectedSourceFrameRateKey: Int(nominalFrameRate > 0 ? nominalFrameRate : 30)
            ]
            if preset.codec == .h264 {
                compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
        }

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
