//
//  HotkeyManager.swift
//  OpenCapture
//
//  Global keyboard shortcut manager
//

import AppKit
import Carbon

@MainActor
class HotkeyManager: ObservableObject {
    enum Action {
        case toggleRecording
        case togglePause
        case cancelRecording
        case toggleAnnotation
        case clearAnnotations
        case toggleWebcam
        case toggleMicrophone
        case toggleTeleprompter
        case teleprompterNext
        case teleprompterPrevious
        case toggleBackgroundBlur
    }

    var onAction: ((Action) -> Void)?

    /// Set to true when the teleprompter is visible, so arrow keys are captured for page navigation.
    /// When false, arrow keys pass through to other apps (e.g. Keynote/PowerPoint slide navigation).
    var teleprompterActive: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {}

    nonisolated deinit {
        let global = globalMonitor
        let local = localMonitor
        if let monitor = global { NSEvent.removeMonitor(monitor) }
        if let monitor = local { NSEvent.removeMonitor(monitor) }
    }

    func start() {
        removeMonitors()

        // Global monitor — captures hotkeys even when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }

        // Local monitor — captures hotkeys when app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
            return event
        }
    }

    func stop() {
        removeMonitors()
    }

    private func removeMonitors() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Shift+R — Toggle start/stop recording
        if flags == [.command, .shift] && event.keyCode == 15 { // keyCode 15 = 'R'
            onAction?(.toggleRecording)
            return
        }

        // Cmd+Shift+P — Toggle pause/resume
        if flags == [.command, .shift] && event.keyCode == 35 { // keyCode 35 = 'P'
            onAction?(.togglePause)
            return
        }

        // Cmd+Shift+A — Toggle annotation
        if flags == [.command, .shift] && event.keyCode == 0 { // keyCode 0 = 'A'
            onAction?(.toggleAnnotation)
            return
        }

        // Cmd+Shift+D — Clear annotations (delete)
        if flags == [.command, .shift] && event.keyCode == 2 { // keyCode 2 = 'D'
            onAction?(.clearAnnotations)
            return
        }

        // Cmd+Shift+V — Toggle webcam (video)
        if flags == [.command, .shift] && event.keyCode == 9 { // keyCode 9 = 'V'
            onAction?(.toggleWebcam)
            return
        }

        // Cmd+Shift+M — Toggle microphone
        if flags == [.command, .shift] && event.keyCode == 46 { // keyCode 46 = 'M'
            onAction?(.toggleMicrophone)
            return
        }

        // Cmd+Shift+T — Toggle teleprompter
        if flags == [.command, .shift] && event.keyCode == 17 { // keyCode 17 = 'T'
            onAction?(.toggleTeleprompter)
            return
        }

        // Cmd+Shift+B — Toggle background blur
        if flags == [.command, .shift] && event.keyCode == 11 { // keyCode 11 = 'B'
            onAction?(.toggleBackgroundBlur)
            return
        }

        // Ctrl+Right arrow — Teleprompter next page (only when teleprompter is active)
        if teleprompterActive && flags == [.control] && event.keyCode == 124 { // keyCode 124 = →
            onAction?(.teleprompterNext)
            return
        }

        // Ctrl+Left arrow — Teleprompter previous page (only when teleprompter is active)
        if teleprompterActive && flags == [.control] && event.keyCode == 123 { // keyCode 123 = ←
            onAction?(.teleprompterPrevious)
            return
        }

        // Escape — Cancel recording
        if event.keyCode == 53 && flags.isEmpty {
            onAction?(.cancelRecording)
            return
        }
    }
}
