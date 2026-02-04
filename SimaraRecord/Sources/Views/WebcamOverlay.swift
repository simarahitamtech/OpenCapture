//
//  WebcamOverlay.swift
//  OpenCapture
//
//  Floating circular webcam PiP window during recording
//

import AppKit
import AVFoundation

// MARK: - Webcam PiP Window

class WebcamPiPWindow: NSPanel {
    init() {
        let size: CGFloat = 200
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true

        // Position in bottom-right corner
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.maxX - frame.width - 20,
                y: screenFrame.minY + 20
            )
            self.setFrameOrigin(origin)
        }
    }
}

// MARK: - Webcam PiP View

class WebcamPiPView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let borderLayer = CAShapeLayer()

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)

        wantsLayer = true
        guard let rootLayer = layer else { return }

        // Circular mask on the root layer
        rootLayer.cornerRadius = 100 // half of 200
        rootLayer.masksToBounds = true

        // Add preview layer
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)

        // Add circular border on top
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        borderLayer.lineWidth = 3
        rootLayer.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let rootLayer = layer else { return }

        // Update all sublayer frames
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        previewLayer.frame = rootLayer.bounds
        rootLayer.cornerRadius = bounds.width / 2

        let borderRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        borderLayer.path = CGPath(ellipseIn: borderRect, transform: nil)
        borderLayer.frame = rootLayer.bounds

        CATransaction.commit()
    }
}
