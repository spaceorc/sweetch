import Cocoa
import ApplicationServices

/// Claude Code in a terminal starts dictation while Space is held; Claude desktop toggles it with
/// ⌘D instead. This bridges the two: in Claude desktop, holding Space in the prompt erases the one
/// space it typed and presses ⌘D, and releasing Space presses ⌘D again to stop.
///
/// A tap is left alone — it types its space as always. "Held" means the first autorepeat, or
/// `holdDelay` without one (for people with key repeat off), whichever comes first; either
/// way exactly one space has reached the app by then, so one Backspace undoes it.
///
/// Runs on the event-tap thread (the main run loop).
final class HoldToTalk {
    static let bundleID = "com.anthropic.claudefordesktop"
    private static let dictationKeyCode: Int64 = 2   // D, with ⌘ — Claude's dictation toggle
    private static let holdDelay: TimeInterval = 0.35
    private static let spaceKeyCode: Int64 = 49

    private enum State {
        case idle
        case pending(Timer)                     // Space is down and its space typed; not held yet
        case recording
        case passthrough                        // held, but not somewhere we can record — let it be
    }
    private var state: State = .idle

    /// Sees every real key event first; returns true to swallow it.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.spaceKeyCode else {
            // Typing on while Space is still down (fast "a b") — that was never a hold.
            if type == .keyDown, case .pending(let timer) = state { timer.invalidate(); state = .idle }
            return false
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch (type, state) {
        case (.keyDown, .idle) where !isRepeat:
            guard event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID else { return false }
            let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in self?.becomeHeld() }
            RunLoop.main.add(timer, forMode: .common)
            state = .pending(timer)
            return false

        case (.keyDown, .pending(let timer)) where isRepeat:
            timer.invalidate()
            becomeHeld()
            return isRecording

        case (.keyDown, .recording) where isRepeat:
            return true

        case (.keyUp, .pending(let timer)):
            timer.invalidate()
            state = .idle
            return false

        case (.keyUp, .recording):
            Replayer.postKeyPair(keyCode: Self.dictationKeyCode, flags: .maskCommand)
            log.info("hold-to-talk: dictation off")
            state = .idle
            return true

        case (.keyUp, .passthrough):
            state = .idle
            return false

        default:
            return false
        }
    }

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private func becomeHeld() {
        guard case .pending = state else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID, focusIsTextInput() else {
            log.info("hold-to-talk: Space held outside Claude's prompt — passing through")
            state = .passthrough
            return
        }
        Replayer.postKeyPair(keyCode: 51, flags: [])   // the space the press already typed
        Replayer.postKeyPair(keyCode: Self.dictationKeyCode, flags: .maskCommand)
        log.info("hold-to-talk: dictation on")
        state = .recording
    }

    /// Only hijack Space while typing in a text field — elsewhere a Backspace could navigate.
    private func focusIsTextInput() -> Bool {
        guard let el = SelectionConverter.focusedElement(wait: false) else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        return ["AXTextArea", "AXTextField", "AXComboBox"].contains(role as? String ?? "")
    }
}
