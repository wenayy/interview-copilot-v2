import AppKit
import ScreenCaptureKit

/// Scrolling screenshot: drag out a region, then scroll it yourself while we
/// grab a frame each time the content settles somewhere new. The frames go to
/// the model in order, so a long problem/doc that doesn't fit on screen can be
/// answered in one shot. Like the overlay, every window here uses
/// `sharingType = .none`, so none of it shows up on screen share or in frames.

/// A selected region and the display it lives on.
struct ScreenRegion: Sendable {
    let displayID: CGDirectDisplayID
    /// Top-left-origin points within the display (what `sourceRect` wants).
    let sourceRect: CGRect
    /// Global Cocoa coordinates (for drawing the border window).
    let globalRect: CGRect
    let scale: CGFloat
}

// MARK: - Region picker

@MainActor
final class RegionPicker {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<ScreenRegion?, Never>?

    /// Shows a dimmed full-screen layer on the screen under the mouse; resolves
    /// with the dragged region, or nil on Esc / right-click / a tiny drag.
    func pick() async -> ScreenRegion? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return nil }

        return await withCheckedContinuation { cont in
            continuation = cont
            let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
            win.level = .screenSaver
            win.backgroundColor = .clear
            win.isOpaque = false
            win.sharingType = .none
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect in self?.finish(rect, on: screen) }
            win.contentView = view
            window = win
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ local: NSRect?, on screen: NSScreen) {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
        var region: ScreenRegion?
        if let local, local.width >= 20, local.height >= 20,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID {
            region = ScreenRegion(
                displayID: id,
                sourceRect: CGRect(x: local.minX, y: screen.frame.height - local.maxY,
                                   width: local.width, height: local.height),
                globalRect: local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
                scale: screen.backingScaleFactor)
        }
        continuation?.resume(returning: region)
        continuation = nil
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Dims the screen and draws the rubber-band selection.
private final class RegionSelectView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private var origin: NSPoint?
    private var selection: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        if let sel = selection {
            NSColor.clear.setFill()
            sel.fill(using: .copy)
            NSColor.systemCyan.setStroke()
            let path = NSBezierPath(rect: sel)
            path.lineWidth = 2
            path.stroke()
        } else {
            let hint = "Drag over the area you'll scroll · Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY),
                      withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                           width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { onDone?(selection) }
    override func rightMouseDown(with event: NSEvent) { onDone?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) }   // Esc
    }
}

// MARK: - Capture session

@MainActor
final class ScrollCaptureSession {
    /// Hard cap so a forgotten session can't run up a huge vision bill.
    static let maxFrames = 10

    let region: ScreenRegion
    private(set) var frames: [Data] = []
    var onFrame: (@MainActor (Int) -> Void)?
    var onAutoFinish: (@MainActor () -> Void)?

    private var loop: Task<Void, Never>?
    private var border: NSWindow?

    init(region: ScreenRegion) { self.region = region }

    func start() {
        showBorder()
        loop = Task { [weak self, region] in
            var lastSeen: [UInt8]?
            var lastKept: [UInt8]?
            while !Task.isCancelled {
                if let shot = try? await ScreenGrabber.captureRegion(region) {
                    guard let self, !Task.isCancelled else { return }
                    // Keep a frame once scrolling has paused (two identical
                    // grabs in a row) on content we haven't kept yet. The first
                    // frame is always kept.
                    let settled = lastSeen.map {
                        ScreenGrabber.difference($0, shot.fingerprint) < 1.5 } ?? false
                    let isNew = lastKept.map {
                        ScreenGrabber.difference($0, shot.fingerprint) > 4 } ?? true
                    if lastKept == nil || (settled && isNew) {
                        frames.append(shot.png)
                        lastKept = shot.fingerprint
                        onFrame?(frames.count)
                        if frames.count >= Self.maxFrames {
                            onAutoFinish?()
                            return
                        }
                    }
                    lastSeen = shot.fingerprint
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    /// Stops capturing and returns the frames, top to bottom.
    func stop() -> [Data] {
        loop?.cancel()
        loop = nil
        border?.orderOut(nil)
        border = nil
        return frames
    }

    /// Click-through outline so you can see what's being captured.
    private func showBorder() {
        let frame = region.globalRect.insetBy(dx: -3, dy: -3)
        let win = NSWindow(contentRect: frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = true
        win.sharingType = .none
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSView(frame: NSRect(origin: .zero, size: frame.size))
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.systemRed.cgColor
        box.layer?.borderWidth = 2
        box.layer?.cornerRadius = 3
        win.contentView = box
        win.orderFrontRegardless()
        border = win
    }
}
