//
//  ThumbnailGenerator.swift
//  OpenCapture
//
//  Generates thumbnails from video files for preview and organization
//

import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Thumbnail Size

/// Predefined thumbnail sizes maintaining 16:9 aspect ratio
enum ThumbnailSize {
    case small   // 160x90
    case medium  // 320x180
    case large   // 640x360
    case custom(width: Int, height: Int)

    var cgSize: CGSize {
        switch self {
        case .small:
            return CGSize(width: 160, height: 90)
        case .medium:
            return CGSize(width: 320, height: 180)
        case .large:
            return CGSize(width: 640, height: 360)
        case .custom(let width, let height):
            return CGSize(width: width, height: height)
        }
    }
}

// MARK: - Image Format

/// Output format for saved thumbnails
enum ThumbnailImageFormat {
    case jpeg(quality: CGFloat)
    case png

    var utType: UTType {
        switch self {
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        }
    }
}

// MARK: - Thumbnail Generator

/// Generates thumbnails from video files using AVAssetImageGenerator
///
/// Features:
/// - Fast thumbnail extraction with configurable tolerance
/// - Multiple size presets and custom sizes
/// - JPEG and PNG output support
/// - Strip generation for video preview timelines
/// - Automatic frame selection for short videos
///
/// Example usage:
/// ```swift
/// let generator = ThumbnailGenerator()
/// let thumbnail = try await generator.generate(from: videoURL)
/// try await generator.generateAndSave(from: videoURL, to: outputURL)
/// let strip = try await generator.generateStrip(from: videoURL, count: 10)
/// ```
class ThumbnailGenerator {

    // MARK: - Options

    /// Configuration options for thumbnail generation
    struct Options {
        /// Desired thumbnail size
        var size: ThumbnailSize = .medium

        /// Time in video to extract thumbnail from
        /// nil = auto-select (1 second or 10% of duration, whichever is smaller)
        var time: CMTime? = nil

        /// Output image format
        var format: ThumbnailImageFormat = .jpeg(quality: 0.8)

        /// Time tolerance for faster seeking (larger = faster but less precise)
        var timeTolerance: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600)

