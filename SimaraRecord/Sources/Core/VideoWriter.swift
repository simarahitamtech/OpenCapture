//
//  VideoWriter.swift
//  OpenCapture
//
//  Handles incremental MP4 writing - the anti-hostage core
//

import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

class VideoWriter {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let outputURL: URL
    private let videoSettings: [String: Any]
    private let audioSettings: [String: Any]
    private let pixelWidth: Int
    private let pixelHeight: Int
    private var isWriting = false
    private var sessionStartTime: CMTime = .zero
    private var hasStartedSession = false

    /// Cached pixel buffer from the last `.complete` SCStream frame. Used to
    /// fill in idle frames that don't carry their own buffer, so the encoder
    /// keeps receiving frames at the target rate even when the screen is
    /// momentarily unchanged.
    private var lastCompletePixelBuffer: CVPixelBuffer?

    // Serial queue to prevent concurrent audio appends from mic + system audio
    private let audioAppendQueue = DispatchQueue(label: "com.simararecord.audioAppend")

    // Pause support — track total paused duration to offset timestamps
    private(set) var isPaused = false
    private var pauseStartTime: CMTime = .zero
    private var totalPausedDuration: CMTime = .zero

    /// Read-only accessor for paused duration (seconds). Used by the recorder
    /// to stamp window-frame events with paused-adjusted timestamps so they
    /// align with the video track timeline.
    var totalPausedSeconds: Double { CMTimeGetSeconds(totalPausedDuration) }

