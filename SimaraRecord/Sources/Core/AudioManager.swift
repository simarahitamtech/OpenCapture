//
//  AudioManager.swift
//  OpenCapture
//
//  Handles microphone input and audio device management
//

import AVFoundation
import Combine

@MainActor
class AudioManager: ObservableObject {
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var selectedMicrophone: AudioDevice?
    @Published var audioLevel: Float = 0.0
    @Published var isMonitoring = false

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var levelTimer: Timer?
    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?

    init() {
        updateAvailableMicrophones()
        setupNotifications()
    }

    deinit {
        if let observer = deviceConnectedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deviceDisconnectedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Device Management

    func updateAvailableMicrophones() {
        // Get available audio input devices
        #if os(macOS)
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        self.availableMicrophones = devices.map { device in
            AudioDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device == AVCaptureDevice.default(for: .audio)
            )
        }

        // Select default device if none selected
        if selectedMicrophone == nil {
            selectedMicrophone = availableMicrophones.first { $0.isDefault } ?? availableMicrophones.first
        }

        print("🎤 Found \(availableMicrophones.count) microphones")
        #endif
    }

    private func setupNotifications() {
        // Listen for audio device changes (macOS-specific notification)
        #if os(macOS)
        deviceConnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAvailableMicrophones()
        }
        deviceDisconnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAvailableMicrophones()
        }
        #endif
    }

    // MARK: - Audio Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            // Install tap to monitor audio levels
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            try engine.start()

            self.audioEngine = engine
            self.inputNode = input
            self.isMonitoring = true

            print("🎤 Audio monitoring started")
        } catch {
            print("❌ Failed to start audio monitoring: \(error)")
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        self.audioEngine = nil
        self.inputNode = nil
        self.isMonitoring = false
        self.audioLevel = 0.0

        print("🎤 Audio monitoring stopped")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride)
            .map { channelDataValue[$0] }

        // Calculate RMS (Root Mean Square) for audio level
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

        // Convert to decibels and normalize to 0-1 range
        let decibels = 20 * log10(rms)
        let normalizedLevel = max(0, min(1, (decibels + 50) / 50)) // -50dB to 0dB range

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = normalizedLevel
        }
    }

    // MARK: - Permissions

    func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }
}

// MARK: - Audio Device Model

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool

    var displayName: String {
        isDefault ? "\(name) (Default)" : name
    }
}
