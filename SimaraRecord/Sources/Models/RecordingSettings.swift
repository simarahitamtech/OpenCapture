//
//  RecordingSettings.swift
//  OpenCapture
//
//  Models for recording configuration
//

import Foundation
import CoreGraphics

// MARK: - Recording Settings

struct RecordingSettings {
    var region: RecordingRegion
    var quality: VideoQuality
    var frameRate: FrameRate
    var audioSettings: AudioSettings
    var webcamSettings: WebcamSettings
    var teleprompterSettings: TeleprompterSettings
    var outputURL: URL

    static var `default`: RecordingSettings {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let timestamp = DateFormatter.filenameDateFormatter.string(from: Date())
        let filename = "recording_\(timestamp).mov"

        return RecordingSettings(
            region: .fullScreen,
            quality: .high,
            frameRate: .fps60,
            audioSettings: AudioSettings(),
            webcamSettings: WebcamSettings(),
            teleprompterSettings: TeleprompterSettings(),
            outputURL: desktopURL.appendingPathComponent(filename)
        )
    }
}

// MARK: - Recording Region

enum RecordingRegion: Equatable, Hashable {
    case fullScreen
    case custom(CGRect)

    var rect: CGRect? {
        switch self {
        case .fullScreen:
            return nil // Will capture main display
        case .custom(let rect):
            return rect
        }
    }
}

struct RegionPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    var width: Int
    var height: Int

    static let presets: [RegionPreset] = [
        RegionPreset(id: UUID(), name: "1920x1080 (Full HD)", width: 1920, height: 1080),
        RegionPreset(id: UUID(), name: "1280x720 (HD)", width: 1280, height: 720),
        RegionPreset(id: UUID(), name: "1024x768", width: 1024, height: 768),
    ]
}

// MARK: - Video Quality

enum VideoQuality: String, CaseIterable, Identifiable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var id: String { rawValue }

    var bitrate: Int {
        switch self {
        case .high: return 8_000_000    // 8 Mbps
        case .medium: return 4_000_000  // 4 Mbps
        case .low: return 2_000_000     // 2 Mbps
        }
    }

    var description: String {
        switch self {
        case .high: return "Best quality, larger file size"
        case .medium: return "Balanced quality and file size"
        case .low: return "Smaller file size, lower quality"
        }
    }
}

// MARK: - Frame Rate

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue) FPS"
    }
}

// MARK: - Audio Settings

struct AudioSettings {
    var microphoneEnabled: Bool = false
    var systemAudioEnabled: Bool = false
    var selectedMicrophoneID: String?
    var micInputGain: Float = 0.75  // 0.0 to 1.0

    var hasAnyAudioEnabled: Bool {
        microphoneEnabled || systemAudioEnabled
    }
}

// MARK: - Webcam Settings

struct WebcamSettings {
    var enabled: Bool = false
    var selectedDeviceID: String?
    var backgroundBlurEnabled: Bool = false
    var blurIntensity: Double = 0.7  // 0.0 (subtle) to 1.0 (heavy), maps to sigma 5–30
}

// MARK: - Teleprompter Settings

struct TeleprompterSettings {
    var enabled: Bool = false
    var scriptText: String = ""
    var fontSize: CGFloat = 28.0
    var opacity: Double = 0.85
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case selectingRegion
    case recording(startTime: Date, isPaused: Bool)
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .recording(_, let paused) = self { return paused }
        return false
    }
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
