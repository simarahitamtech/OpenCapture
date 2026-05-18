//
//  SilenceRemover.swift
//  OpenCapture
//
//  Post-processing utility to remove silent portions from recorded videos.
//  Uses AVFoundation for audio analysis and Accelerate (vDSP) for efficient RMS calculation.
//

import AVFoundation
import Accelerate
import CoreMedia

// MARK: - Silence Remover

/// Analyzes and removes silent portions from video recordings to tighten up content.
///
/// This class provides two main operations:
/// 1. `analyze(url:)` - Preview what segments will be identified as speech vs silence
/// 2. `process(inputURL:outputURL:progress:)` - Actually remove silence and export a new video
///
/// The algorithm:
/// - Reads audio in ~100ms chunks
/// - Calculates RMS amplitude using vDSP for performance
/// - Converts to decibels and compares against threshold
/// - Identifies silent segments longer than `minSilenceDuration`
/// - Reassembles video+audio keeping speech segments with configurable padding
class SilenceRemover {

    // MARK: - Configuration

    /// Amplitude threshold below which audio is considered silence (in decibels).
    /// Default: -40 dB (very quiet audio is treated as silence)
    var silenceThreshold: Float = -40

    /// Minimum duration a silent segment must have to be removed (in seconds).
    /// Shorter silences are kept to maintain natural speech rhythm.
    /// Default: 0.5 seconds
    var minSilenceDuration: TimeInterval = 0.5

    /// Padding duration to keep around speech segments (in seconds).
    /// Prevents abrupt cuts by keeping a small buffer before/after speech.
    /// Default: 0.1 seconds
    var paddingDuration: TimeInterval = 0.1

    /// Duration of each audio chunk to analyze (in seconds).
    /// Smaller values give more precision but slower analysis.
    private let analysisChunkDuration: TimeInterval = 0.1  // 100ms

    // MARK: - Types

    /// Represents a segment of the audio/video timeline
    struct Segment: Equatable, Sendable {
        /// Start time of the segment in seconds
        let startTime: TimeInterval
        /// End time of the segment in seconds
        let endTime: TimeInterval
        /// Whether this segment contains speech (true) or silence (false)
        let isSpeech: Bool

        /// Duration of the segment in seconds
        var duration: TimeInterval {
            endTime - startTime
        }
    }

    /// Result of the silence removal process
    struct Result: Sendable {
        /// Total duration of the original video
        let originalDuration: TimeInterval
        /// Total duration of the processed video
        let newDuration: TimeInterval
        /// Total amount of silence removed
        let silenceRemoved: TimeInterval
        /// Number of silent segments that were removed
        let segmentsRemoved: Int

        /// Percentage of the video that was silence
        var silencePercentage: Double {
            guard originalDuration > 0 else { return 0 }
            return (silenceRemoved / originalDuration) * 100
        }
    }

