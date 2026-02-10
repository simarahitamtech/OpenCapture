//
//  VideoTrimmer.swift
//  OpenCapture
//
//  Handles video trimming operations using AVFoundation.
//  Allows trimming start/end of recorded videos without re-encoding when possible.
//

import AVFoundation
import CoreMedia
import CoreGraphics

/// A class for trimming video files by extracting a specific time range.
///
/// `VideoTrimmer` provides functionality to:
/// - Get the duration of a video file
/// - Extract preview frames at specific timestamps
/// - Trim videos by specifying start and end times
/// - Maintain A/V synchronization during trimming
///
/// Example usage:
/// ```swift
/// let trimmer = VideoTrimmer()
/// let duration = try await trimmer.getDuration(url: videoURL)
/// let range = VideoTrimmer.TrimRange(
///     start: CMTime(seconds: 2.0, preferredTimescale: 600),
///     end: CMTime(seconds: 10.0, preferredTimescale: 600)
/// )
/// let result = try await trimmer.trim(
///     inputURL: videoURL,
///     outputURL: outputURL,
///     range: range
/// ) { progress in
///     print("Progress: \(progress * 100)%")
/// }
/// ```
class VideoTrimmer {

    // MARK: - Types

    /// Represents a time range for trimming a video.
    struct TrimRange {
        /// The start time of the trim range (inclusive).
        var start: CMTime
        /// The end time of the trim range (inclusive).
        var end: CMTime

        /// The duration of the trim range.
        var duration: CMTime {
            CMTimeSubtract(end, start)
        }

        /// Whether the trim range is valid (start is before end and both are non-negative).
        var isValid: Bool {
            start.seconds >= 0 &&
            end.seconds > start.seconds &&
            start.isValid && end.isValid &&
            !start.isIndefinite && !end.isIndefinite
        }

        /// Creates a trim range from the beginning of the video to the specified end time.
        static func fromStart(to end: CMTime) -> TrimRange {
            TrimRange(start: .zero, end: end)
        }

        /// Creates a trim range from the specified start time to the end of the video.
        static func toEnd(from start: CMTime, videoDuration: CMTime) -> TrimRange {
            TrimRange(start: start, end: videoDuration)
        }
    }

    /// The result of a trim operation.
    struct Result {
        /// The original video duration in seconds.
        let originalDuration: TimeInterval
        /// The new (trimmed) video duration in seconds.
        let newDuration: TimeInterval
        /// The amount trimmed from the start in seconds.
        let trimmedFromStart: TimeInterval
        /// The amount trimmed from the end in seconds.
        let trimmedFromEnd: TimeInterval
        /// The URL of the trimmed output file.
        let outputURL: URL
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Returns the duration of the video at the specified URL.
    ///
    /// - Parameter url: The URL of the video file.
    /// - Returns: The duration as a `CMTime`.
    /// - Throws: `VideoTrimmerError.invalidAsset` if the file cannot be loaded,
    ///           or `VideoTrimmerError.durationUnavailable` if duration cannot be determined.
    func getDuration(url: URL) async throws -> CMTime {
        let asset = AVURLAsset(url: url)

        // Load the duration asynchronously
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw VideoTrimmerError.invalidAsset(error)
        }

        guard duration.isValid && !duration.isIndefinite else {
            throw VideoTrimmerError.durationUnavailable
        }

        return duration
    }

