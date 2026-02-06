//
//  TeleprompterWindow.swift
//  OpenCapture
//
//  Floating teleprompter overlay — invisible to screen recording.
//  Script is divided into pages separated by "###".
//  Navigate with arrow keys during recording.
//

import SwiftUI
import AppKit

// MARK: - Teleprompter Window (NSPanel)

class TeleprompterWindow: NSPanel {
    /// Set this so the window can navigate pages directly via arrow keys
    var teleprompterState: TeleprompterState?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.hasShadow = true

        // CRITICAL: Invisible to ScreenCaptureKit — will not appear in recordings
        self.sharingType = .none

        // Position on the left side of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.minX + 20,
                y: screenFrame.midY - frame.height / 2
            )
            self.setFrameOrigin(origin)
        }
    }

    /// Start listening for arrow keys (called when window is shown)
    func startKeyMonitor() {
        stopKeyMonitor()

        // Local monitor — when our app is focused
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.handleArrowKey(event) { return nil }
            return event
        }

        // Global monitor — when another app is focused (requires Accessibility permission)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            self.handleArrowKey(event)
        }
    }

    /// Stop listening for arrow keys (called when window is hidden)
    func stopKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    // When user clicks on teleprompter, activate the app so keyboard events work
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
    }

    override var canBecomeKey: Bool { true }

    // Handle arrow keys directly when this window is key
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124: // Right arrow
            teleprompterState?.nextPage()
        case 123: // Left arrow
            teleprompterState?.previousPage()
        default:
            super.keyDown(with: event)
        }
    }

    @discardableResult
    private func handleArrowKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124: // Right arrow
            Task { @MainActor in self.teleprompterState?.nextPage() }
            return true
        case 123: // Left arrow
            Task { @MainActor in self.teleprompterState?.previousPage() }
            return true
        default:
            return false
        }
    }

    deinit {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - Teleprompter State

@MainActor
class TeleprompterState: ObservableObject {
    @Published var pages: [String] = []
    @Published var currentPage: Int = 0
    @Published var fontSize: CGFloat = 28.0
    @Published var opacity: Double = 0.85

    func parseScript(_ text: String) {
        // Accept both ### and --- as page separators
        let normalized = text.replacingOccurrences(of: "\n---\n", with: "\n###\n")
        let rawPages = normalized.components(separatedBy: "\n###\n")
        pages = rawPages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        currentPage = 0
        print("📄 Teleprompter: parsed \(pages.count) pages from script (\(text.count) chars)")
    }

    func nextPage() {
        guard !pages.isEmpty else { return }
        if currentPage < pages.count - 1 {
            currentPage += 1
        }
    }

    func previousPage() {
        if currentPage > 0 {
            currentPage -= 1
        }
    }

    func goToFirst() {
        currentPage = 0
    }

    func goToLast() {
        guard !pages.isEmpty else { return }
        currentPage = pages.count - 1
    }

    var currentPageText: String {
        guard !pages.isEmpty, currentPage < pages.count else {
            return "No script loaded"
        }
        return pages[currentPage]
    }

    var nextPagePreview: String? {
        guard !pages.isEmpty, currentPage + 1 < pages.count else {
            return nil
        }
        let next = pages[currentPage + 1]
        // Show just the first line as preview
        return next.components(separatedBy: .newlines).first
    }

    var pageIndicator: String {
        guard !pages.isEmpty else { return "0 / 0" }
        return "\(currentPage + 1) / \(pages.count)"
    }
}

// MARK: - Teleprompter View

struct TeleprompterView: View {
    @ObservedObject var state: TeleprompterState

    var body: some View {
        VStack(spacing: 0) {
            presentModeView
            controlBar
        }
        .background(Color.black.opacity(state.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Present Mode

    private var presentModeView: some View {
        VStack(spacing: 0) {
            // Current page
            ScrollView(.vertical, showsIndicators: false) {
                styledPageView(state.currentPageText, fontSize: state.fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .id(state.currentPage)

            // Next page preview
            if let preview = state.nextPagePreview {
                Divider()
                    .background(Color.white.opacity(0.2))

                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 10))
                    Text(preview)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    /// Build styled page using VStack of lines with SwiftUI AttributedString
    private func styledPageView(_ text: String, fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: fontSize * 0.4) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                styledLineView(line, fontSize: fontSize)
            }
        }
    }

    /// Render one line with bullet + bold/italic using AttributedString
    private func styledLineView(_ line: String, fontSize: CGFloat) -> some View {
        let isBullet = line.hasPrefix("- ")
        let content = isBullet ? String(line.dropFirst(2)) : line

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if isBullet {
                Text("  \u{2022}  ")
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(.cyan)
            }
            Text(buildAttributedLine(content, fontSize: fontSize))
        }
    }

    /// Parse *bold*, **bold**, _italic_ into SwiftUI AttributedString
    private func buildAttributedLine(_ text: String, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        let chars = Array(text)
        var i = 0
        var buffer = ""

        while i < chars.count {
            // ** double asterisk bold
            if i + 1 < chars.count && chars[i] == "*" && chars[i + 1] == "*" {
                if !buffer.isEmpty {
                    result.append(normalSegment(buffer, fontSize: fontSize))
                    buffer = ""
                }
                if let closeIdx = findMarkerClose(chars, from: i + 2, marker: "**") {
                    let boldText = String(chars[(i + 2)..<closeIdx])
                    result.append(boldSegment(boldText, fontSize: fontSize))
                    i = closeIdx + 2
                } else {
                    buffer.append(contentsOf: "**")
                    i += 2
                }
            }
            // * single asterisk bold
            else if chars[i] == "*" {
                if !buffer.isEmpty {
                    result.append(normalSegment(buffer, fontSize: fontSize))
                    buffer = ""
                }
                if let closeIdx = findMarkerClose(chars, from: i + 1, marker: "*") {
                    let boldText = String(chars[(i + 1)..<closeIdx])
                    result.append(boldSegment(boldText, fontSize: fontSize))
                    i = closeIdx + 1
                } else {
                    buffer.append("*")
                    i += 1
                }
            }
            // _ italic
            else if chars[i] == "_" {
                if !buffer.isEmpty {
                    result.append(normalSegment(buffer, fontSize: fontSize))
                    buffer = ""
                }
                if let closeIdx = findMarkerClose(chars, from: i + 1, marker: "_") {
                    let italicText = String(chars[(i + 1)..<closeIdx])
                    result.append(italicSegment(italicText, fontSize: fontSize))
                    i = closeIdx + 1
                } else {
                    buffer.append("_")
                    i += 1
                }
            } else {
                buffer.append(chars[i])
                i += 1
            }
        }
        if !buffer.isEmpty {
            result.append(normalSegment(buffer, fontSize: fontSize))
        }
        return result
    }

    private func normalSegment(_ text: String, fontSize: CGFloat) -> AttributedString {
        var s = AttributedString(text)
        s.font = .system(size: fontSize, weight: .medium)
        s.foregroundColor = .white
        return s
    }

    private func boldSegment(_ text: String, fontSize: CGFloat) -> AttributedString {
        var s = AttributedString(text)
        s.font = .system(size: fontSize, weight: .heavy)
        s.foregroundColor = .yellow
        return s
    }

    private func italicSegment(_ text: String, fontSize: CGFloat) -> AttributedString {
        var s = AttributedString(text)
        s.font = .system(size: fontSize, weight: .medium).italic()
        s.foregroundColor = .cyan
        return s
    }

    private func findMarkerClose(_ chars: [Character], from start: Int, marker: String) -> Int? {
        let mc = Array(marker)
        var j = start
        while j <= chars.count - mc.count {
            if Array(chars[j..<(j + mc.count)]) == mc && j > start {
                return j
            }
            j += 1
        }
        return nil
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            // Page navigation
            Button(action: { state.previousPage() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(state.currentPage > 0 ? 0.8 : 0.3))
            .disabled(state.currentPage == 0)

            Text(state.pageIndicator)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(minWidth: 40)

            Button(action: { state.nextPage() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(state.currentPage < state.pages.count - 1 ? 0.8 : 0.3))
            .disabled(state.currentPage >= state.pages.count - 1)

            Spacer()

            // Font size
            Button(action: { state.fontSize = max(16, state.fontSize - 2) }) {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.6))

            Text("\(Int(state.fontSize))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 20)

            Button(action: { state.fontSize = min(48, state.fontSize + 2) }) {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.6))

            Text("← →")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - Script Editor (Popup Window)

struct ScriptEditorView: View {
    @Binding var scriptText: String

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Label("Script Editor", systemImage: "text.below.photo")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                let pageCount = scriptText.replacingOccurrences(of: "\n---\n", with: "\n###\n")
                    .components(separatedBy: "\n###\n")
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                let wordCount = scriptText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

                Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                Text("\(wordCount) words")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Editor
            TextEditor(text: $scriptText)
                .font(.system(size: 15, design: .monospaced))
                .lineSpacing(4)
                .padding(12)

            Divider()

            // Syntax help
            HStack(spacing: 16) {
                syntaxHint("###", "Page break")
                syntaxHint("*text*", "Bold")
                syntaxHint("- item", "Bullet")
                Spacer()
                Text("⌘C/⌘V to copy/paste")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func syntaxHint(_ syntax: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(syntax)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(3)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
