import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey. Unlike NSEvent global
/// monitors, this works while another app is focused and needs NO Accessibility
/// permission — the fix for "hotkeys don't work during the interview".
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    /// Hotkeys that keep firing while held (id → key code), and the timer of
    /// the one currently held.
    private var repeatingKeys: [UInt32: UInt32] = [:]
    private var repeatTimer: Timer?

    /// Control+Option — our app modifier, chosen to avoid common conflicts.
    static let ctrlOpt = UInt32(controlKey | optionKey)

    /// `repeats`: keep firing while the key is held, like normal key repeat.
    func register(keyCode: UInt32, modifiers: UInt32 = ctrlOpt,
                  repeats: Bool = false, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        handlers[id] = action
        if repeats { repeatingKeys[id] = keyCode }
        let hkID = EventHotKeyID(signature: fourCharCode("ICPT"), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hkID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    fileprivate func pressed(_ id: UInt32) {
        handlers[id]?()
        guard repeatingKeys[id] != nil else { return }
        // Like system key repeat: a short pause, then steady repeats.
        stopRepeat()
        let delay = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                let center = HotKeyCenter.shared
                let tick = Timer(timeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated { HotKeyCenter.shared.repeatTick(id) }
                }
                RunLoop.main.add(tick, forMode: .common)
                center.repeatTimer = tick
            }
        }
        RunLoop.main.add(delay, forMode: .common)
        repeatTimer = delay
    }

    fileprivate func released(_ id: UInt32) {
        if repeatingKeys[id] != nil { stopRepeat() }
    }

    private func repeatTick(_ id: UInt32) {
        // Stop if the key is no longer physically down, in case the release
        // event was missed (e.g. focus changed mid-hold).
        guard let keyCode = repeatingKeys[id],
              CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else {
            stopRepeat(); return
        }
        handlers[id]?()
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // The callback is a capture-less C function, invoked on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated {
                if isPress { HotKeyCenter.shared.pressed(hkID.id) }
                else { HotKeyCenter.shared.released(hkID.id) }
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}

private func fourCharCode(_ s: String) -> FourCharCode {
    var result: FourCharCode = 0
    for ch in s.utf16 { result = (result << 8) + FourCharCode(ch) }
    return result
}

/// The app's shortcuts, in one place — used both to register them and to render
/// the in-overlay cheat sheet so you never have to remember them.
struct Shortcut {
    let label: String
    let keys: String        // display, e.g. "⌃⌥A"
    let keyCode: UInt32
}

enum Shortcuts {
    // keyCodes: A=0, S=1, H=4, M=46, R=15, Q=12, C=8, L=37, [=33, ]=30,
    // 1=18, 2=19, 3=20
    static let answer = Shortcut(label: "Answer (spoken question)", keys: "⌃⌥A", keyCode: 0)
    static let screen = Shortcut(label: "Answer from screen", keys: "⌃⌥S", keyCode: 1)
    static let queueShot = Shortcut(label: "Add screenshot to queue", keys: "⌃⌥1", keyCode: 18)
    static let answerQueue = Shortcut(label: "Answer from queued screenshots", keys: "⌃⌥2", keyCode: 19)
    static let clearQueue = Shortcut(label: "Clear screenshot queue", keys: "⌃⌥3", keyCode: 20)
    static let overlay = Shortcut(label: "Show / hide overlay", keys: "⌃⌥H", keyCode: 4)
    static let mic = Shortcut(label: "Toggle mic listening", keys: "⌃⌥M", keyCode: 46)
    static let resume = Shortcut(label: "Toggle résumé use", keys: "⌃⌥R", keyCode: 15)
    static let askLast = Shortcut(label: "Ask last (what you said)", keys: "⌃⌥Q", keyCode: 12)
    static let compact = Shortcut(label: "Compact / full mode", keys: "⌃⌥C", keyCode: 8)

    static let scroll = Shortcut(label: "Scrolling screenshot (start / done)", keys: "⌃⌥L", keyCode: 37)

    // Display-only rows for the cheat sheet; the four arrows are registered
    // individually in AppDelegate.setupHotKeys() and repeat while held.
    // P=35 (⌃⌥T is taken by MyToolbox's Capture Text).
    static let moveOverlay = Shortcut(label: "Move overlay", keys: "⌃⌥ arrows", keyCode: 123)
    static let resizeOverlay = Shortcut(label: "Resize overlay", keys: "⌃⌥⇧ arrows", keyCode: 123)
    static let lockSize = Shortcut(label: "Lock / unlock overlay size", keys: "⌃⌥P", keyCode: 35)

    static let olderAnswer = Shortcut(label: "Previous answer", keys: "⌃⌥[", keyCode: 33)
    static let newerAnswer = Shortcut(label: "Next answer (back to latest)", keys: "⌃⌥]", keyCode: 30)

    static let all = [answer, screen, queueShot, answerQueue, clearQueue, scroll,
                      overlay, moveOverlay, resizeOverlay, lockSize,
                      mic, resume, askLast, compact,
                      olderAnswer, newerAnswer]
}
