//
//  WebcamManager.swift
//  OpenCapture
//
//  Camera device discovery and webcam capture management
//

import AVFoundation
import AppKit
import Vision
import CoreImage

@MainActor
class WebcamManager: ObservableObject {
    @Published var availableCameras: [CameraDevice] = []
    @Published var selectedCamera: CameraDevice?
    @Published var isRunning = false
    @Published var backgroundBlurEnabled = false
    @Published var backgroundMode: WebcamBackgroundMode = .none
    @Published var backgroundImageURL: URL?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?

    // Background blur pipeline
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var blurProcessor: BackgroundBlurProcessor?
    private var delegateAdapter: VideoOutputDelegateAdapter?
    private let videoOutputQueue = DispatchQueue(
        label: "com.opencapture.webcamVideoOutput",
        qos: .userInteractive
    )
    private(set) var processedFrameLayer: CALayer?

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

            // Add video data output for background blur (no delegate until blur is enabled)
            let dataOutput = AVCaptureVideoDataOutput()
            dataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            dataOutput.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(dataOutput) {
                session.addOutput(dataOutput)
                self.videoDataOutput = dataOutput
            }

            session.commitConfiguration()
            session.startRunning()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill

            // Mirror the front camera so it feels natural
            if device.position == .front || device.position == .unspecified {
                layer.connection?.automaticallyAdjustsVideoMirroring = false
                layer.connection?.isVideoMirrored = true

                // Also mirror the video data output connection
                if let dataConnection = dataOutput.connection(with: .video) {
                    dataConnection.automaticallyAdjustsVideoMirroring = false
                    dataConnection.isVideoMirrored = true
                }
            }

            self.captureSession = session
            self.previewLayer = layer
            self.isRunning = true

            // Create processed frame layer for blur mode
            let procLayer = CALayer()
            procLayer.contentsGravity = .resizeAspectFill
            self.processedFrameLayer = procLayer

            print("📷 Webcam capture started: \(device.localizedName)")
            return layer
        } catch {
            print("❌ Failed to start webcam capture: \(error)")
            return nil
        }
    }

    func stopCapture() {
        disableBackgroundBlur()
        captureSession?.stopRunning()
        captureSession = nil
        previewLayer = nil
        videoDataOutput = nil
        processedFrameLayer = nil
        isRunning = false
        print("📷 Webcam capture stopped")
    }

    // MARK: - Background Blur

    func updateBlurIntensity(_ intensity: Double) {
        // Map 0.0–1.0 to sigma 5–30
        let sigma = 5.0 + intensity * 25.0
        blurProcessor?.blurSigma = sigma
    }

    func enableBackgroundBlur(intensity: Double = 0.7) {
        print("🔵 enableBackgroundBlur called — isRunning: \(isRunning), dataOutput: \(videoDataOutput != nil), procLayer: \(processedFrameLayer != nil), alreadyEnabled: \(backgroundBlurEnabled)")

        // If already enabled with a processor, just update intensity and return
        if backgroundBlurEnabled, blurProcessor != nil {
            print("🔵 enableBackgroundBlur — already enabled, updating intensity only")
            updateBlurIntensity(intensity)
            return
        }

        guard isRunning, let dataOutput = videoDataOutput else {
            print("🔴 enableBackgroundBlur BAILED — missing dataOutput or not running")
            return
        }

        let processor = BackgroundBlurProcessor()
        processor.blurSigma = 5.0 + intensity * 25.0
        processor.onProcessedFrame = { [weak self] cgImage in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.processedFrameLayer?.contents = cgImage
            CATransaction.commit()
        }
        self.blurProcessor = processor

        let adapter = VideoOutputDelegateAdapter(processor: processor)
        self.delegateAdapter = adapter
        dataOutput.setSampleBufferDelegate(adapter, queue: videoOutputQueue)

        backgroundBlurEnabled = true
        // Only set to blur mode if not already in image mode
        if case .image = backgroundMode {
            // Keep image mode
        } else {
            backgroundMode = .blur
        }
        print("🔵 enableBackgroundBlur SUCCESS — blur is now ON")
    }

    func disableBackgroundBlur() {
        print("🔵 disableBackgroundBlur called")
        videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        blurProcessor?.stop()
        blurProcessor = nil
        delegateAdapter = nil

        backgroundBlurEnabled = false
        backgroundMode = .none
        // NOTE: Don't clear backgroundImageURL here - preserve it for re-enabling

        // Ensure the capture session is still running for the preview layer
        if let session = captureSession, !session.isRunning {
            session.startRunning()
        }
        print("🔵 disableBackgroundBlur DONE — blur is now OFF, session running: \(captureSession?.isRunning ?? false)")
    }

    func toggleBackgroundBlur(intensity: Double = 0.7) {
        if backgroundBlurEnabled {
            disableBackgroundBlur()
        } else {
            enableBackgroundBlur(intensity: intensity)
        }
    }

    // MARK: - Virtual Background

    /// Sets a virtual background image for the webcam feed
    /// - Parameters:
    ///   - url: File URL to the background image
    ///   - intensity: Blur intensity to use as fallback (0.0 to 1.0)
    /// - Returns: true if the background image was set successfully
    @discardableResult
    func setBackgroundImage(url: URL, intensity: Double = 0.7) -> Bool {
        print("🔵 setBackgroundImage called — url: \(url.path)")

        // If not currently running with blur/background processing, start it
        if !backgroundBlurEnabled {
            enableBackgroundBlur(intensity: intensity)
        }

        // Set the background image on the processor
        guard let processor = blurProcessor else {
            print("🔴 setBackgroundImage FAILED — no blur processor")
            return false
        }

        let success = processor.setBackgroundImage(url: url)
        if success {
            backgroundImageURL = url
            backgroundMode = .image(url)
            print("✅ Virtual background set successfully")
        }
        return success
    }

    /// Clears the virtual background and switches back to blur mode
    func clearBackgroundImage() {
        print("🔵 clearBackgroundImage called")
        blurProcessor?.clearBackgroundImage()
        backgroundImageURL = nil

        // If background processing was enabled, switch mode to blur
        if backgroundBlurEnabled {
            backgroundMode = .blur
        } else {
            backgroundMode = .none
        }
        print("🔵 Virtual background cleared")
    }

    /// Sets the background mode (none, blur, or image)
    /// - Parameters:
    ///   - mode: The background mode to set
    ///   - intensity: Blur intensity (0.0 to 1.0), used for blur mode
    func setBackgroundMode(_ mode: WebcamBackgroundMode, intensity: Double = 0.7) {
        print("🔵 setBackgroundMode called — mode: \(mode)")

        switch mode {
        case .none:
            disableBackgroundBlur()
            clearBackgroundImage()
            backgroundMode = .none

        case .blur:
            clearBackgroundImage()
            if !backgroundBlurEnabled {
                enableBackgroundBlur(intensity: intensity)
            }
            blurProcessor?.processingMode = .blur
            backgroundMode = .blur

        case .image(let url):
            setBackgroundImage(url: url, intensity: intensity)
        }
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

// MARK: - Video Output Delegate Adapter

/// Bridges @MainActor WebcamManager to AVCaptureVideoDataOutputSampleBufferDelegate
/// which delivers callbacks on arbitrary queues.
class VideoOutputDelegateAdapter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let processor: BackgroundBlurProcessor

    init(processor: BackgroundBlurProcessor) {
        self.processor = processor
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processor.processFrame(sampleBuffer)
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
