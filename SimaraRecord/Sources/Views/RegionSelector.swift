//
//  RegionSelector.swift
//  OpenCapture
//
//  Region selector overlay — click and drag to select an area
//

import SwiftUI
import AppKit

// MARK: - Region Selector Window

class RegionSelectorWindow: NSPanel {
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
        self.worksWhenModal = true
        self.hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Region Selector View (AppKit)

class RegionSelectorView: NSView {
    private var startPoint: NSPoint?
    private var endPoint: NSPoint?
    private var isSelecting = false
    var onComplete: ((CGRect?) -> Void)?

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
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent background
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        // Draw selection rectangle if dragging
        if let start = startPoint, let end = endPoint {
            let rect = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )

            // Clear the selected area to show through
            NSColor.clear.setFill()
            rect.fill(using: .copy)

            // Selection border
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()

            // Dimension label
            let text = "\(Int(rect.width)) x \(Int(rect.height)) px"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = text.size(withAttributes: attrs)
            let labelRect = NSRect(
                x: rect.midX - textSize.width / 2 - 8,
                y: rect.maxY + 10,
                width: textSize.width + 16,
                height: textSize.height + 8
            )

            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
            text.draw(
                at: NSPoint(x: labelRect.midX - textSize.width / 2, y: labelRect.midY - textSize.height / 2),
                withAttributes: attrs
            )
        }

        // Instructions
        if !isSelecting {
            let instructionText = "Click and drag to select area  |  Esc or right-click to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = instructionText.size(withAttributes: attrs)
            let bgRect = NSRect(
                x: bounds.midX - textSize.width / 2 - 20,
                y: bounds.midY - textSize.height / 2 - 10,
                width: textSize.width + 40,
                height: textSize.height + 20
            )

            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()
            instructionText.draw(
                at: NSPoint(x: bgRect.midX - textSize.width / 2, y: bgRect.midY - textSize.height / 2),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        endPoint = startPoint
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        endPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = endPoint else {
            onComplete?(nil)
            return
        }

        let viewRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        if viewRect.width > 50 && viewRect.height > 50 {
            // Convert from view coordinates (bottom-left origin) to
            // ScreenCaptureKit coordinates (top-left origin).
            if let screen = self.window?.screen ?? NSScreen.main {
                let screenHeight = screen.frame.height
                let flippedRect = CGRect(
                    x: viewRect.origin.x - screen.frame.origin.x,
                    y: screenHeight - viewRect.origin.y - viewRect.height,
                    width: viewRect.width,
                    height: viewRect.height
                )
                onComplete?(flippedRect)
            } else {
                onComplete?(viewRect)
            }
        } else {
            // Too small — treat as cancel
            onComplete?(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete?(nil)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Region Selector Controller

@MainActor
class RegionSelectorController: ObservableObject {
    private var window: RegionSelectorWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var safetyTimer: Timer?

    func showSelector(completion: @escaping (CGRect?) -> Void) {
        guard window == nil else { return }

        guard let screen = NSScreen.main else { return }

        let window = RegionSelectorWindow(screen: screen)
        let view = RegionSelectorView(frame: screen.frame)

        var dismissed = false
        let dismiss: (CGRect?) -> Void = { [weak self] rect in
            guard !dismissed else { return }
            dismissed = true
            self?.cleanup()
            completion(rect)
        }

        view.onComplete = dismiss

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.crosshair.set()

        // Local event monitor (works when app is active)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { event in
            if event.type == .rightMouseDown || (event.type == .keyDown && event.keyCode == 53) {
                dismiss(nil)
                return nil
            }
            return event
        }

        // Global event monitor (works even when app is NOT active — catches Escape from anywhere)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { event in
            if event.type == .rightMouseDown || (event.type == .keyDown && event.keyCode == 53) {
                DispatchQueue.main.async {
                    dismiss(nil)
                }
            }
        }

        // Safety timeout — auto-dismiss after 30 seconds to prevent getting stuck
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { _ in
            DispatchQueue.main.async {
                print("⚠️ Region selector timed out, auto-dismissing")
                dismiss(nil)
            }
        }

        self.window = window
    }

    private func cleanup() {
        safetyTimer?.invalidate()
        safetyTimer = nil

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        window?.orderOut(nil)
        window?.close()
        window = nil

        NSCursor.arrow.set()
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        cleanup()
    }
}