    init(outputURL: URL, width: Int, height: Int, frameRate: Int, bitrate: Int) throws {
        self.outputURL = outputURL

        // Ensure dimensions are even (H.264 requirement)
        let evenWidth = (width / 2) * 2
        let evenHeight = (height / 2) * 2
        self.pixelWidth = evenWidth
        self.pixelHeight = evenHeight

        print("🎬 VideoWriter dimensions: \(width)x\(height) -> \(evenWidth)x\(evenHeight)")

        // Video encoding settings with explicit compression properties
        self.videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ] as [String: Any]
        ]

        // Audio encoding settings - AAC
        self.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
    }

    func startWriting() throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Use MOV container - better macOS compatibility with fragmented writing
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            throw VideoWriterError.failedToCreateWriter
        }

        // CRITICAL: Movie fragment interval makes file playable even during recording
        // If app crashes, file is still valid up to last fragment
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        // Setup video input with nil outputSettings to accept source format directly
        // We use a separate input with settings for encoding
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Pixel buffer adaptor - MUST be used for ScreenCaptureKit buffers
        // ScreenCaptureKit delivers IOSurface-backed buffers that can't be appended directly
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelWidth,
            kCVPixelBufferHeightKey as String: pixelHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(videoInput) else {
            throw VideoWriterError.cannotAddVideoInput
        }
        writer.add(videoInput)

        // Setup audio input
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else {
            throw VideoWriterError.cannotAddAudioInput
        }
        writer.add(audioInput)

        // Start writing session
        guard writer.startWriting() else {
            let error = writer.error?.localizedDescription ?? "unknown error"
            print("❌ Failed to start writing: \(error)")
            print("   Writer status: \(writer.status.rawValue)")
            throw VideoWriterError.failedToStartWriting(writer.error)
        }

        self.assetWriter = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.isWriting = true
        self.hasStartedSession = false

        print("✅ VideoWriter started successfully")
        print("   Output: \(outputURL.path)")
        print("   Video: \(pixelWidth)x\(pixelHeight)")
        print("   Format: MOV (QuickTime)")
        print("   Fragment interval: 1 second (anti-hostage mode)")
        print("   ⭐ File is playable even during recording!")
    }

    // MARK: - Pause / Resume

    func pause() {
        guard isWriting, !isPaused else { return }
        isPaused = true
        // Record when we paused so we can compute the gap later
        pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        print("⏸ VideoWriter paused")
    }

    func resume() {
        guard isWriting, isPaused else { return }
        // Accumulate how long we were paused
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let pausedDuration = CMTimeSubtract(now, pauseStartTime)
        totalPausedDuration = CMTimeAdd(totalPausedDuration, pausedDuration)
        isPaused = false
        print("▶️ VideoWriter resumed (paused for \(pausedDuration.seconds)s, total paused: \(totalPausedDuration.seconds)s)")
    }

    /// Adjusts a presentation timestamp by subtracting total paused duration
    private func adjustedTime(_ time: CMTime) -> CMTime {
        return CMTimeSubtract(time, totalPausedDuration)
    }

    // MARK: - Buffer Appending

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, !isPaused else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }
        guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
        guard let adaptor = pixelBufferAdaptor else { return }

        // Read SCStream frame status. We treat .complete and .idle the same:
        // both carry valid pixels. Without this, capturing a window on an
        // external HDMI display (where the system marks ~50% of frames idle
        // because the display compositor reports no change) silently halves
        // the recording's frame rate. See diagnostic logs in ScreenRecorder
        // — Mac mini demo mode dropped from 60 fps to ~27 fps because every
        // idle frame was dropped here.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else {
            return
        }
        let status: SCFrameStatus? = {
            if let raw = attachments[SCStreamFrameInfo.status] as? Int {
                return SCFrameStatus(rawValue: raw)
            }
            return nil
        }()

        // Skip frames that genuinely carry no image (suspended / stopped / blank /
        // started). For idle frames the pixel buffer is the same as the last
        // delivered .complete frame — perfectly fine to write.
        switch status {
        case .complete, .idle:
            break
        default:
            return
        }

        // Idle frames sometimes carry a pixel buffer (a snapshot of the last
        // unchanged screen) and sometimes don't. When the buffer is missing,
        // fall back to repeating the most recent complete buffer so the
        // output frame rate stays smooth instead of stalling.
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) ?? lastCompletePixelBuffer
        guard let pixelBuffer = imageBuffer else {
            // No image and no previous frame to repeat — bail. Happens at the
            // very start before any complete frame has arrived.
            return
        }
        if status == .complete {
            lastCompletePixelBuffer = pixelBuffer
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedPresentationTime = adjustedTime(presentationTime)

        // Start the session on the first valid frame
        if !hasStartedSession {
            writer.startSession(atSourceTime: adjustedPresentationTime)
            sessionStartTime = adjustedPresentationTime
            hasStartedSession = true
            print("🎬 First video frame received at time: \(adjustedPresentationTime.seconds)")

            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
            print("   Buffer size: \(bufferWidth)x\(bufferHeight), format: \(formatType)")
        }

        // Use the pixel buffer adaptor to append — this handles IOSurface-backed buffers correctly
        if !adaptor.append(pixelBuffer, withPresentationTime: adjustedPresentationTime) {
            if let writerError = writer.error {
                print("❌ Failed to append pixel buffer: \(writerError)")
                print("   Error code: \(writerError._code)")
            }
            print("   Writer status: \(writer.status.rawValue)")
        }
    }

    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Quick pre-check (non-serialized) to bail early
        guard isWriting, !isPaused, hasStartedSession else { return }

        // Serialize all audio appends — mic and system audio arrive on different threads
        // and concurrent appends cause readyForMoreMediaData races
        audioAppendQueue.async { [self] in
            guard isWriting, !isPaused,
                  let writer = assetWriter, writer.status == .writing,
                  let audioInput = audioInput,
                  audioInput.isReadyForMoreMediaData else {
                return
            }

            // Adjust audio timestamp to remove paused gaps
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let adjustedPresentationTime = adjustedTime(presentationTime)

            // Create a copy of the sample buffer with adjusted timing
            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: adjustedPresentationTime,
                decodeTimeStamp: .invalid
            )
            var adjustedBuffer: CMSampleBuffer?
            var count: CMItemCount = 0
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &adjustedBuffer
            )

            if let adjustedBuffer = adjustedBuffer {
                if !audioInput.append(adjustedBuffer) {
                    print("⚠️ Failed to append audio buffer: \(writer.error?.localizedDescription ?? "unknown")")
                }
            } else {
                // Fallback: append original buffer (timestamps may be off after pause)
                if !audioInput.append(sampleBuffer) {
                    print("⚠️ Failed to append audio buffer: \(writer.error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    func finishWriting(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let writer = assetWriter, isWriting else {
            completion(.failure(VideoWriterError.notWriting))
            return
        }

        isWriting = false

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self = self else { return }

            if let error = writer.error {
                completion(.failure(error))
            } else {
                print("✅ Video file finalized: \(self.outputURL.path)")
                completion(.success(self.outputURL))
            }
        }
    }

    func cancelWriting() {
        guard let writer = assetWriter, isWriting else { return }

        isWriting = false
        writer.cancelWriting()

        // Optionally delete the partial file
        try? FileManager.default.removeItem(at: outputURL)
        print("❌ Recording cancelled and file deleted")
    }
}

// MARK: - Errors

enum VideoWriterError: LocalizedError {
    case failedToCreateWriter
    case cannotAddVideoInput
    case cannotAddAudioInput
    case failedToStartWriting(Error?)
    case notWriting

    var errorDescription: String? {
        switch self {
        case .failedToCreateWriter:
            return "Failed to create video writer"
        case .cannotAddVideoInput:
            return "Cannot add video input to writer"
        case .cannotAddAudioInput:
            return "Cannot add audio input to writer"
        case .failedToStartWriting(let error):
            return "Failed to start writing: \(error?.localizedDescription ?? "unknown")"
        case .notWriting:
            return "Writer is not in writing state"
        }
    }
}
