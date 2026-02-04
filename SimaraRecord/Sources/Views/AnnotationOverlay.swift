//
//  AnnotationOverlay.swift
//  OpenCapture
//
//  On-screen annotation/drawing during recording
//

import SwiftUI
import AppKit

// MARK: - Data Model

enum AnnotationTool: Equatable {
    case pen
    case arrow
    case rectangle
}

struct AnnotationColor: Equatable, Identifiable {
    let id: String
    let color: NSColor
    let name: String

    static let red = AnnotationColor(id: "red", color: .systemRed, name: "Red")
    static let yellow = AnnotationColor(id: "yellow", color: .systemYellow, name: "Yellow")
    static let green = AnnotationColor(id: "green", color: .systemGreen, name: "Green")
    static let blue = AnnotationColor(id: "blue", color: .systemBlue, name: "Blue")
    static let white = AnnotationColor(id: "white", color: .white, name: "White")

    static let allColors: [AnnotationColor] = [.red, .yellow, .green, .blue, .white]

    static func == (lhs: AnnotationColor, rhs: AnnotationColor) -> Bool {
        lhs.id == rhs.id
    }
}

enum AnnotationLineWidth: CGFloat, CaseIterable {
    case thin = 2.0
    case medium = 4.0
    case thick = 8.0
}

struct AnnotationStroke {
    let tool: AnnotationTool
    let color: NSColor
    let lineWidth: CGFloat
    let points: [NSPoint]
}

// MARK: - Annotation Window

class AnnotationWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.ignoresMouseEvents = false
        self.hasShadow = false
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Annotation Drawing View

class AnnotationDrawingView: NSView {
    var currentTool: AnnotationTool = .pen
    var currentColor: NSColor = .systemRed
    var currentLineWidth: AnnotationLineWidth = .medium

    private var strokes: [AnnotationStroke] = []
    private var activePoints: [NSPoint] = []
    private var isDrawing = false

    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override var acceptsFirstResponder: Bool { true }

    func clearStrokes() {
        strokes.removeAll()
        activePoints.removeAll()
        isDrawing = false
        needsDisplay = true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activePoints = [point]
        isDrawing = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch currentTool {
        case .pen:
            activePoints.append(point)
        case .arrow, .rectangle:
            if activePoints.count >= 2 {
                activePoints[1] = point
            } else {
                activePoints.append(point)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawing, activePoints.count >= 2 else {
            isDrawing = false
            activePoints = []
            return
        }

        let stroke = AnnotationStroke(
            tool: currentTool,
            color: currentColor,
            lineWidth: currentLineWidth.rawValue,
            points: activePoints
        )
        strokes.append(stroke)

        activePoints = []
        isDrawing = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onDismiss?()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Draw all completed strokes
        for stroke in strokes {
            drawStroke(stroke)
        }

        // Draw the in-progress stroke
        if isDrawing && activePoints.count >= 2 {
            let activeStroke = AnnotationStroke(
                tool: currentTool,
                color: currentColor,
                lineWidth: currentLineWidth.rawValue,
                points: activePoints
            )
            drawStroke(activeStroke)
        }
    }

    private func drawStroke(_ stroke: AnnotationStroke) {
        stroke.color.setStroke()

        switch stroke.tool {
        case .pen:
            drawPenStroke(stroke)
        case .arrow:
            drawArrowStroke(stroke)
        case .rectangle:
            drawRectangleStroke(stroke)
        }
    }

    private func drawPenStroke(_ stroke: AnnotationStroke) {
        guard stroke.points.count >= 2 else { return }

        let path = NSBezierPath()
        path.lineWidth = stroke.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: stroke.points[0])

        for i in 1..<stroke.points.count {
            path.line(to: stroke.points[i])
        }
        path.stroke()
    }

    private func drawArrowStroke(_ stroke: AnnotationStroke) {
        guard stroke.points.count >= 2 else { return }

        let start = stroke.points[0]
        let end = stroke.points[stroke.points.count - 1]

        // Draw the line
        let linePath = NSBezierPath()
        linePath.lineWidth = stroke.lineWidth
        linePath.lineCapStyle = .round
        linePath.move(to: start)
        linePath.line(to: end)
        linePath.stroke()

        // Draw arrowhead
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = max(16, stroke.lineWidth * 5)
        let arrowAngle: CGFloat = .pi / 6 // 30 degrees

        let arrowPoint1 = NSPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let arrowPoint2 = NSPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )

        // Fill arrowhead
        stroke.color.setFill()
        let fillPath = NSBezierPath()
        fillPath.move(to: end)
        fillPath.line(to: arrowPoint1)
        fillPath.line(to: arrowPoint2)
        fillPath.close()
        fillPath.fill()
    }

    private func drawRectangleStroke(_ stroke: AnnotationStroke) {
        guard stroke.points.count >= 2 else { return }

        let start = stroke.points[0]
        let end = stroke.points[stroke.points.count - 1]

        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        let path = NSBezierPath(rect: rect)
        path.lineWidth = stroke.lineWidth
        path.stroke()
    }
}

// MARK: - Annotation Toolbar Window

class AnnotationToolbarWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true

        // Position at bottom-center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.midX - frame.width / 2,
                y: screenFrame.minY + 40
            )
            self.setFrameOrigin(origin)
        }
    }
}