        static let `default` = Options()
    }

    // MARK: - Errors

    enum ThumbnailError: LocalizedError {
        case invalidURL
        case assetLoadFailed(Error)
        case noVideoTrack
        case imageGenerationFailed(Error?)
        case imageWriteFailed
        case invalidTimeRange
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid video URL"
            case .assetLoadFailed(let error):
                return "Failed to load video asset: \(error.localizedDescription)"
            case .noVideoTrack:
                return "Video file contains no video track"
            case .imageGenerationFailed(let error):
                return "Failed to generate thumbnail: \(error?.localizedDescription ?? "unknown error")"
            case .imageWriteFailed:
                return "Failed to write thumbnail image to disk"
            case .invalidTimeRange:
                return "Specified time is outside video duration"
            case .emptyResult:
                return "No thumbnails were generated"
            }
        }
    }

    // MARK: - Public Methods

    /// Generate a thumbnail from a video file
    /// - Parameters:
    ///   - url: URL of the video file
    ///   - options: Thumbnail generation options
    /// - Returns: Generated thumbnail as CGImage
    func generate(from url: URL, options: Options = .default) async throws -> CGImage {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // Load asset properties
        let duration: CMTime
        let hasVideoTrack: Bool

        do {
            duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            hasVideoTrack = !videoTracks.isEmpty
        } catch {
            throw ThumbnailError.assetLoadFailed(error)
        }

        guard hasVideoTrack else {
            throw ThumbnailError.noVideoTrack
        }

        // Determine extraction time
        let extractionTime = options.time ?? calculateAutoTime(duration: duration)

        // Validate time is within bounds
        guard extractionTime >= .zero && extractionTime <= duration else {
            throw ThumbnailError.invalidTimeRange
        }

        // Create image generator
        let generator = AVAssetImageGenerator(asset: asset)
        configureGenerator(generator, options: options)

        // Generate image
        do {
            let (image, _) = try await generator.image(at: extractionTime)
            return image
        } catch {
            throw ThumbnailError.imageGenerationFailed(error)
        }
    }

    /// Generate a thumbnail and save it to disk
    /// - Parameters:
    ///   - url: URL of the video file
    ///   - outputURL: Destination URL for the thumbnail
    ///   - options: Thumbnail generation options
    func generateAndSave(from url: URL, to outputURL: URL, options: Options = .default) async throws {
        let image = try await generate(from: url, options: options)
        try saveImage(image, to: outputURL, format: options.format)
    }

    /// Generate multiple thumbnails at evenly spaced intervals for a preview strip
    /// - Parameters:
    ///   - url: URL of the video file
    ///   - count: Number of thumbnails to generate
    ///   - size: Size for all thumbnails
    /// - Returns: Array of CGImage thumbnails in chronological order
    func generateStrip(from url: URL, count: Int, size: ThumbnailSize = .small) async throws -> [CGImage] {
        guard count > 0 else {
            throw ThumbnailError.emptyResult
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // Load duration
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                throw ThumbnailError.noVideoTrack
            }
        } catch let error as ThumbnailError {
            throw error
        } catch {
            throw ThumbnailError.assetLoadFailed(error)
        }

        // Calculate times at even intervals
        let times = calculateStripTimes(duration: duration, count: count)

        // Create image generator
        let generator = AVAssetImageGenerator(asset: asset)
        let options = Options(size: size, timeTolerance: CMTime(seconds: 0.3, preferredTimescale: 600))
        configureGenerator(generator, options: options)

        // Generate images
        var images: [CGImage] = []
        images.reserveCapacity(count)

        for time in times {
            do {
                let (image, _) = try await generator.image(at: time)
                images.append(image)
            } catch {
                // Log but continue - we want partial results
                print("⚠️ Failed to generate thumbnail at \(time.seconds)s: \(error)")
            }
        }

        guard !images.isEmpty else {
            throw ThumbnailError.emptyResult
        }

        return images
    }

    /// Generate multiple thumbnails and save them to disk
    /// - Parameters:
    ///   - url: URL of the video file
    ///   - outputDirectory: Directory to save thumbnails in
    ///   - baseName: Base filename for thumbnails (will append _001, _002, etc.)
    ///   - count: Number of thumbnails to generate
    ///   - size: Size for all thumbnails
    ///   - format: Output image format
    /// - Returns: Array of URLs for saved thumbnails
    func generateStripAndSave(
        from url: URL,
        to outputDirectory: URL,
        baseName: String,
        count: Int,
        size: ThumbnailSize = .small,
        format: ThumbnailImageFormat = .jpeg(quality: 0.8)
    ) async throws -> [URL] {
        let images = try await generateStrip(from: url, count: count, size: size)

        var savedURLs: [URL] = []
        savedURLs.reserveCapacity(images.count)

        for (index, image) in images.enumerated() {
            let filename = String(format: "%@_%03d.%@", baseName, index + 1, format.fileExtension)
            let fileURL = outputDirectory.appendingPathComponent(filename)
            try saveImage(image, to: fileURL, format: format)
            savedURLs.append(fileURL)
        }

        return savedURLs
    }

    // MARK: - Private Methods

    /// Configure the image generator with the specified options
    private func configureGenerator(_ generator: AVAssetImageGenerator, options: Options) {
        // Set maximum size - AVAssetImageGenerator will scale down efficiently
        generator.maximumSize = options.size.cgSize

        // Apply time tolerance for faster seeking
        generator.requestedTimeToleranceBefore = options.timeTolerance
        generator.requestedTimeToleranceAfter = options.timeTolerance

        // Apply correct transform for portrait/landscape videos
        generator.appliesPreferredTrackTransform = true

        // Use best quality aperture
        generator.apertureMode = .cleanAperture
    }

    /// Calculate automatic extraction time based on video duration
    /// Uses 1 second or 10% of duration, whichever is smaller
    private func calculateAutoTime(duration: CMTime) -> CMTime {
        let durationSeconds = duration.seconds

        // For very short videos (< 2 seconds), use 10% of duration
        // For longer videos, use 1 second
        let targetSeconds: Double
        if durationSeconds < 2.0 {
            targetSeconds = durationSeconds * 0.1
        } else {
            targetSeconds = min(1.0, durationSeconds * 0.1)
        }

        return CMTime(seconds: targetSeconds, preferredTimescale: 600)
    }

    /// Calculate evenly spaced times for strip generation
    private func calculateStripTimes(duration: CMTime, count: Int) -> [CMTime] {
        guard count > 0 else { return [] }

        let durationSeconds = duration.seconds

        // If only one thumbnail, use auto time
        if count == 1 {
            return [calculateAutoTime(duration: duration)]
        }

        // Calculate interval - leave some margin at start and end
        let margin = durationSeconds * 0.05 // 5% margin
        let usableDuration = durationSeconds - (2 * margin)
        let interval = usableDuration / Double(count - 1)

        var times: [CMTime] = []
        times.reserveCapacity(count)

        for i in 0..<count {
            let seconds = margin + (Double(i) * interval)
            times.append(CMTime(seconds: seconds, preferredTimescale: 600))
        }

        return times
    }

    /// Save a CGImage to disk in the specified format
    private func saveImage(_ image: CGImage, to url: URL, format: ThumbnailImageFormat) throws {
        // Create the destination directory if needed
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Create image destination
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ThumbnailError.imageWriteFailed
        }

        // Configure output options
        var properties: [CFString: Any] = [:]

        switch format {
        case .jpeg(let quality):
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        case .png:
            // PNG doesn't need quality setting
            break
        }

        // Add image and finalize
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailError.imageWriteFailed
        }

        print("📷 Thumbnail saved: \(url.lastPathComponent)")
    }
}

// MARK: - Convenience Extensions

extension ThumbnailGenerator {

    /// Generate a thumbnail at a specific timestamp in seconds
    func generate(from url: URL, atSeconds seconds: Double, size: ThumbnailSize = .medium) async throws -> CGImage {
        var options = Options.default
        options.size = size
        options.time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await generate(from: url, options: options)
    }

    /// Generate and save a thumbnail with default options
    func generateAndSave(from videoURL: URL, to outputURL: URL) async throws {
        try await generateAndSave(from: videoURL, to: outputURL, options: .default)
    }
}
