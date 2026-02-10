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
    private var processedLayer: CALayer?
    private var shape: WebcamShape

    init(previewLayer: AVCaptureVideoPreviewLayer, processedLayer: CALayer? = nil, shape: WebcamShape = .circle) {
        self.previewLayer = previewLayer
        self.processedLayer = processedLayer
        self.shape = shape
        super.init(frame: .zero)

        wantsLayer = true
        guard let rootLayer = layer else { return }

        // Apply initial corner radius based on shape
        rootLayer.cornerRadius = cornerRadius(for: shape, width: 200)
        rootLayer.masksToBounds = true

        // Add preview layer (visible when blur is OFF)
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)

        // Add processed layer (visible when blur is ON)
        if let procLayer = processedLayer {
            procLayer.frame = rootLayer.bounds
            procLayer.contentsGravity = .resizeAspectFill
            procLayer.isHidden = true
            rootLayer.addSublayer(procLayer)
        }

        // Add border on top (always visible)
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        borderLayer.lineWidth = 3
        rootLayer.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Switch between preview layer (blur off) and processed layer (blur on)
    func setBlurEnabled(_ enabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if enabled {
            // Switching TO processed layer (blur ON)
            processedLayer?.isHidden = false
            previewLayer.isHidden = true
        } else {
            // Switching TO preview layer (blur OFF)
            previewLayer.isHidden = false
            processedLayer?.isHidden = true

            // Ensure the preview layer connection is active and frame is correct
            if let rootLayer = layer {
                previewLayer.frame = rootLayer.bounds
                // Ensure connection is enabled (can get disabled during layer switching)
                previewLayer.connection?.isEnabled = true
            }
        }

        CATransaction.commit()
        needsLayout = true
    }

    /// Update the shape of the webcam overlay
    func setShape(_ newShape: WebcamShape) {
        shape = newShape
        needsLayout = true
    }

    private func cornerRadius(for shape: WebcamShape, width: CGFloat) -> CGFloat {
        switch shape {
        case .circle:
            return width / 2
        case .roundedSquare:
            return width * 0.2
        case .square:
            return 0
        }
    }

    private func borderPath(for shape: WebcamShape, in rect: CGRect) -> CGPath {
        let radius = cornerRadius(for: shape, width: rect.width)
        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedSquare:
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .square:
            return CGPath(rect: rect, transform: nil)
        }
    }

    override func layout() {
        super.layout()
        guard let rootLayer = layer else { return }

        // Update all sublayer frames
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        previewLayer.frame = rootLayer.bounds
        processedLayer?.frame = rootLayer.bounds
        rootLayer.cornerRadius = cornerRadius(for: shape, width: bounds.width)

        let borderRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        borderLayer.path = borderPath(for: shape, in: borderRect)
        borderLayer.frame = rootLayer.bounds

        CATransaction.commit()
    }
}

// MARK: - Webcam Preview (Popup)

import SwiftUI

/// SwiftUI wrapper for the webcam preview layer + blur processed layer
struct WebcamPreviewView: View {
    @ObservedObject var webcamManager: WebcamManager
    let previewLayer: AVCaptureVideoPreviewLayer
    let blurEnabled: Bool
    let blurIntensity: Double

    var body: some View {
        VStack(spacing: 0) {
            WebcamPreviewNSView(
                previewLayer: previewLayer,
                processedLayer: webcamManager.processedFrameLayer,
                blurEnabled: webcamManager.backgroundBlurEnabled
            )
            .frame(minWidth: 320, minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(16)

            Divider()

            HStack(spacing: 16) {
                Button(action: {
                    if webcamManager.backgroundBlurEnabled {
                        webcamManager.disableBackgroundBlur()
                    } else {
                        webcamManager.enableBackgroundBlur(intensity: blurIntensity)
                    }
                }) {
                    Label(
                        webcamManager.backgroundBlurEnabled ? "Blur ON" : "Blur OFF",
                        systemImage: webcamManager.backgroundBlurEnabled ? "person.fill.viewfinder" : "person.viewfinder"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(webcamManager.backgroundBlurEnabled ? .green : .secondary)

                Circle()
                    .fill(webcamManager.backgroundBlurEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Text(webcamManager.backgroundBlurEnabled ? "Background blur active" : "No blur")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// NSView subclass that keeps layers sized to bounds
class WebcamPreviewLayerView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var processedLayer: CALayer?

    init(previewLayer: AVCaptureVideoPreviewLayer, processedLayer: CALayer?) {
        self.previewLayer = previewLayer
        self.processedLayer = processedLayer
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        processedLayer?.frame = bounds
        CATransaction.commit()
    }
}

/// NSViewRepresentable wrapping the preview + processed layers
struct WebcamPreviewNSView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    let processedLayer: CALayer?
    let blurEnabled: Bool

    func makeNSView(context: Context) -> WebcamPreviewLayerView {
        let view = WebcamPreviewLayerView(previewLayer: previewLayer, processedLayer: processedLayer)
        guard let rootLayer = view.layer else { return view }

        // Preview layer — always added, visible when blur is OFF
        previewLayer.videoGravity = .resizeAspectFill
        rootLayer.addSublayer(previewLayer)

        // Processed layer — visible when blur is ON
        if let procLayer = processedLayer {
            procLayer.contentsGravity = .resizeAspectFill
            rootLayer.addSublayer(procLayer)
        }

        // Set initial visibility
        previewLayer.isHidden = blurEnabled
        processedLayer?.isHidden = !blurEnabled

        return view
    }

    func updateNSView(_ view: WebcamPreviewLayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.isHidden = blurEnabled
        processedLayer?.isHidden = !blurEnabled
        CATransaction.commit()
        view.needsLayout = true
    }
}