    /// Errors that can occur during silence removal
    enum Error: LocalizedError {
        case noAudioTrack
        case failedToReadAudio(Swift.Error?)
        case failedToCreateComposition
        case failedToExport(Swift.Error?)
        case cancelled
        case invalidAsset
        case noSpeechDetected

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "This recording has no audio. Turn off Remove Silence in the post-editor to continue."
            case .failedToReadAudio(let error):
                return "Failed to read audio: \(error?.localizedDescription ?? "unknown error")"
            case .failedToCreateComposition:
                return "Failed to create composition for export"
            case .failedToExport(let error):
                return "Failed to export video: \(error?.localizedDescription ?? "unknown error")"
            case .cancelled:
                return "Operation was cancelled"
            case .invalidAsset:
                return "Invalid or corrupted video file"
            case .noSpeechDetected:
                return "No speech detected in the entire recording"
            }
        }
    }

    // MARK: - Initialization

    init() {}

    /// Convenience initializer with custom configuration
    init(silenceThreshold: Float = -40, minSilenceDuration: TimeInterval = 0.5, paddingDuration: TimeInterval = 0.1) {
        self.silenceThreshold = silenceThreshold
        self.minSilenceDuration = minSilenceDuration
        self.paddingDuration = paddingDuration
    }

    // MARK: - Public API

    /// Analyzes a video file and returns segments classified as speech or silence.
    ///
    /// Use this to preview what will be cut before actually processing the video.
    ///
    /// - Parameter url: URL of the video file to analyze
    /// - Returns: Array of segments with their classification
    /// - Throws: `SilenceRemover.Error` if analysis fails
    func analyze(url: URL) async throws -> [Segment] {
        let asset = AVAsset(url: url)

        // Validate asset is readable
        guard try await asset.load(.isReadable) else {
            throw Error.invalidAsset
        }

        // Get the audio track
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw Error.noAudioTrack
        }

        // Get total duration
        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)

        // Analyze audio amplitude in chunks
        let amplitudes = try await analyzeAudioAmplitudes(asset: asset, audioTrack: audioTrack)

        // Convert amplitudes to segments
        let rawSegments = classifySegments(amplitudes: amplitudes, totalDuration: totalDuration)

        // Merge short segments and apply minimum duration rules
        let mergedSegments = mergeSegments(rawSegments)

        return mergedSegments
    }

    /// Processes a video file, removing silent portions and exporting a new video.
    ///
    /// - Parameters:
    ///   - inputURL: URL of the source video file
    ///   - outputURL: URL where the processed video will be saved
    ///   - progress: Optional callback reporting export progress (0.0 to 1.0)
    /// - Returns: Result containing statistics about the processing
    /// - Throws: `SilenceRemover.Error` if processing fails
    func process(
        inputURL: URL,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws -> Result {
        // Analyze to get segments
        let segments = try await analyze(url: inputURL)

        // Filter to only speech segments
        let speechSegments = segments.filter { $0.isSpeech }

        guard !speechSegments.isEmpty else {
            throw Error.noSpeechDetected
        }

        // Load asset
        let asset = AVAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let originalDuration = CMTimeGetSeconds(duration)

        // Create composition with speech segments
        let composition = try await createComposition(
            from: asset,
            keepingSegments: speechSegments
        )

        // Calculate new duration
        let newDuration = speechSegments.reduce(0.0) { $0 + $1.duration }

        // Export the composition
        try await exportComposition(
            composition,
            to: outputURL,
            progress: progress
        )

        // Calculate statistics
        let silenceRemoved = originalDuration - newDuration
        let silentSegmentCount = segments.filter { !$0.isSpeech && $0.duration >= minSilenceDuration }.count

        return Result(
            originalDuration: originalDuration,
            newDuration: newDuration,
            silenceRemoved: silenceRemoved,
            segmentsRemoved: silentSegmentCount
        )
    }

    /// Process a video keeping only the supplied segments (skipping internal analysis).
    func process(
        inputURL: URL,
        outputURL: URL,
        keepingSegments speechSegments: [Segment],
        progress: ((Double) -> Void)? = nil
    ) async throws -> Result {
        guard !speechSegments.isEmpty else {
            throw Error.noSpeechDetected
        }

        let asset = AVAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let originalDuration = CMTimeGetSeconds(duration)

        let composition = try await createComposition(
            from: asset,
            keepingSegments: speechSegments
        )

        let newDuration = speechSegments.reduce(0.0) { $0 + $1.duration }

        try await exportComposition(
            composition,
            to: outputURL,
            progress: progress
        )

        let silenceRemoved = originalDuration - newDuration
        return Result(
            originalDuration: originalDuration,
            newDuration: newDuration,
            silenceRemoved: silenceRemoved,
            segmentsRemoved: 0
        )
    }

    // MARK: - Audio Analysis

    /// Analyzes audio track and returns amplitude (in dB) for each chunk
    private func analyzeAudioAmplitudes(
        asset: AVAsset,
        audioTrack: AVAssetTrack
    ) async throws -> [(time: TimeInterval, amplitude: Float)] {
        // Configure asset reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Error.failedToReadAudio(error)
        }

        // Configure output settings for PCM float samples
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1  // Mix down to mono for analysis
        ]

        let trackOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw Error.failedToReadAudio(nil)
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw Error.failedToReadAudio(reader.error)
        }

        // Process audio samples
        var amplitudes: [(time: TimeInterval, amplitude: Float)] = []
        let sampleRate: Double = 44100
        let samplesPerChunk = Int(sampleRate * analysisChunkDuration)

        var sampleBuffer: [Float] = []
        var currentTime: TimeInterval = 0

        while let sampleBufferRef = trackOutput.copyNextSampleBuffer() {
            defer { /* CMSampleBuffer is automatically released */ }

            // Get audio buffer list
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBufferRef) else {
                continue
            }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )

            guard let data = dataPointer else { continue }

            // Convert to float array
            let floatCount = length / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
            let floatBuffer = UnsafeBufferPointer(start: floatPointer, count: floatCount)

            sampleBuffer.append(contentsOf: floatBuffer)

            // Process complete chunks
            while sampleBuffer.count >= samplesPerChunk {
                let chunk = Array(sampleBuffer.prefix(samplesPerChunk))
                sampleBuffer.removeFirst(samplesPerChunk)

                let rms = calculateRMS(samples: chunk)
                let db = rmsToDecibels(rms)

                amplitudes.append((time: currentTime, amplitude: db))
                currentTime += analysisChunkDuration
            }
        }

        // Process remaining samples
        if !sampleBuffer.isEmpty {
            let rms = calculateRMS(samples: sampleBuffer)
            let db = rmsToDecibels(rms)
            amplitudes.append((time: currentTime, amplitude: db))
        }

        if reader.status == .failed {
            throw Error.failedToReadAudio(reader.error)
        }

        return amplitudes
    }

    /// Calculates RMS (Root Mean Square) of audio samples using vDSP for performance
    private func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        return rms
    }

    /// Converts RMS amplitude to decibels
    private func rmsToDecibels(_ rms: Float) -> Float {
        guard rms > 0 else { return -Float.infinity }
        return 20 * log10(rms)
    }

    // MARK: - Segment Classification

    /// Classifies amplitude data into speech/silence segments
    private func classifySegments(
        amplitudes: [(time: TimeInterval, amplitude: Float)],
        totalDuration: TimeInterval
    ) -> [Segment] {
        guard !amplitudes.isEmpty else { return [] }

        var segments: [Segment] = []
        var segmentStart = 0.0
        var isSpeech = amplitudes[0].amplitude >= silenceThreshold

        for (index, sample) in amplitudes.enumerated() {
            let currentIsSpeech = sample.amplitude >= silenceThreshold

            if currentIsSpeech != isSpeech {
                // Transition detected
                let segmentEnd = sample.time
                segments.append(Segment(
                    startTime: segmentStart,
                    endTime: segmentEnd,
                    isSpeech: isSpeech
                ))
                segmentStart = segmentEnd
                isSpeech = currentIsSpeech
            }

            // Handle last chunk
            if index == amplitudes.count - 1 {
                segments.append(Segment(
                    startTime: segmentStart,
                    endTime: totalDuration,
                    isSpeech: isSpeech
                ))
            }
        }

        return segments
    }

    /// Merges segments, applying minimum duration rules and padding
    private func mergeSegments(_ segments: [Segment]) -> [Segment] {
        guard !segments.isEmpty else { return [] }

        var result: [Segment] = []

        for segment in segments {
            if segment.isSpeech {
                // Apply padding to speech segments
                let paddedStart = max(0, segment.startTime - paddingDuration)
                let paddedEnd = segment.endTime + paddingDuration

                // Try to merge with previous segment if they overlap
                if let lastIndex = result.indices.last,
                   result[lastIndex].isSpeech,
                   paddedStart <= result[lastIndex].endTime {
                    // Extend the previous speech segment
                    let extended = Segment(
                        startTime: result[lastIndex].startTime,
                        endTime: max(result[lastIndex].endTime, paddedEnd),
                        isSpeech: true
                    )
                    result[lastIndex] = extended
                } else {
                    result.append(Segment(
                        startTime: paddedStart,
                        endTime: paddedEnd,
                        isSpeech: true
                    ))
                }
            } else {
                // Silence segment - only keep if it meets minimum duration
                if segment.duration >= minSilenceDuration {
                    result.append(segment)
                } else {
                    // Short silence - merge with previous speech if exists
                    if let lastIndex = result.indices.last, result[lastIndex].isSpeech {
                        let extended = Segment(
                            startTime: result[lastIndex].startTime,
                            endTime: segment.endTime,
                            isSpeech: true
                        )
                        result[lastIndex] = extended
                    } else {
                        // Convert short silence to speech
                        result.append(Segment(
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            isSpeech: true
                        ))
                    }
                }
            }
        }

        // Final pass: merge adjacent speech segments
        var finalResult: [Segment] = []
        for segment in result {
            if let lastIndex = finalResult.indices.last,
               finalResult[lastIndex].isSpeech && segment.isSpeech {
                // Merge adjacent speech segments
                let merged = Segment(
                    startTime: finalResult[lastIndex].startTime,
                    endTime: segment.endTime,
                    isSpeech: true
                )
                finalResult[lastIndex] = merged
            } else {
                finalResult.append(segment)
            }
        }

        return finalResult
    }

    // MARK: - Composition

    /// Creates an AVMutableComposition containing only the speech segments
    private func createComposition(
        from asset: AVAsset,
        keepingSegments segments: [Segment]
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()

        // Load tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Create composition tracks
        var compositionVideoTrack: AVMutableCompositionTrack?
        var compositionAudioTrack: AVMutableCompositionTrack?

        if let videoTrack = videoTracks.first {
            compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )

            // Copy video settings
            if let compTrack = compositionVideoTrack {
                let transform = try await videoTrack.load(.preferredTransform)
                compTrack.preferredTransform = transform
            }
        }

        if let audioTrack = audioTracks.first {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        guard compositionVideoTrack != nil || compositionAudioTrack != nil else {
            throw Error.failedToCreateComposition
        }

        // Get asset duration for clamping
        let assetDuration = try await asset.load(.duration)
        let assetDurationSeconds = CMTimeGetSeconds(assetDuration)

        // Insert each speech segment
        var insertTime = CMTime.zero

        for segment in segments {
            // Clamp segment to asset bounds
            let clampedStart = max(0, segment.startTime)
            let clampedEnd = min(segment.endTime, assetDurationSeconds)

            guard clampedEnd > clampedStart else { continue }

            let startTime = CMTime(seconds: clampedStart, preferredTimescale: 600)
            let endTime = CMTime(seconds: clampedEnd, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            // Insert video
            if let compositionVideoTrack = compositionVideoTrack,
               let videoTrack = videoTracks.first {
                do {
                    try compositionVideoTrack.insertTimeRange(
                        timeRange,
                        of: videoTrack,
                        at: insertTime
                    )
                } catch {
                    print("⚠️ Failed to insert video segment: \(error)")
                }
            }

            // Insert audio
            if let compositionAudioTrack = compositionAudioTrack,
               let audioTrack = audioTracks.first {
                do {
                    try compositionAudioTrack.insertTimeRange(
                        timeRange,
                        of: audioTrack,
                        at: insertTime
                    )
                } catch {
                    print("⚠️ Failed to insert audio segment: \(error)")
                }
            }

            // Advance insert position
            let segmentDuration = CMTimeSubtract(endTime, startTime)
            insertTime = CMTimeAdd(insertTime, segmentDuration)
        }

        return composition
    }

    // MARK: - Export

    /// Exports the composition to a file
    private func exportComposition(
        _ composition: AVMutableComposition,
        to outputURL: URL,
        progress: ((Double) -> Void)?
    ) async throws {
        // Remove existing file
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Create export session
        // Use highest quality preset that supports passthrough when possible
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw Error.failedToExport(nil)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        // Progress monitoring task
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                let currentProgress = Double(exportSession.progress)
                await MainActor.run {
                    progress?(currentProgress)
                }
            }
        }

        // Export
        await exportSession.export()

        // Cancel progress monitoring
        progressTask.cancel()

        // Report completion
        await MainActor.run {
            progress?(1.0)
        }

        // Check result
        switch exportSession.status {
        case .completed:
            print("✅ Silence removal export completed: \(outputURL.path)")
        case .cancelled:
            throw Error.cancelled
        case .failed:
            throw Error.failedToExport(exportSession.error)
        default:
            throw Error.failedToExport(nil)
        }
    }
}

// MARK: - Convenience Extensions

extension SilenceRemover.Segment: CustomStringConvertible {
    var description: String {
        let type = isSpeech ? "Speech" : "Silence"
        return "\(type): \(String(format: "%.2f", startTime))s - \(String(format: "%.2f", endTime))s (\(String(format: "%.2f", duration))s)"
    }
}

extension SilenceRemover.Result: CustomStringConvertible {
    var description: String {
        """
        Silence Removal Results:
        - Original duration: \(String(format: "%.1f", originalDuration))s
        - New duration: \(String(format: "%.1f", newDuration))s
        - Silence removed: \(String(format: "%.1f", silenceRemoved))s (\(String(format: "%.1f", silencePercentage))%)
        - Segments removed: \(segmentsRemoved)
        """
    }
}
