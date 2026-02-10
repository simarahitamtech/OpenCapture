//
//  BackgroundBlurProcessor.swift
//  OpenCapture
//
//  Real-time webcam background blur and virtual background using Vision person
//  segmentation and Core Image compositing. Person stays sharp, background is
//  either blurred or replaced with a custom image.
//

import AVFoundation
import Vision
import CoreImage
import AppKit

/// Background processing mode for the webcam feed
enum BackgroundProcessingMode {
    case blur
    case virtualBackground
}

class BackgroundBlurProcessor {

    /// Callback delivering the processed frame (called on main queue)
    var onProcessedFrame: ((CGImage) -> Void)?

    /// Blur sigma — set at runtime via intensity slider. Thread-safe (read on processing queue).
    var blurSigma: Double = 20.0

    /// Current processing mode (blur or virtual background)
    var processingMode: BackgroundProcessingMode = .blur

    private let processingQueue = DispatchQueue(
        label: "com.opencapture.backgroundBlur",
        qos: .userInteractive
    )
    private let ciContext: CIContext
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private var isProcessing = false

    // Virtual background image support
    private var backgroundImage: CIImage?
    private var scaledBackgroundCache: CIImage?
    private var cachedBackgroundSize: CGSize = .zero

    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false])

        segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    // MARK: - Virtual Background Image Management

    /// Sets the virtual background image from a URL
    /// - Parameter url: File URL to the background image
    /// - Returns: true if the image was loaded successfully
    @discardableResult
    func setBackgroundImage(url: URL) -> Bool {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("❌ Failed to load background image from: \(url.path)")
            return false
        }

        backgroundImage = CIImage(cgImage: cgImage)
        // Clear cached scaled version so it gets regenerated for current frame size
        scaledBackgroundCache = nil
        cachedBackgroundSize = .zero
        processingMode = .virtualBackground
        print("✅ Loaded virtual background image: \(url.lastPathComponent)")
        return true
    }

    /// Clears the virtual background image and switches back to blur mode
    func clearBackgroundImage() {
        backgroundImage = nil
        scaledBackgroundCache = nil
        cachedBackgroundSize = .zero
        processingMode = .blur
        print("🔵 Cleared virtual background, switching to blur mode")
    }

    /// Returns the scaled and cropped background image to match the target frame size
    /// Uses aspect fill with center crop
    private func getScaledBackgroundImage(for targetExtent: CGRect) -> CIImage? {
        guard let bgImage = backgroundImage else { return nil }

        let targetSize = targetExtent.size

        // Return cached version if dimensions match
        if cachedBackgroundSize == targetSize, let cached = scaledBackgroundCache {
            return cached
        }

        // Calculate scale factor for aspect fill
        let bgExtent = bgImage.extent
        let scaleX = targetSize.width / bgExtent.width
        let scaleY = targetSize.height / bgExtent.height
        let scale = max(scaleX, scaleY)  // aspect fill

        // Scale the image
        let scaledImage = bgImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Calculate crop rect to center the image
        let scaledExtent = scaledImage.extent
        let cropX = (scaledExtent.width - targetSize.width) / 2 + scaledExtent.origin.x
        let cropY = (scaledExtent.height - targetSize.height) / 2 + scaledExtent.origin.y
        let cropRect = CGRect(x: cropX, y: cropY, width: targetSize.width, height: targetSize.height)

        // Crop to target size
        var croppedImage = scaledImage.cropped(to: cropRect)

        // Translate to origin (0, 0) to match video frame coordinates
        croppedImage = croppedImage.transformed(
            by: CGAffineTransform(translationX: -croppedImage.extent.origin.x,
                                  y: -croppedImage.extent.origin.y)
        )

        // Cache the result
        scaledBackgroundCache = croppedImage
        cachedBackgroundSize = targetSize

        return croppedImage
    }

    func processFrame(_ sampleBuffer: CMSampleBuffer) {
        // Drop frame if still processing the previous one
        guard !isProcessing else { return }
        isProcessing = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessing = false
            return
        }

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isProcessing = false }

            // 1. Run person segmentation
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )
            do {
                try handler.perform([self.segmentationRequest])
            } catch {
                return
            }

            guard let maskPixelBuffer = self.segmentationRequest.results?.first?.pixelBuffer else {
                return
            }

            // 2. Create CIImages
            let originalImage = CIImage(cvPixelBuffer: pixelBuffer)
            let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

            // 3. Scale mask to match original dimensions
            let scaleX = originalImage.extent.width / maskImage.extent.width
            let scaleY = originalImage.extent.height / maskImage.extent.height
            let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            // 4. Determine background image based on processing mode
            let backgroundImage: CIImage
            switch self.processingMode {
            case .blur:
                // Blur the full frame
                let sigma = self.blurSigma
                backgroundImage = originalImage
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: sigma)
                    .cropped(to: originalImage.extent)

            case .virtualBackground:
                // Use virtual background image, fall back to blur if not available
                if let scaledBg = self.getScaledBackgroundImage(for: originalImage.extent) {
                    backgroundImage = scaledBg
                } else {
                    // Fallback to blur if no background image is set
                    let sigma = self.blurSigma
                    backgroundImage = originalImage
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: sigma)
                        .cropped(to: originalImage.extent)
                }
            }

            // 5. Composite: sharp person (foreground) over background
            // CIBlendWithMask: where mask is white, show input image (person)
            //                  where mask is black, show background image
            guard let composited = CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: originalImage,
                    kCIInputBackgroundImageKey: backgroundImage,
                    kCIInputMaskImageKey: scaledMask
                ]
            )?.outputImage else { return }

            // 6. Render to CGImage
            guard let cgImage = self.ciContext.createCGImage(
                composited,
                from: originalImage.extent
            ) else { return }

            // 7. Deliver on main thread
            DispatchQueue.main.async {
                self.onProcessedFrame?(cgImage)
            }
        }
    }

    func stop() {
        onProcessedFrame = nil
    }
}
