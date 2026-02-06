//
//  BackgroundBlurProcessor.swift
//  OpenCapture
//
//  Real-time webcam background blur using Vision person segmentation
//  and Core Image compositing. Person stays sharp, background blurred.
//

import AVFoundation
import Vision
import CoreImage

class BackgroundBlurProcessor {

    /// Callback delivering the processed frame (called on main queue)
    var onProcessedFrame: ((CGImage) -> Void)?

    /// Blur sigma — set at runtime via intensity slider. Thread-safe (read on processing queue).
    var blurSigma: Double = 20.0

    private let processingQueue = DispatchQueue(
        label: "com.opencapture.backgroundBlur",
        qos: .userInteractive
    )
    private let ciContext: CIContext
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private var isProcessing = false

    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false])

        segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
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

            // 4. Blur the full frame
            let sigma = self.blurSigma
            let blurredImage = originalImage
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: originalImage.extent)

            // 5. Composite: sharp person over blurred background
            guard let composited = CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: originalImage,
                    kCIInputBackgroundImageKey: blurredImage,
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
