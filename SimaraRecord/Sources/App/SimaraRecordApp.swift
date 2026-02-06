//
//  OpenCaptureApp.swift
//  OpenCapture
//
//  Main application entry point
//

import SwiftUI
import AppKit

@main
struct OpenCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app activates and shows windows
        NSApp.setActivationPolicy(.regular)

        // Set the app icon programmatically for the Dock
        let icon = AppIconGenerator.generate(size: 512)
        NSApp.applicationIconImage = icon

        // Also install the icon into the app bundle so System Settings shows it
        installIconInBundle(icon)

        // Setup main menu with keyboard shortcuts
        setupMainMenu()

        // Center the main window and bring app to front
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func setupMainMenu() {
        // Add a Recording menu to the existing menu bar (preserves SwiftUI's Edit menu
        // which provides working ⌘C/⌘V/⌘X/⌘A in text fields)
        guard let mainMenu = NSApp.mainMenu else { return }

        let recordingMenu = NSMenu(title: "Recording")
        let startStopItem = NSMenuItem(title: "Start/Stop Recording", action: nil, keyEquivalent: "r")
        startStopItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(startStopItem)

        let pauseItem = NSMenuItem(title: "Pause/Resume", action: nil, keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(pauseItem)

        recordingMenu.addItem(.separator())

        let annotateItem = NSMenuItem(title: "Toggle Annotation", action: nil, keyEquivalent: "a")
        annotateItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(annotateItem)

        let clearItem = NSMenuItem(title: "Clear Annotations", action: nil, keyEquivalent: "d")
        clearItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(clearItem)

        recordingMenu.addItem(.separator())

        let webcamItem = NSMenuItem(title: "Toggle Webcam", action: nil, keyEquivalent: "v")
        webcamItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(webcamItem)

        let micItem = NSMenuItem(title: "Toggle Microphone", action: nil, keyEquivalent: "m")
        micItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(micItem)

        let teleprompterItem = NSMenuItem(title: "Toggle Teleprompter", action: nil, keyEquivalent: "t")
        teleprompterItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(teleprompterItem)

        let blurItem = NSMenuItem(title: "Toggle Background Blur", action: nil, keyEquivalent: "b")
        blurItem.keyEquivalentModifierMask = [.command, .shift]
        recordingMenu.addItem(blurItem)

        recordingMenu.addItem(.separator())

        let cancelItem = NSMenuItem(title: "Cancel Recording", action: nil, keyEquivalent: "\u{1b}") // Escape
        cancelItem.keyEquivalentModifierMask = []
        recordingMenu.addItem(cancelItem)

        let recordingMenuItem = NSMenuItem()
        recordingMenuItem.submenu = recordingMenu
        mainMenu.addItem(recordingMenuItem)
    }

    private func installIconInBundle(_ icon: NSImage) {
        guard let bundlePath = Bundle.main.bundlePath as String?,
              bundlePath.hasSuffix(".app") else { return }

        let resourcesDir = (bundlePath as NSString).appendingPathComponent("Contents/Resources")
        let iconPath = (resourcesDir as NSString).appendingPathComponent("AppIcon.icns")

        // Only write if it doesn't already exist
        guard !FileManager.default.fileExists(atPath: iconPath) else { return }

        // Try to copy from SPM bundle resource first
        if let bundledIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            try? FileManager.default.copyItem(at: bundledIcon, to: URL(fileURLWithPath: iconPath))
            return
        }

        // Fallback: write the generated icon as TIFF (not ideal but works)
        try? FileManager.default.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)
        if let tiffData = icon.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: iconPath))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - App Icon Generator

enum AppIconGenerator {
    static func generate(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)

        // Padding for macOS icon shape
        let padding = size * 0.05
        let iconRect = rect.insetBy(dx: padding, dy: padding)

        // Rounded rect background
        let cornerRadius = iconRect.width * 0.22
        let path = CGPath(
            roundedRect: iconRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        // Purple -> blue -> teal gradient
        let colors = [
            CGColor(red: 0.58, green: 0.38, blue: 0.86, alpha: 1.0),
            CGColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 1.0),
            CGColor(red: 0.50, green: 0.75, blue: 0.78, alpha: 1.0),
        ] as CFArray
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0.0, 0.5, 1.0]
        )!

        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
            options: []
        )
        ctx.restoreGState()

        // Camera body (white rounded rect)
        let camWidth = iconRect.width * 0.42
        let camHeight = iconRect.height * 0.30
        let camX = iconRect.midX - camWidth / 2 - iconRect.width * 0.04
        let camY = iconRect.midY - camHeight / 2
        let camRect = CGRect(x: camX, y: camY, width: camWidth, height: camHeight)
        let camCorner = camHeight * 0.18
        let camPath = CGPath(
            roundedRect: camRect,
            cornerWidth: camCorner,
            cornerHeight: camCorner,
            transform: nil
        )

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.addPath(camPath)
        ctx.fillPath()

        // Camera lens notch (trapezoid on right)
        let notchWidth = iconRect.width * 0.12
        let notchHeight = camHeight * 0.55
        let notchX = camRect.maxX + iconRect.width * 0.01
        let notchY = camRect.midY

        ctx.beginPath()
        ctx.move(to: CGPoint(x: notchX, y: notchY - notchHeight / 2))
        ctx.addLine(to: CGPoint(x: notchX + notchWidth, y: notchY - notchHeight * 0.8))
        ctx.addLine(to: CGPoint(x: notchX + notchWidth, y: notchY + notchHeight * 0.8))
        ctx.addLine(to: CGPoint(x: notchX, y: notchY + notchHeight / 2))
        ctx.closePath()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.fillPath()

        // Recording dot (red circle, top-right of camera)
        let dotSize = iconRect.width * 0.08
        let dotX = camRect.maxX - dotSize * 0.2
        let dotY = camRect.maxY - dotSize * 0.2
        let dotRect = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        ctx.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1.0))
        ctx.fillEllipse(in: dotRect)

        image.unlockFocus()
        return image
    }
}
