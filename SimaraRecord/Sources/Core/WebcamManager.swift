//
//  WebcamManager.swift
//  OpenCapture
//
//  Camera device discovery and webcam capture management
//

import AVFoundation
import AppKit

@MainActor
class WebcamManager: ObservableObject {
    @Published var availableCameras: [CameraDevice] = []
    @Published var selectedCamera: CameraDevice?
    @Published var isRunning = false

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?

    init() {
        updateAvailableCameras()
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

    func updateAvailableCameras() {
        #if os(macOS)
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices

        self.availableCameras = devices.map { device in
            CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device == AVCaptureDevice.default(for: .video)
            )
        }

        // Select default if none selected
        if selectedCamera == nil {
            selectedCamera = availableCameras.first { $0.isDefault } ?? availableCameras.first
        }

        print("📷 Found \(availableCameras.count) cameras")
        #endif
    }

    private func setupNotifications() {
        #if os(macOS)
        deviceConnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAvailableCameras()
        }
        deviceDisconnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAvailableCameras()
        }
        #endif
    }

    // MARK: - Capture

    func startCapture(deviceID: String?) -> AVCaptureVideoPreviewLayer? {
        guard !isRunning else { return previewLayer }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .medium

        // Find camera device
        let camera: AVCaptureDevice?
        if let deviceID = deviceID {
            camera = AVCaptureDevice(uniqueID: deviceID)
        } else if let selected = selectedCamera {
            camera = AVCaptureDevice(uniqueID: selected.id)
        } else {
            camera = AVCaptureDevice.default(for: .video)
        }

        guard let device = camera else {
            print("⚠️ No camera device found")
            return nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                print("⚠️ Cannot add camera input to capture session")
                return nil
            }
            session.addInput(input)

            session.commitConfiguration()
            session.startRunning()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill

            // Mirror the front camera so it feels natural
            if device.position == .front || device.position == .unspecified {
                layer.connection?.automaticallyAdjustsVideoMirroring = false
                layer.connection?.isVideoMirrored = true
            }

            self.captureSession = session
            self.previewLayer = layer
            self.isRunning = true

            print("📷 Webcam capture started: \(device.localizedName)")
            return layer
        } catch {
            print("❌ Failed to start webcam capture: \(error)")
            return nil
        }
    }

    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        previewLayer = nil
        isRunning = false
        print("📷 Webcam capture stopped")
    }

    // MARK: - Permissions

    func requestCameraPermission() async -> Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
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

// MARK: - Camera Device Model

struct CameraDevice: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool

    var displayName: String {
        isDefault ? "\(name) (Default)" : name
    }
}