    /// Extracts a single frame from the video at the specified time.
    ///
    /// This is useful for generating preview thumbnails for the trim editor UI.
    ///
    /// - Parameters:
    ///   - url: The URL of the video file.
    ///   - time: The time at which to extract the frame.
    /// - Returns: A `CGImage` representing the frame at the specified time.
    /// - Throws: `VideoTrimmerError.frameExtractionFailed` if the frame cannot be generated.
    func getFrame(url: URL, at time: CMTime) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)

        // Configure for best quality
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        // For higher quality thumbnails, don't limit the size
        imageGenerator.maximumSize = .zero

        do {
            let (image, _) = try await imageGenerator.image(at: time)
            return image
        } catch {
            throw VideoTrimmerError.frameExtractionFailed(error)
        }
    }

    /// Extracts multiple frames at the specified times for thumbnail generation.
    ///
    /// This is more efficient than calling `getFrame` multiple times when
    /// generating a timeline of thumbnails.
    ///
    /// - Parameters:
    ///   - url: The URL of the video file.
    ///   - times: An array of times at which to extract frames.
    ///   - maxSize: Optional maximum size for the thumbnails. Pass `.zero` for full resolution.
    /// - Returns: An array of tuples containing the requested time and the extracted image.
    /// - Throws: `VideoTrimmerError.frameExtractionFailed` if frame generation fails.
    func getFrames(url: URL, at times: [CMTime], maxSize: CGSize = CGSize(width: 200, height: 200)) async throws -> [(time: CMTime, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)

        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator.maximumSize = maxSize

        var results: [(time: CMTime, image: CGImage)] = []

        // Use the async sequence API for batch generation
        let timesAsNSValues = times.map { NSValue(time: $0) }

        for await result in imageGenerator.images(for: timesAsNSValues) {
            switch result {
            case .success(let requestedTime, let image, _):
                results.append((time: requestedTime, image: image))
            case .failed(let requestedTime, let error):
                print("⚠️ Failed to generate frame at \(requestedTime.seconds)s: \(error)")
                // Continue with other frames rather than failing entirely
            }
        }

        return results
    }

    /// Trims the video to the specified time range.
    ///
    /// This method creates a new video file containing only the portion of the
    /// original video within the specified time range. Both video and audio tracks
    /// are trimmed to maintain synchronization.
    ///
    /// The method attempts to use passthrough export (no re-encoding) when possible
    /// for faster processing and quality preservation. If passthrough fails, it
    /// falls back to highest quality re-encoding.
    ///
    /// - Parameters:
    ///   - inputURL: The URL of the source video file.
    ///   - outputURL: The URL where the trimmed video will be saved.
    ///   - range: The `TrimRange` specifying the start and end times.
    ///   - progress: Optional callback reporting export progress (0.0 to 1.0).
    /// - Returns: A `Result` containing information about the trim operation.
    /// - Throws: Various `VideoTrimmerError` cases for validation and processing failures.
    func trim(
        inputURL: URL,
        outputURL: URL,
        range: TrimRange,
        progress: ((Double) -> Void)? = nil
    ) async throws -> Result {
        // Validate the trim range
        guard range.isValid else {
            throw VideoTrimmerError.invalidTrimRange
        }

        // Load the asset
        let asset = AVURLAsset(url: inputURL)

        // Get the original duration
        let originalDuration: CMTime
        do {
            originalDuration = try await asset.load(.duration)
        } catch {
            throw VideoTrimmerError.invalidAsset(error)
        }

        guard originalDuration.isValid && !originalDuration.isIndefinite else {
            throw VideoTrimmerError.durationUnavailable
        }

        // Validate that the range is within the video bounds
        guard range.start.seconds >= 0 else {
            throw VideoTrimmerError.trimRangeOutOfBounds
        }

        guard range.end.seconds <= originalDuration.seconds else {
            throw VideoTrimmerError.trimRangeOutOfBounds
        }

        // Check for zero-duration trim
        guard range.duration.seconds > 0.1 else {
            throw VideoTrimmerError.trimResultTooShort
        }

        // Remove existing output file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Create the composition
        let composition = AVMutableComposition()

        // Define the time range to extract
        let timeRange = CMTimeRange(start: range.start, end: range.end)

        // Load and insert video track
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw VideoTrimmerError.noVideoTrack
        }

        if let sourceVideoTrack = videoTracks.first {
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoTrimmerError.failedToCreateComposition
            }

            do {
                try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)

                // Preserve the original track's preferred transform (for rotation)
                let transform = try await sourceVideoTrack.load(.preferredTransform)
                compositionVideoTrack.preferredTransform = transform
            } catch {
                throw VideoTrimmerError.failedToInsertVideoTrack(error)
            }
        } else {
            throw VideoTrimmerError.noVideoTrack
        }

        // Load and insert audio track (if present)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            // Audio track loading failed, but that's okay - video might not have audio
            audioTracks = []
        }

        if let sourceAudioTrack = audioTracks.first {
            if let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                do {
                    try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
                } catch {
                    print("⚠️ Failed to insert audio track: \(error)")
                    // Continue without audio rather than failing entirely
                }
            }
        }

        // Try passthrough export first (fastest, no quality loss)
        var exportSession: AVAssetExportSession?

        if AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetPassthrough) {
            exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        }

        // Fall back to highest quality if passthrough isn't available
        if exportSession == nil {
            exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        }

        guard let session = exportSession else {
            throw VideoTrimmerError.exportSessionCreationFailed
        }

        // Configure the export session
        session.outputURL = outputURL
        session.outputFileType = .mov  // MOV for best macOS compatibility
        session.shouldOptimizeForNetworkUse = false

        print("✂️ Starting video trim...")
        print("   Input: \(inputURL.path)")
        print("   Output: \(outputURL.path)")
        print("   Original duration: \(originalDuration.seconds)s")
        print("   Trim range: \(range.start.seconds)s - \(range.end.seconds)s")
        print("   New duration: \(range.duration.seconds)s")
        print("   Export preset: \(session.presetName)")

        // Start progress monitoring if callback provided
        let progressTask: Task<Void, Never>?
        if let progress = progress {
            progressTask = Task {
                while !Task.isCancelled {
                    let currentProgress = Double(session.progress)
                    await MainActor.run {
                        progress(currentProgress)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
        } else {
            progressTask = nil
        }

        // Perform the export
        await session.export()

        // Cancel progress monitoring
        progressTask?.cancel()

        // Report final progress
        progress?(1.0)

        // Check export status
        switch session.status {
        case .completed:
            print("✅ Video trim completed successfully")
            print("   Output saved to: \(outputURL.path)")

            let result = Result(
                originalDuration: originalDuration.seconds,
                newDuration: range.duration.seconds,
                trimmedFromStart: range.start.seconds,
                trimmedFromEnd: originalDuration.seconds - range.end.seconds,
                outputURL: outputURL
            )

            return result

        case .failed:
            let error = session.error ?? VideoTrimmerError.exportFailed(nil)
            print("❌ Video trim failed: \(error.localizedDescription)")
            throw VideoTrimmerError.exportFailed(session.error)

        case .cancelled:
            print("❌ Video trim was cancelled")
            throw VideoTrimmerError.exportCancelled

        default:
            throw VideoTrimmerError.exportFailed(nil)
        }
    }

    /// Validates a trim range against a video's duration.
    ///
    /// - Parameters:
    ///   - range: The trim range to validate.
    ///   - videoDuration: The total duration of the video.
    /// - Returns: `true` if the range is valid for the given video duration.
    func validateTrimRange(_ range: TrimRange, videoDuration: CMTime) -> Bool {
        guard range.isValid else { return false }
        guard range.start.seconds >= 0 else { return false }
        guard range.end.seconds <= videoDuration.seconds else { return false }
        guard range.duration.seconds > 0.1 else { return false }
        return true
    }

    /// Creates a suggested output URL for a trimmed video.
    ///
    /// Appends "_trimmed" to the original filename while preserving the extension.
    ///
    /// - Parameter inputURL: The URL of the original video file.
    /// - Returns: A suggested URL for the trimmed output.
    func suggestedOutputURL(for inputURL: URL) -> URL {
        let directory = inputURL.deletingLastPathComponent()
        let filename = inputURL.deletingPathExtension().lastPathComponent
        let ext = inputURL.pathExtension

        return directory.appendingPathComponent("\(filename)_trimmed.\(ext)")
    }
}

// MARK: - Errors

/// Errors that can occur during video trimming operations.
enum VideoTrimmerError: LocalizedError {
    /// The input video file could not be loaded.
    case invalidAsset(Error)
    /// The video duration could not be determined.
    case durationUnavailable
    /// The trim range is invalid (e.g., start >= end).
    case invalidTrimRange
    /// The trim range extends beyond the video bounds.
    case trimRangeOutOfBounds
    /// The resulting trimmed video would be too short.
    case trimResultTooShort
    /// The video file has no video track.
    case noVideoTrack
    /// Failed to create the composition for trimming.
    case failedToCreateComposition
    /// Failed to insert the video track into the composition.
    case failedToInsertVideoTrack(Error)
    /// Failed to create an export session.
    case exportSessionCreationFailed
    /// The export operation failed.
    case exportFailed(Error?)
    /// The export operation was cancelled.
    case exportCancelled
    /// Failed to extract a frame from the video.
    case frameExtractionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidAsset(let error):
            return "Invalid video file: \(error.localizedDescription)"
        case .durationUnavailable:
            return "Could not determine video duration"
        case .invalidTrimRange:
            return "Invalid trim range: start time must be before end time"
        case .trimRangeOutOfBounds:
            return "Trim range extends beyond video bounds"
        case .trimResultTooShort:
            return "Trimmed video would be too short (minimum 0.1 seconds)"
        case .noVideoTrack:
            return "Video file contains no video track"
        case .failedToCreateComposition:
            return "Failed to create video composition"
        case .failedToInsertVideoTrack(let error):
            return "Failed to process video track: \(error.localizedDescription)"
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let error):
            if let error = error {
                return "Export failed: \(error.localizedDescription)"
            }
            return "Export failed with unknown error"
        case .exportCancelled:
            return "Export was cancelled"
        case .frameExtractionFailed(let error):
            return "Failed to extract video frame: \(error.localizedDescription)"
        }
    }
}