// MARK: - Annotation Toolbar (SwiftUI)

struct AnnotationToolbar: View {
    @ObservedObject var state: AnnotationToolbarState
    let onDone: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Tool buttons
            toolButton(tool: .pen, icon: "pencil.line", label: "Pen")
            toolButton(tool: .arrow, icon: "arrow.up.right", label: "Arrow")
            toolButton(tool: .rectangle, icon: "rectangle", label: "Rect")

            Divider().frame(height: 24)

            // Color presets
            ForEach(AnnotationColor.allColors) { preset in
                Circle()
                    .fill(Color(nsColor: preset.color))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: state.colorID == preset.id ? 2 : 0)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .onTapGesture {
                        state.colorID = preset.id
                        state.syncToView()
                    }
            }

            Divider().frame(height: 24)

            // Line width
            ForEach(AnnotationLineWidth.allCases, id: \.rawValue) { width in
                Circle()
                    .fill(Color.white)
                    .frame(width: width.rawValue * 2 + 4, height: width.rawValue * 2 + 4)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.6),
                                    lineWidth: state.lineWidth == width ? 2 : 0)
                    )
                    .onTapGesture {
                        state.lineWidth = width
                        state.syncToView()
                    }
            }

            Divider().frame(height: 24)

            // Clear
            Button(action: onClear) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            // Done
            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 8)
    }

    @ViewBuilder
    private func toolButton(tool: AnnotationTool, icon: String, label: String) -> some View {
        let content = VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 16))
            Text(label)
                .font(.system(size: 9))
        }
        .frame(width: 36, height: 36)

        if state.tool == tool {
            Button(action: {
                state.tool = tool
                state.syncToView()
            }) { content }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: {
                state.tool = tool
                state.syncToView()
            }) { content }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Toolbar State Bridge

class AnnotationToolbarState: ObservableObject {
    @Published var tool: AnnotationTool = .pen
    @Published var colorID: String = AnnotationColor.red.id
    @Published var lineWidth: AnnotationLineWidth = .medium

    weak var drawingView: AnnotationDrawingView?

    var resolvedColor: NSColor {
        AnnotationColor.allColors.first { $0.id == colorID }?.color ?? .systemRed
    }

    func syncToView() {
        drawingView?.currentTool = tool
        drawingView?.currentColor = resolvedColor
        drawingView?.currentLineWidth = lineWidth
    }
}

// MARK: - Annotation Controller

@MainActor
class AnnotationController: ObservableObject {
    private var drawingWindow: AnnotationWindow?
    private var toolbarWindow: AnnotationToolbarWindow?
    private var drawingView: AnnotationDrawingView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var fadeTask: Task<Void, Never>?

    @Published var isActive = false

    func startAnnotating() {
        // If a previous session is still fading, cancel it immediately
        if drawingWindow != nil {
            fadeTask?.cancel()
            drawingWindow?.orderOut(nil)
            drawingWindow?.close()
            drawingWindow = nil
            drawingView = nil
        }

        guard let screen = NSScreen.main else { return }

        // Create the drawing window + view
        let window = AnnotationWindow(screen: screen)
        let view = AnnotationDrawingView(frame: screen.frame)
        view.onDismiss = { [weak self] in
            self?.stopAnnotating()
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.crosshair.set()

        // Create the toolbar window
        let toolbarWin = AnnotationToolbarWindow()
        let toolbarState = AnnotationToolbarState()
        toolbarState.drawingView = view
        let toolbar = AnnotationToolbar(
            state: toolbarState,
            onDone: { [weak self] in self?.stopAnnotating() },
            onClear: { [weak view] in view?.clearStrokes() }
        )
        toolbarWin.contentView = NSHostingView(rootView: toolbar)
        toolbarWin.orderFront(nil)

        // Event monitors for Escape
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.stopAnnotating()
                return nil
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    self?.stopAnnotating()
                }
            }
        }

        self.drawingWindow = window
        self.toolbarWindow = toolbarWin
        self.drawingView = view
        self.isActive = true

        print("✏️ Annotation mode started")
    }

    func stopAnnotating() {
        guard isActive else { return }
        isActive = false

        // Remove event monitors
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        // Close toolbar immediately
        toolbarWindow?.orderOut(nil)
        toolbarWindow?.close()
        toolbarWindow = nil

        // Make drawing window non-interactive (pass-through)
        drawingWindow?.ignoresMouseEvents = true

        NSCursor.arrow.set()

        print("✏️ Annotation mode ended, fading in 3s...")

        // Fade out after 3 seconds
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            guard !Task.isCancelled, let self = self, let window = self.drawingWindow else { return }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                window.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.drawingWindow?.orderOut(nil)
                    self?.drawingWindow?.close()
                    self?.drawingWindow = nil
                    self?.drawingView = nil
                    print("✏️ Annotations faded out")
                }
            })
        }
    }

    func cancel() {
        fadeTask?.cancel()
        fadeTask = nil

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        toolbarWindow?.orderOut(nil)
        toolbarWindow?.close()
        toolbarWindow = nil

        drawingWindow?.orderOut(nil)
        drawingWindow?.close()
        drawingWindow = nil
        drawingView = nil
        isActive = false
    }

    func clearAnnotations() {
        drawingView?.clearStrokes()
    }
}
