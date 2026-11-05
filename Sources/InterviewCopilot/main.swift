import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Hidden overlay panel
//
// The key trick that makes this a "screen-share invisible" copilot on macOS:
// `sharingType = .none` excludes the window from *all* screen capture and
// recording (Zoom/Meet/Teams screen share, QuickTime, ScreenCaptureKit, etc.).
// You still see it locally; nobody on the call — or in a recording — does.

final class OverlayPanel: NSPanel {
    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 470),
            // Not .resizable: a resizable window's edges switch the cursor to
            // resize arrows, which shows up on a screen share. Resize with
            // ⌃⌥⇧ + arrows instead.
            styleMask: [.titled, .closable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        // Exclude from screen sharing & recordings.
        sharingType = .none

        // Float above normal windows, appear on every Space, survive fullscreen.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary]

        isFloatingPanel = true
        hidesOnDeactivate = false
        // Closing the overlay should hide it, not destroy it — the menu bar
        // "Show overlay" reopens the same panel.
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        contentView = rootView
        setFrameAutosaveName("InterviewCopilotOverlay")

        // The green zoom button (and double-clicking the title bar) still
        // resized the window even without .resizable. Hide it and the unused
        // minimize button; zoom/full screen are blocked below. Close stays.
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
    }

    // Size changes only through the keyboard (⌃⌥⇧ + arrows) and Mini/Full.
    override func zoom(_ sender: Any?) {}
    override func toggleFullScreen(_ sender: Any?) {}

    /// While set (⌃⌥P), every frame change keeps this size with the requested
    /// top edge, so nothing can resize the overlay: not the keyboard, not
    /// Mini/Full, not SwiftUI content sizing or window tiling. Moving still
    /// works. Every resize path ends in one of these two setFrame calls.
    var lockedSize: NSSize?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(keepingLockedSize(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(keepingLockedSize(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func keepingLockedSize(_ rect: NSRect) -> NSRect {
        guard let size = lockedSize, rect.size != size else { return rect }
        NSLog("[overlay] size locked: blocked resize %@ -> %@",
              NSStringFromSize(size), NSStringFromSize(rect.size))
        var frame = rect
        frame.origin.y = rect.maxY - size.height
        frame.size = size
        return frame
    }

    // Allow a borderless/nonactivating panel to still receive keystrokes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: OverlayPanel!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    let settings = AppSettings()
    lazy var vm = CopilotViewModel(settings: settings)
    /// Panel frame from before Mini mode, restored when going back to Full.
    private var fullFrame: NSRect?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: ContentView(vm: vm))
        panel = OverlayPanel(rootView: host)
        // A non-resizable window's frame autosave restores only its position,
        // so keep the size chosen with ⌃⌥⇧ + arrows ourselves (Full mode only;
        // Mini is a temporary size).
        let sizeKey = "overlaySize"
        if let saved = UserDefaults.standard.string(forKey: sizeKey) {
            let size = NSSizeFromString(saved)
            if size.width >= 300, size.height >= 160 {
                // Keep the restored top-left corner where it was.
                var frame = panel.frame
                frame.origin.y += frame.height - size.height
                frame.size = size
                panel.setFrame(frame, display: false)
            }
        }
        NotificationCenter.default
            .publisher(for: NSWindow.didResizeNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, !self.vm.compactMode else { return }
                UserDefaults.standard.set(NSStringFromSize(self.panel.frame.size), forKey: sizeKey)
            }
            .store(in: &cancellables)
        // Reopen where it was left (frame autosave restores the position);
        // center only on first launch, and pull it back on screen if the
        // display it was on is gone.
        if UserDefaults.standard.string(forKey: "NSWindow Frame InterviewCopilotOverlay") == nil {
            panel.center()
        } else {
            panel.setFrame(panel.constrainFrameRect(panel.frame, to: panel.screen ?? NSScreen.main),
                           display: false)
        }
        panel.lockedSize = sizeLocked ? panel.frame.size : nil
        panel.makeKeyAndOrderFront(nil)

        // Resize the panel itself for Mini / Full, so Mini is actually small
        // instead of the same window with less in it.
        vm.$compactMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] compact in
                // Published fires before the view updates; resize after the
                // new layout (and its minimum size) is in place.
                DispatchQueue.main.async { self?.applyCompact(compact) }
            }
            .store(in: &cancellables)

        setupMainMenu()   // enables ⌘X/⌘C/⌘V/⌘A in text fields
        setupMenuBar()

        setupHotKeys()

        NSApp.setActivationPolicy(.accessory) // no Dock icon; menu-bar app
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Keyboard move / resize / size lock

    /// Size lock: freezes the overlay's size (⌃⌥⇧ + arrows and Mini/Full
    /// don't resize it) while buttons, typing and moving keep working.
    /// Remembered across launches.
    private var sizeLocked = UserDefaults.standard.bool(forKey: "overlaySizeLocked") {
        didSet {
            UserDefaults.standard.set(sizeLocked, forKey: "overlaySizeLocked")
            panel?.lockedSize = sizeLocked ? panel.frame.size : nil
            vm.status = sizeLocked ? "Size locked (⌃⌥P to unlock)" : "Size unlocked"
        }
    }

    private let keyboardStep: CGFloat = 40

    /// Move the overlay by (dx, dy), kept inside the visible screen area.
    private func moveOverlay(dx: CGFloat, dy: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.x += dx
        frame.origin.y += dy
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    /// Grow or shrink the overlay, keeping its top edge in place and not
    /// going below the layout's minimum size.
    private func resizeOverlay(dw: CGFloat, dh: CGFloat) {
        guard let panel else { return }
        guard !sizeLocked else {
            vm.status = "Size locked — ⌃⌥P to unlock"
            return
        }
        var frame = panel.frame
        let width = max(vm.compactMode ? 300 : 360, frame.width + dw)
        let height = max(160, frame.height + dh)
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Shrink to a small Mini frame, or restore the Full frame, keeping the
    /// panel's top edge where it is.
    private func applyCompact(_ compact: Bool) {
        guard let panel else { return }
        // Size locked: Mini/Full still switch what's shown, but the window
        // keeps its size. A Mini entered while locked has no Full frame to
        // restore, so leaving it doesn't resize either.
        if sizeLocked {
            if compact { fullFrame = nil }
            return
        }
        var frame = panel.frame
        let size: NSSize
        if compact {
            fullFrame = frame
            size = NSSize(width: min(frame.width, 380), height: 230)
        } else {
            guard let fullFrame else { return }
            size = fullFrame.size
        }
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Mini mode isn't remembered across launches, so save the Full frame.
    func applicationWillTerminate(_ notification: Notification) {
        if vm.compactMode, let fullFrame, let panel {
            var frame = panel.frame
            frame.origin.y += frame.height - fullFrame.height
            frame.size = fullFrame.size
            panel.setFrame(frame, display: false)
        }
    }

    // App keeps running in the menu bar after the overlay is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        false
    }

    // MARK: Main menu (for editing shortcuts)

    // An accessory app has no menu bar, but a main menu is still what routes
    // ⌘C/⌘V/⌘X/⌘A/⌘Z to the focused text field via the responder chain. Without
    // it, paste doesn't work in the Settings fields.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit finder",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            let img = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: "finder")
            img?.isTemplate = true
            btn.image = img
            btn.title = ""
            btn.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add("Start listening", #selector(startListening))
        add("Stop listening", #selector(stopListening))
        menu.addItem(.separator())
        add("Show overlay", #selector(showOverlay))
        add("Hide overlay", #selector(hideOverlay))
        menu.addItem(.separator())
        add("Get answer now  (⌃⌥A)", #selector(getAnswer))
        add("Answer from screen  (⌃⌥S)", #selector(answerScreen))
        add("Add screenshot to queue  (⌃⌥1)", #selector(queueScreenshot))
        add("Answer from queued screenshots  (⌃⌥2)", #selector(answerQueue))
        add("Scrolling screenshot  (⌃⌥L)", #selector(scrollScreenshot))
        menu.addItem(.separator())
        add("New session  (clear memory + transcript)", #selector(newSession))
        menu.addItem(.separator())
        add("Shortcuts:  ⌃⌥A answer · ⌃⌥S screen", #selector(noop))
        add("           ⌃⌥H hide · ⌃⌥M mic · ⌃⌥R résumé", #selector(noop))
        menu.addItem(.separator())
        add("Lock size  (⌃⌥P)", #selector(toggleSizeLock))
        add("Open settings…", #selector(openSettings), ",")
        menu.addItem(.separator())
        add("Relaunch app  (after granting permissions)", #selector(relaunch))
        add("Quit finder", #selector(quit), "q")
        statusItem.menu = menu
    }

    @objc private func startListening() { Task { await vm.start() } }
    @objc private func stopListening() { vm.stop() }
    @objc private func showOverlay() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func hideOverlay() { panel.orderOut(nil) }
    @objc private func getAnswer() { vm.requestSuggestion() }
    @objc private func answerScreen() { vm.answerFromScreen() }
    @objc private func queueScreenshot() { vm.addScreenToQueue() }
    @objc private func answerQueue() { vm.answerFromQueue() }
    @objc private func scrollScreenshot() { vm.toggleScrollCapture() }
    @objc private func newSession() { vm.newSession() }

    private func setupHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(keyCode: Shortcuts.answer.keyCode) { [weak self] in
            self?.vm.requestSuggestion()
        }
        hk.register(keyCode: Shortcuts.screen.keyCode) { [weak self] in
            self?.vm.answerFromScreen()
        }
        hk.register(keyCode: Shortcuts.queueShot.keyCode) { [weak self] in
            self?.vm.addScreenToQueue()
        }
        hk.register(keyCode: Shortcuts.answerQueue.keyCode) { [weak self] in
            self?.vm.answerFromQueue()
        }
        hk.register(keyCode: Shortcuts.clearQueue.keyCode) { [weak self] in
            self?.vm.clearScreenQueue()
        }
        hk.register(keyCode: Shortcuts.scroll.keyCode) { [weak self] in
            self?.vm.toggleScrollCapture()
        }
        hk.register(keyCode: Shortcuts.overlay.keyCode) { [weak self] in
            self?.toggleOverlay()
        }
        hk.register(keyCode: Shortcuts.mic.keyCode) { [weak self] in
            guard let self else { return }
            self.vm.setMic(!self.vm.micEnabled)
        }
        hk.register(keyCode: Shortcuts.resume.keyCode) { [weak self] in
            self?.vm.useResume.toggle()
        }
        hk.register(keyCode: Shortcuts.askLast.keyCode) { [weak self] in
            self?.vm.askLast()
        }
        hk.register(keyCode: Shortcuts.compact.keyCode) { [weak self] in
            self?.vm.compactMode.toggle()
        }
        hk.register(keyCode: Shortcuts.olderAnswer.keyCode) { [weak self] in
            self?.vm.showOlderAnswer()
        }
        hk.register(keyCode: Shortcuts.newerAnswer.keyCode) { [weak self] in
            self?.vm.showNewerAnswer()
        }
        hk.register(keyCode: Shortcuts.lockSize.keyCode) { [weak self] in
            self?.sizeLocked.toggle()
        }

        // Arrows (keyCodes ← 123, → 124, ↓ 125, ↑ 126): ⌃⌥ moves the overlay,
        // ⌃⌥⇧ resizes it (← → width, ↑ shorter, ↓ taller). Holding repeats.
        let step = keyboardStep
        let resize = HotKeyCenter.ctrlOpt | UInt32(shiftKey)
        hk.register(keyCode: 123, repeats: true) { [weak self] in self?.moveOverlay(dx: -step, dy: 0) }
        hk.register(keyCode: 124, repeats: true) { [weak self] in self?.moveOverlay(dx: step, dy: 0) }
        hk.register(keyCode: 125, repeats: true) { [weak self] in self?.moveOverlay(dx: 0, dy: -step) }
        hk.register(keyCode: 126, repeats: true) { [weak self] in self?.moveOverlay(dx: 0, dy: step) }
        hk.register(keyCode: 123, modifiers: resize, repeats: true) { [weak self] in self?.resizeOverlay(dw: -step, dh: 0) }
        hk.register(keyCode: 124, modifiers: resize, repeats: true) { [weak self] in self?.resizeOverlay(dw: step, dh: 0) }
        hk.register(keyCode: 125, modifiers: resize, repeats: true) { [weak self] in self?.resizeOverlay(dw: 0, dh: step) }
        hk.register(keyCode: 126, modifiers: resize, repeats: true) { [weak self] in self?.resizeOverlay(dw: 0, dh: -step) }
    }

    @objc private func toggleSizeLock() { sizeLocked.toggle() }

    private func toggleOverlay() {
        if panel.isVisible { panel.orderOut(nil) }
        else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func noop() {}

    /// Reliably relaunch the app (macOS's own "Quit & Reopen" permission button
    /// is flaky for ad-hoc-signed apps). Spawns a fresh instance after we exit,
    /// so the new process picks up newly-granted permissions.
    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings) { [weak self] in
                self?.vm.rebuildProvider()
                self?.settingsWindow?.close()
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.sharingType = .none   // hide Settings from screen share too
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Enable/disable Start vs Stop and Show vs Hide based on current state.
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(startListening): item.isEnabled = !vm.isRunning
            case #selector(stopListening): item.isEnabled = vm.isRunning
            case #selector(showOverlay): item.isEnabled = !panel.isVisible
            case #selector(hideOverlay): item.isEnabled = panel.isVisible
            case #selector(toggleSizeLock): item.state = sizeLocked ? .on : .off
            default: break
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