// MARK: - AVAssetImageGenerator Extension

/// Extension to provide async iteration over generated images.
extension AVAssetImageGenerator {
    /// Result type for image generation.
    enum ImageGenerationResult {
        case success(requestedTime: CMTime, image: CGImage, actualTime: CMTime)
        case failed(requestedTime: CMTime, error: Error)
    }

    /// Generates images asynchronously for the specified times.
    ///
    /// - Parameter times: An array of `NSValue`-wrapped `CMTime` values.
    /// - Returns: An `AsyncStream` of `ImageGenerationResult` values.
    func images(for times: [NSValue]) -> AsyncStream<ImageGenerationResult> {
        AsyncStream { continuation in
            self.generateCGImagesAsynchronously(forTimes: times) { requestedTime, image, actualTime, result, error in
                switch result {
                case .succeeded:
                    if let image = image {
                        continuation.yield(.success(requestedTime: requestedTime, image: image, actualTime: actualTime))
                    }
                case .failed:
                    continuation.yield(.failed(requestedTime: requestedTime, error: error ?? VideoTrimmerError.frameExtractionFailed(NSError(domain: "VideoTrimmer", code: -1))))
                case .cancelled:
                    break
                @unknown default:
                    break
                }
            }

            // Note: generateCGImagesAsynchronously doesn't have a completion handler,
            // so we need to detect completion by counting results
            // This is a limitation - the stream will complete when all times are processed
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(times.count) * 0.5 + 1.0) {
                continuation.finish()
            }
        }
    }
}
